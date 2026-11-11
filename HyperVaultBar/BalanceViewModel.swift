import AppKit
import Foundation

enum ChangeKind {
    case rawBalance, flowAdjusted

    var label: String {
        switch self {
        case .rawBalance: "24h balance change"
        case .flowAdjusted: "24h change"
        }
    }

    var explanation: String {
        switch self {
        case .rawBalance:
            "Cash-flow data is unavailable, so deposits and withdrawals may affect this balance change."
        case .flowAdjusted:
            "Deposits and withdrawals are excluded from this change."
        }
    }
}

enum SettingsApplyError: LocalizedError {
    case notificationsDenied
    var errorDescription: String? { "Notifications are disabled for HyperVaultBar in System Settings." }
}

@MainActor
final class BalanceViewModel: ObservableObject {
    @Published private(set) var balance: Decimal?
    @Published private(set) var hasPosition = true
    @Published private(set) var change: Decimal?
    @Published private(set) var changeKind: ChangeKind = .rawBalance
    @Published private(set) var updatedAt: Date?
    @Published private(set) var stale = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var vaultEquity: Decimal?
    @Published private(set) var vaultEquityAt: Date?
    @Published private(set) var vaultAPR: Decimal?
    @Published private(set) var vaultName: String?
    @Published private(set) var historyError: String?
    @Published private(set) var flowError: String?
    @Published private(set) var notificationError: String?
    @Published private(set) var vaultDetailsStale = false

    let settings: SettingsStore
    private let service: any BalanceProviding
    private let directory: URL?
    private let applyLogin: ((Bool) throws -> Void)?
    private let requestPermission: () async throws -> Bool
    private let notifier: any NotificationSending
    private let movementStore = MovementHistoryStore()
    private var refreshID: UUID?
    @Published private(set) var canResetHistory = false
    private var snapshots: SnapshotStore?
    private var flowStore: VaultFlowStore?
    private var timer: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var alertState = DrawdownAlertState()
    private var notificationInFlight = false
    private var movementInFlight: Set<String> = []
    private var retryAfter: Date?

