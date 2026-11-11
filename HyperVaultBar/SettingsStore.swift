import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    nonisolated static let hlpAddress = "0xdfc24b077bc1425ad1dea75bcb6f8158e10df303"
    nonisolated static let intervals: [TimeInterval] = [15, 30, 60, 300, 900, 1800, 3600]

    @Published var balanceMovement: MovementAlertConfiguration { didSet { persist(balanceMovement, key: "balanceMovement") } }
    @Published var aprMovement: MovementAlertConfiguration { didSet { persist(aprMovement, key: "aprMovement") } }

    private func persist(_ value: MovementAlertConfiguration, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    @Published var walletAddress: String { didSet { defaults.set(walletAddress, forKey: "walletAddress") } }
    @Published var vaultAddress: String { didSet { defaults.set(vaultAddress, forKey: "vaultAddress") } }
    @Published var refreshInterval: TimeInterval { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    @Published var alertThreshold: Double { didSet { defaults.set(alertThreshold, forKey: "alertThreshold") } }
    @Published private(set) var launchAtLogin = false
    @Published var launchError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func configuration(_ key: String, threshold: Double, window: Double) -> MovementAlertConfiguration {
            if let data = defaults.data(forKey: key),
               let value = try? JSONDecoder().decode(MovementAlertConfiguration.self, from: data), value.valid { return value }
            return MovementAlertConfiguration(threshold: threshold, window: window)
        }
        balanceMovement = configuration("balanceMovement", threshold: 0.1, window: 900)
        aprMovement = configuration("aprMovement", threshold: 1, window: 3600)
        walletAddress = defaults.string(forKey: "walletAddress") ?? ""
        let storedVault = defaults.string(forKey: "vaultAddress") ?? Self.hlpAddress
        vaultAddress = Self.validAddress(storedVault) ? storedVault.lowercased() : Self.hlpAddress
        refreshInterval = Self.validInterval(defaults.object(forKey: "refreshInterval") as? Double ?? 900)
        alertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool ?? false
        alertThreshold = max(0.1, min(100, defaults.object(forKey: "alertThreshold") as? Double ?? 5))
        refreshLoginStatus()
    }

    static func validInterval(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value >= 15 ? value : 900
    }

    static func validWallet(_ wallet: String) -> Bool {
        validAddress(wallet)
    }

    nonisolated static func validAddress(_ address: String) -> Bool {
        address.range(of: #"^0x[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil
    }

    func refreshLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        refreshLoginStatus()
        if enabled == launchAtLogin {
            launchError = nil
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            refreshLoginStatus()
            throw error
        }
        refreshLoginStatus()
    }
}

func intervalName(_ interval: TimeInterval) -> String {
    if interval.truncatingRemainder(dividingBy: 3600) == 0 {
        let hours = Int(interval / 3600)
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
    if interval.truncatingRemainder(dividingBy: 60) == 0 {
        return "\(Int(interval / 60)) min"
    }
    return "\(Int(interval)) s"
}

func notificationPeriod(_ interval: TimeInterval) -> String {
    let minutes = max(1, Int((interval / 60).rounded()))
    if minutes >= 45 {
        let hours = max(1, Int((Double(minutes) / 60).rounded()))
        return hours == 1 ? "in the last hour" : "in the last \(hours) hours"
    }
    return minutes == 1 ? "in the last minute" : "in the last \(minutes) minutes"
}

