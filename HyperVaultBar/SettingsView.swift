import SwiftUI

private let alertThresholdFieldWidth: CGFloat = 80

struct SettingsView: View {
    @ObservedObject var model: BalanceViewModel
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var wallet = ""
    @State private var editingWallet = false
    @State private var walletDraft = ""
    @State private var customVault = false
    @State private var vaultAddress = ""
    @State private var intervalChoice: TimeInterval = 900
    @State private var customSeconds = 900
    @State private var alerts = false
    @State private var threshold = 5.0
    @State private var login = false
    @State private var reduceTransparency = false
    @State private var saving = false
    @State private var balanceMovement = MovementAlertConfiguration(threshold: 0.1, window: 900)
    @State private var aprMovement = MovementAlertConfiguration(threshold: 1, window: 3600)
    @State private var saveError: String?
    @State private var testMessage: String?

    private var selectedVault: String { customVault ? vaultAddress : SettingsStore.hlpAddress }

    private var valid: Bool {
        !editingWallet && (!balanceMovement.enabled || balanceMovement.valid) &&
        (!aprMovement.enabled || aprMovement.valid) && SettingsStore.validWallet(wallet) &&
        SettingsStore.validAddress(selectedVault) &&
        (!alerts || (threshold >= 0.1 && threshold <= 100)) &&
        (intervalChoice != -1 || customSeconds >= 15)
    }