    init(settings: SettingsStore? = nil, service: any BalanceProviding = BalanceService(),
         directory: URL? = nil, autoStart: Bool = true, applyLogin: ((Bool) throws -> Void)? = nil,
         requestPermission: (() async throws -> Bool)? = nil,
         notifier: any NotificationSending = NotificationService()) {
        self.settings = settings ?? SettingsStore()
        self.service = service
        self.directory = directory
        self.notifier = notifier
        self.requestPermission = requestPermission ?? { try await notifier.requestPermission() }
        self.applyLogin = applyLogin
        loadHistory(wallet: self.settings.walletAddress, vault: self.settings.vaultAddress)
        if autoStart {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleWake() }
            }
            restartTimer()
        }
    }

    deinit {
        timer?.cancel()
        refreshTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var displayVaultName: String {
        if let name = vaultName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if settings.vaultAddress.caseInsensitiveCompare(SettingsStore.hlpAddress) == .orderedSame {
            return "Hyperliquidity Provider (HLP)"
        }
        return "Vault \(settings.vaultAddress.prefix(8))…"
    }

    var changeValueDescription: String {
        guard let balance, let change else { return "—" }
        let amount = Money.signed(change)
        guard let percent = Money.significantPercent(change, base: balance - change, signed: true) else {
            return amount
        }
        return "\(amount) (\(percent))"
    }

    func refresh(replacing: Bool = false) {
        if refreshID != nil && !replacing { return }
        if !replacing, let retryAfter, retryAfter > .now { return }
        refreshTask?.cancel()
        refreshID = nil
        guard SettingsStore.validWallet(settings.walletAddress),
              SettingsStore.validAddress(settings.vaultAddress) else {
            stale = true
            errorMessage = "Enter valid wallet and vault addresses in Settings."
            return
        }
        let wallet = settings.walletAddress
        let vault = settings.vaultAddress
        let id = UUID()
        refreshID = id
        refreshTask = Task {
            defer { if refreshID == id { refreshID = nil; refreshTask = nil } }
            async let position: Void = refreshPosition(wallet: wallet, vault: vault)
            async let details: Void = refreshDetails(wallet: wallet, vault: vault)
            _ = await (position, details)
        }
    }

    private func refreshPosition(wallet: String, vault: String) async {
            do {
                let position = try await service.fetchEquity(wallet: wallet, vaultAddress: vault)
                try Task.checkCancellation()
                let now = Date()
                let equity = position.equity
                hasPosition = position.hasPosition
                let currentFlowStore = flowStore
                async let flowsRequest: [VaultCashFlow] = {
                    guard let currentFlowStore else { throw BalanceError.incompleteLedger }
                    return try await currentFlowStore.flows(
                        since: now.addingTimeInterval(-7 * 86_400), through: now,
                        fetch: { start, end in
                            try await service.fetchVaultFlows(wallet: wallet, vaultAddress: vault,
                                                              since: start, until: end)
                        })
                }()
                let historical = snapshots?.closestTo24Hours(before: now)
                balance = equity
                change = position.hasPosition ? historical.map { equity - $0.equity } : nil
                changeKind = .rawBalance
                updatedAt = now
                stale = false
                errorMessage = nil
                do {
                    try snapshots?.append(equity, at: now)
                    if snapshots != nil { historyError = nil }
                } catch {
                    historyError = error.localizedDescription
                }

                do {
                    let flows = try await flowsRequest
                    try Task.checkCancellation()
                    flowError = nil
                    if position.hasPosition, let snapshots,
                       let peak = FlowAdjustedMetrics.adjustedPeak(snapshots: snapshots.snapshots, at: now, flows: flows),
                       equity > peak {
                        do { try snapshots.append(equity, at: now, force: true) }
                        catch { historyError = error.localizedDescription }
                    }
                    if position.hasPosition, let historical {
                        change = FlowAdjustedMetrics.change(current: equity, from: historical, at: now, flows: flows)
                        changeKind = .flowAdjusted
                    }
                    if position.hasPosition {
                        checkDrawdown(current: equity, now: now, flows: flows)
                        await checkMovement(value: equity, now: now, wallet: wallet, vault: vault,
                                            config: settings.balanceMovement, kind: "balance", flows: flows)
                    }
                } catch is CancellationError {
                    // A newer refresh owns the displayed state.
                } catch {
                    guard !Task.isCancelled else { return }
                    if case BalanceError.rateLimited = error { retryAfter = .now.addingTimeInterval(60) }
                    flowError = error.localizedDescription
                    // Raw equity can include deposits or withdrawals; do not alert without ledger data.
                }
            } catch is CancellationError {
                // A newer refresh owns the displayed state.
            } catch {
                guard !Task.isCancelled else { return }
                if case BalanceError.rateLimited = error { retryAfter = .now.addingTimeInterval(60) }
                stale = true
                errorMessage = error.localizedDescription
            }
    }

    private func refreshDetails(wallet: String, vault: String) async {
        do {
            let details = try await service.fetchDetails(wallet: wallet, vaultAddress: vault)
            try Task.checkCancellation()
            vaultEquity = details.vaultEquity
            vaultEquityAt = details.vaultEquityAt
            vaultAPR = details.apr
            vaultName = details.name
            vaultDetailsStale = false
            if let apr = details.apr {
                await checkMovement(value: apr, now: .now, wallet: wallet, vault: vault,
                                    config: settings.aprMovement, kind: "apr", flows: nil)
            }
        } catch {
            guard !Task.isCancelled else { return }
            if case BalanceError.rateLimited = error { retryAfter = .now.addingTimeInterval(60) }
            vaultDetailsStale = true
        }
    }

    func restartTimer() {
        timer?.cancel()
        refresh(replacing: true)
        let interval = max(15, settings.refreshInterval)
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                refresh()
            }
        }
    }

    func handleWake() {
        // Discard a request suspended during sleep and start a fresh interval from wake.
        restartTimer()
    }

    func setInterval(_ interval: TimeInterval) {
        settings.refreshInterval = SettingsStore.validInterval(interval)
        restartTimer()
    }

    func applySettings(wallet: String, vault: String, interval: TimeInterval,
                       enabled: Bool, threshold: Double, login: Bool,
                       balanceMovement: MovementAlertConfiguration, aprMovement: MovementAlertConfiguration) async throws {
        // Complete fallible external actions before writing the other preferences.
        let newlyEnabled = (enabled && !settings.alertsEnabled) ||
            (balanceMovement.enabled && !settings.balanceMovement.enabled) ||
            (aprMovement.enabled && !settings.aprMovement.enabled)
        if newlyEnabled {
            do {
                notificationError = try await requestPermission() ? nil : SettingsApplyError.notificationsDenied.localizedDescription
            } catch { notificationError = error.localizedDescription }
        }
        if let applyLogin { try applyLogin(login) } else { try settings.setLaunchAtLogin(login) }

        let selectionChanged = wallet.caseInsensitiveCompare(settings.walletAddress) != .orderedSame ||
            vault.caseInsensitiveCompare(settings.vaultAddress) != .orderedSame
        if selectionChanged {
            loadHistory(wallet: wallet, vault: vault)
            balance = nil
            hasPosition = true
            change = nil
            vaultEquity = nil
            vaultEquityAt = nil
            vaultAPR = nil
            vaultName = nil
            updatedAt = nil
            flowError = nil
            errorMessage = nil
            vaultDetailsStale = false
        }
        if threshold != settings.alertThreshold {
            alertState.reset()
            UserDefaults.standard.set(true, forKey: alertKey(wallet: wallet, vault: vault))
        }
        settings.balanceMovement = balanceMovement
        settings.aprMovement = aprMovement
        settings.walletAddress = wallet
        settings.vaultAddress = vault.lowercased()
        settings.alertsEnabled = enabled
        if !enabled && !balanceMovement.enabled && !aprMovement.enabled { notificationError = nil }
        settings.alertThreshold = max(0.1, min(100, threshold))
        setInterval(interval)
    }

    private func checkDrawdown(current: Decimal, now: Date, flows: [VaultCashFlow]) {
        guard let history = snapshots?.snapshots,
              let peak = FlowAdjustedMetrics.adjustedPeak(snapshots: history, at: now, flows: flows),
              peak > 0 else { return }
        var proposed = alertState
        let notify = proposed.shouldNotify(current: current, peak: peak,
                                           threshold: Decimal(settings.alertThreshold),
                                           enabled: settings.alertsEnabled)
        let key = alertKey(wallet: settings.walletAddress, vault: settings.vaultAddress)
        if !notify {
            alertState = proposed
            UserDefaults.standard.set(proposed.armed, forKey: key)
            return
        }
        guard !notificationInFlight else { return }
        notificationInFlight = true
        let wallet = settings.walletAddress
        let vault = settings.vaultAddress
        Task {
            defer { notificationInFlight = false }
            guard settings.walletAddress.caseInsensitiveCompare(wallet) == .orderedSame,
                  settings.vaultAddress.caseInsensitiveCompare(vault) == .orderedSame,
                  settings.alertsEnabled else { return }
            do {
                try await notifier.send(title: "Vault drawdown alert",
                    body: "Your balance is \(Money.percent(peak - current, base: peak)) below its 7-day high. Current balance: \(Money.format(current)).")
                UserDefaults.standard.set(false, forKey: key)
                if settings.walletAddress.caseInsensitiveCompare(wallet) == .orderedSame &&
                   settings.vaultAddress.caseInsensitiveCompare(vault) == .orderedSame {
                    alertState = proposed
                }
                notificationError = nil
            } catch {
                notificationError = error.localizedDescription
                // Keep the alert armed so a later refresh can retry delivery.
            }
        }
    }

    func movementStatus(kind: String, config: MovementAlertConfiguration) -> String {
        guard config.enabled else { return "Disabled" }
        let saved = kind == "apr" ? settings.aprMovement : settings.balanceMovement
        guard config == saved else { return "Save to apply these settings." }
        guard SettingsStore.validWallet(settings.walletAddress) else { return "Enter a wallet address first." }
        if let notificationError { return notificationError }
        if kind == "balance" {
            if stale { return "Paused: balance data unavailable." }
            if !hasPosition { return "Paused: no position in this vault." }
            if flowError != nil { return "Paused: cash flows unavailable." }
        } else if vaultDetailsStale || vaultAPR == nil { return "Paused: APR data unavailable." }
        let history = movementStore.load(kind: kind, wallet: settings.walletAddress, vault: settings.vaultAddress)
        guard let latest = history.points.last else { return "Collecting local history." }
        guard history.comparisonPoint(at: latest.date, window: config.window) != nil else {
            return "Collecting history for a \(intervalName(config.window)) comparison."
        }
        if let sent = history.lastSent, Date.now.timeIntervalSince(sent) < config.cooldown {
            return "Cooling down after a notification. Checked on each refresh."
        }
        if !history.armed { return "Waiting for recovery below half the threshold or a direction reversal." }
        return "Ready. Checked on each refresh."
    }

    private func checkMovement(value: Decimal, now: Date, wallet: String, vault: String,
                               config: MovementAlertConfiguration, kind: String,
                               flows: [VaultCashFlow]?) async {
        guard !Task.isCancelled else { return }
        let key = "movement.\(kind).\(wallet.lowercased()).\(vault.lowercased())"
        guard !movementInFlight.contains(key) else { return }
        movementInFlight.insert(key)
        defer { movementInFlight.remove(key) }
        var history = movementStore.load(kind: kind, wallet: wallet, vault: vault)
        if history.configuration != config {
            history.configuration = config
            history.armed = true
            history.lastSent = nil
        }
        history.record(value, at: now)
        if let movement = history.candidate(current: value, at: now, config: config, flows: flows) {
            let direction = movement.change >= 0 ? "increased" : "decreased"
            let amount = String(format: "%.2f", NSDecimalNumber(decimal: abs(movement.change)).doubleValue)
            let period = notificationPeriod(movement.elapsed)
            let title = kind == "apr"
                ? "Vault APR \(direction) by \(amount) points"
                : "Vault balance \(direction) by \(amount)%"
            let body = kind == "apr"
                ? "\(period.capitalized). Current APR: \(Money.apr(value))."
                : "\(period.capitalized). Current balance: \(Money.format(value))."
            do {
                guard !Task.isCancelled,
                      settings.walletAddress.caseInsensitiveCompare(wallet) == .orderedSame,
                      settings.vaultAddress.caseInsensitiveCompare(vault) == .orderedSame else { return }
                try await notifier.send(title: title, body: body)
                history.delivered(at: now, change: movement.change)
                notificationError = nil
            } catch { notificationError = error.localizedDescription }
        }
        do {
            try movementStore.save(history, kind: kind, wallet: wallet, vault: vault)
            objectWillChange.send()
        } catch { notificationError = error.localizedDescription }
    }

    func sendTestNotification() async throws {
        let authorized = try await notifier.requestPermission()
        guard authorized else { throw SettingsApplyError.notificationsDenied }
        try await notifier.send(title: "HyperVaultBar test", body: "Notifications are working.")
    }

    func waitForRefresh() async { await refreshTask?.value }

    func resetCorruptedHistory() {
        do {
            snapshots = try SnapshotStore(wallet: settings.walletAddress, vault: settings.vaultAddress,
                                          directory: directory, recoverCorrupted: true)
            canResetHistory = false
            historyError = "History restarted; comparisons need new samples. The damaged file was preserved."
            refresh(replacing: true)
        } catch { historyError = error.localizedDescription }
    }

    private func loadHistory(wallet: String, vault: String) {
        do {
            snapshots = try SnapshotStore(wallet: wallet, vault: vault, directory: directory)
            canResetHistory = false
            historyError = nil
        } catch {
            snapshots = nil
            canResetHistory = error is DecodingError
            historyError = error.localizedDescription
        }
        do {
            flowStore = try VaultFlowStore(wallet: wallet, vault: vault, directory: directory)
        } catch {
            flowStore = nil
            historyError = error.localizedDescription
        }
        let key = alertKey(wallet: wallet, vault: vault)
        let previousKey = "alertArmed.\(wallet.lowercased())"
        if vault.caseInsensitiveCompare(SettingsStore.hlpAddress) == .orderedSame,
           UserDefaults.standard.object(forKey: key) == nil,
           let previous = UserDefaults.standard.object(forKey: previousKey) as? Bool {
            UserDefaults.standard.set(previous, forKey: key)
            UserDefaults.standard.removeObject(forKey: previousKey)
        }
        let armed = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        alertState = DrawdownAlertState(armed: armed)
    }

    private func alertKey(wallet: String, vault: String) -> String {
        "alertArmed.\(wallet.lowercased()).\(vault.lowercased())"
    }
}