    private var validationMessage: String? {
        if editingWallet { return "Confirm or cancel the wallet change to save settings." }
        if wallet.isEmpty { return "Enter your wallet address to save settings." }
        if !SettingsStore.validWallet(wallet) { return "Check the wallet address above." }
        if customVault && vaultAddress.isEmpty { return "Enter the custom vault address to save settings." }
        if !SettingsStore.validAddress(selectedVault) { return "Check the vault address above." }
        if intervalChoice == -1 && customSeconds < 15 { return "Choose a refresh interval of at least 15 seconds." }
        if alerts && (threshold < 0.1 || threshold > 100) { return "Choose a drawdown threshold from 0.1% to 100%." }
        if (balanceMovement.enabled && !balanceMovement.valid) ||
            (aprMovement.enabled && !aprMovement.valid) { return "Check the notification thresholds above." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").font(.title2.weight(.semibold))
                    Text("Manage your vault and alerts")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image("HyperFoundationLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("Hyperliquid logo")
            }
            .padding(.bottom, 18)

            ScrollView {
                VStack(spacing: 14) {
                    SettingsSection("Wallet", symbol: "wallet.pass") {
                        if editingWallet || wallet.isEmpty {
                            HStack {
                                TextField("0x…", text: editingWallet ? $walletDraft : $wallet)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .accessibilityLabel("Wallet address")
                                if editingWallet {
                                    Button("Cancel") { editingWallet = false }
                                        .fixedSize()
                                    Button("Change") {
                                        wallet = walletDraft
                                        editingWallet = false
                                    }
                                    .fixedSize()
                                    .disabled(!SettingsStore.validWallet(walletDraft))
                                }
                            }
                        } else {
                            HStack(spacing: 12) {
                                Text(wallet)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Change wallet") {
                                    walletDraft = wallet
                                    editingWallet = true
                                }
                                    .fixedSize()
                                    .frame(width: 290, alignment: .trailing)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        Text("Public address used to read your vault position.")
                            .font(.caption).foregroundStyle(.secondary)
                        let visibleWallet = editingWallet ? walletDraft : wallet
                        if !visibleWallet.isEmpty && !SettingsStore.validWallet(visibleWallet) {
                            Text("Enter 0x followed by 40 hexadecimal characters.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }

                    SettingsSection("Vault", symbol: "building.columns") {
                        HStack {
                            Text("Track")
                            Spacer(minLength: 16)
                            Picker("Vault", selection: $customVault) {
                                Text("Hyperliquidity Provider (HLP)").tag(false)
                                Text("Custom vault").tag(true)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .frame(width: 290, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity)
                        if customVault {
                            TextField("0x…", text: $vaultAddress)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .accessibilityLabel("Vault address")
                            if !vaultAddress.isEmpty && !SettingsStore.validAddress(vaultAddress) {
                                Text("Enter a vault address beginning with 0x and 40 hexadecimal characters.")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                        Text("The menu bar shows your position in this vault.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    SettingsSection("Updates", symbol: "arrow.clockwise") {
                        HStack(spacing: 12) {
                            Text("Refresh interval")
                            Spacer(minLength: 16)
                            Picker("Refresh interval", selection: $intervalChoice) {
                                ForEach(SettingsStore.intervals, id: \.self) { value in
                                    Text(intervalName(value)).tag(value)
                                }
                                Text("Custom…").tag(TimeInterval(-1))
                            }
                            .labelsHidden()
                            .fixedSize()
                            .frame(width: 290, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity)
                        if intervalChoice == -1 {
                            HStack(spacing: 8) {
                                Text("Custom interval")
                                Spacer(minLength: 16)
                                TextField("Seconds", value: $customSeconds, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                Text("seconds").foregroundStyle(.secondary)
                            }
                        }
                        Text("Minimum 15 seconds. The new interval starts when you save.")
                            .font(.caption).foregroundStyle(.secondary)
                        if intervalChoice == -1 && customSeconds < 15 {
                            Text("Choose at least 15 seconds.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }

                    SettingsSection("Notifications", symbol: "bell") {
                        Toggle("Drawdown alerts", isOn: $alerts)
                        if alerts {
                        HStack(spacing: 8) {
                            Text("Alert threshold")
                            Spacer(minLength: 16)
                            TextField("Percent", value: $threshold, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: alertThresholdFieldWidth)
                            Stepper("Drawdown threshold", value: $threshold, in: 0.1...100, step: 0.1)
                                .labelsHidden()
                            Text("%").foregroundStyle(.secondary)
                        }
                        Text("Drop below the 7-day peak.")
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        MovementAlertEditor(title: "Balance movement", unit: "%", config: $balanceMovement, status: model.movementStatus(kind: "balance", config: balanceMovement), notificationError: model.notificationError, refreshInterval: intervalChoice == -1 ? TimeInterval(customSeconds) : intervalChoice)
                        Divider()
                        MovementAlertEditor(title: "APR movement", unit: "%pt", config: $aprMovement, status: model.movementStatus(kind: "apr", config: aprMovement), notificationError: model.notificationError, refreshInterval: intervalChoice == -1 ? TimeInterval(customSeconds) : intervalChoice)
                        Divider()
                        Button("Send test notification") {
                            testMessage = nil
                            Task {
                                do {
                                    try await model.sendTestNotification()
                                    testMessage = "Test notification sent."
                                } catch { testMessage = error.localizedDescription }
                            }
                        }
                        if let testMessage {
                            Text(testMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        if alerts && (threshold < 0.1 || threshold > 100) {
                            Text("Choose a threshold from 0.1% to 100%.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }

                    SettingsSection("Startup", symbol: "power") {
                        HStack {
                            Text("Launch at login")
                            Spacer()
                            Toggle("Launch at login", isOn: $login)
                                .labelsHidden()
                        }
                        Text("Start HyperVaultBar automatically when you sign in.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SettingsSection("Appearance", symbol: "circle.lefthalf.filled") {
                        Toggle("Reduce transparency", isOn: $reduceTransparency)
                        Text("Use a solid background in the menu bar popup.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 2)
                .padding(.trailing, 30)
                .padding(.vertical, 2)
            }
            .padding(.trailing, -18)

            Divider().padding(.vertical, 16)
            HStack {
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                        .lineLimit(2)
                } else if let validationMessage {
                    Text(validationMessage).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Changes take effect when you save")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .frame(minWidth: 72)
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("Save") {
                    let interval = intervalChoice == -1 ? TimeInterval(customSeconds) : intervalChoice
                    saving = true
                    saveError = nil
                    Task {
                        do {
                            try await model.applySettings(wallet: wallet, vault: selectedVault,
                                                          interval: interval, enabled: alerts,
                                                          threshold: threshold, login: login,
                                                          balanceMovement: balanceMovement, aprMovement: aprMovement)
                            UserDefaults.standard.set(reduceTransparency, forKey: "reduceTransparency")
                            onSave()
                        } catch {
                            saveError = error.localizedDescription
                        }
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .frame(minWidth: 72)
                .disabled(!valid || saving)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("HyperVaultBar is an independent app and is not affiliated with or endorsed by Hyperliquid.")
                Spacer(minLength: 12)
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("Version \(version)").fixedSize()
                }
            }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
        }
        .padding(24)
        .controlSize(.regular)
        .frame(width: 660, height: 700)
        .onAppear {
            model.settings.refreshLoginStatus()
            wallet = model.settings.walletAddress
            editingWallet = false
            customVault = model.settings.vaultAddress.caseInsensitiveCompare(SettingsStore.hlpAddress) != .orderedSame
            vaultAddress = model.settings.vaultAddress
            let savedInterval = model.settings.refreshInterval
            intervalChoice = SettingsStore.intervals.contains(savedInterval) ? savedInterval : -1
            customSeconds = savedInterval < Double(Int.max) ? Int(savedInterval) : 900
            balanceMovement = model.settings.balanceMovement
            aprMovement = model.settings.aprMovement
            alerts = model.settings.alertsEnabled
            threshold = model.settings.alertThreshold
            login = model.settings.launchAtLogin
            reduceTransparency = UserDefaults.standard.bool(forKey: "reduceTransparency")
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
    }
}

private struct MovementAlertEditor: View {
    let title: String
    let unit: String
    @Binding var config: MovementAlertConfiguration
    let status: String
    let notificationError: String?
    let refreshInterval: TimeInterval
    @State private var showsUnitHelp = false

    private var visibleWarning: String? {
        if status.hasPrefix("Paused:") || status == notificationError { return status }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(title, isOn: $config.enabled)
            if config.enabled {
                if let visibleWarning {
                    Text(visibleWarning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Threshold")
                    Spacer()
                    TextField("Threshold", value: $config.threshold, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: alertThresholdFieldWidth)
                    Stepper("\(title) threshold", value: $config.threshold,
                            in: 0.1...Double.greatestFiniteMagnitude, step: 0.1)
                        .labelsHidden()
                    if unit == "%pt" {
                        Text(unit)
                            .foregroundStyle(.secondary)
                            .onHover { showsUnitHelp = $0 }
                            .overlay(alignment: .bottomTrailing) {
                                if showsUnitHelp {
                                    Text("Percentage point")
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                        .fixedSize()
                                        .padding(6)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                                        .shadow(radius: 3)
                                        .alignmentGuide(.bottom) { $0[.top] - 5 }
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityLabel("Percentage points")
                    } else {
                        Text(unit).foregroundStyle(.secondary)
                    }
                }
                .zIndex(showsUnitHelp ? 1 : 0)
                Text("Over \(intervalName(config.window)) · \(config.direction == "both" ? "Both directions" : config.direction == "up" ? "Increase" : "Decrease")")
                    .font(.caption).foregroundStyle(.secondary)
                if refreshInterval > config.window {
                    Text("For this comparison, set the refresh interval to \(intervalName(config.window)) or less.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Direction", selection: $config.direction) {
                            Text("Both").tag("both")
                            Text("Increase").tag("up")
                            Text("Decrease").tag("down")
                        }
                        Picker("Compare over", selection: $config.window) {
                            ForEach([300.0, 900, 1800, 3600, 14400, 86400], id: \.self) { seconds in
                                Text(intervalName(seconds)).tag(seconds)
                            }
                        }
                        Picker("Minimum pause", selection: $config.cooldown) {
                            ForEach([300.0, 900, 1800, 3600, 14400, 86400], id: \.self) { seconds in
                                Text(intervalName(seconds)).tag(seconds)
                            }
                        }
                        if visibleWarning == nil {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        if unit == "%" {
                            Text("Deposits and withdrawals are excluded.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 8)
                }
                if !config.valid { Text("Enter a positive threshold.").font(.caption).foregroundStyle(.red) }
            }
        }
    }
}
