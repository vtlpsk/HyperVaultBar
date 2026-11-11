import Foundation
import XCTest

private actor StubBalanceService: BalanceProviding {
    var equityCalls = 0
    let failEquity: Bool
    let rateLimitDetails: Bool
    init(failEquity: Bool = false, rateLimitDetails: Bool = false) {
        self.failEquity = failEquity
        self.rateLimitDetails = rateLimitDetails
    }
    func fetchEquity(wallet: String, vaultAddress: String) async throws -> VaultPosition {
        equityCalls += 1
        // Deliberately return even after cancellation to verify obsolete results are rejected.
        try? await Task.sleep(for: .milliseconds(80))
        if failEquity { throw URLError(.timedOut) }
        return VaultPosition(equity: wallet.hasSuffix("1") ? 100 : 200, hasPosition: true)
    }
    func fetchDetails(wallet: String, vaultAddress: String) async throws -> VaultDetails {
        if rateLimitDetails { throw BalanceError.rateLimited }
        return VaultDetails(name: "Test vault", vaultEquity: 1000, vaultEquityAt: .now, apr: 0.1)
    }
    func fetchVaultFlows(wallet: String, vaultAddress: String, since: Date, until: Date) async throws -> [VaultCashFlow] { [] }
}

@MainActor
final class RefreshTests: XCTestCase {
    private func withModel(_ test: (BalanceViewModel, StubBalanceService, UserDefaults) async throws -> Void,
                           failEquity: Bool = false, rateLimitDetails: Bool = false) async throws {
        let suite = "RefreshTests-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("Missing defaults") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(defaults: defaults)
        settings.walletAddress = "0x1111111111111111111111111111111111111111"
        let service = StubBalanceService(failEquity: failEquity, rateLimitDetails: rateLimitDetails)
        let model = BalanceViewModel(settings: settings, service: service, directory: directory,
                                     autoStart: false, applyLogin: { _ in }, requestPermission: { false })
        try await test(model, service, defaults)
    }

    func testRepeatedRefreshDoesNotCancelSlowRequest() async throws {
        try await withModel { model, service, _ in
            model.refresh()
            try await Task.sleep(for: .milliseconds(20))
            model.refresh()
            await model.waitForRefresh()
            let calls = await service.equityCalls
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(model.balance, 100)
            XCTAssertFalse(model.stale)
        }
    }

    func testFailedEquityDoesNotBlockVaultDetails() async throws {
        try await withModel({ model, _, _ in
            model.refresh()
            await model.waitForRefresh()
            XCTAssertTrue(model.stale)
            XCTAssertEqual(model.vaultAPR, 0.1)
            XCTAssertFalse(model.vaultDetailsStale)
        }, failEquity: true)
    }

    func testRateLimitedDetailsSuppressesNextRefreshDespiteSuccessfulEquity() async throws {
        try await withModel({ model, service, _ in
            model.refresh()
            await model.waitForRefresh()
            XCTAssertEqual(model.balance, 100)
            XCTAssertTrue(model.vaultDetailsStale)
            model.refresh()
            await model.waitForRefresh()
            let calls = await service.equityCalls
            XCTAssertEqual(calls, 1)
        }, rateLimitDetails: true)
    }

    func testReplacementRejectsOldWalletResponse() async throws {
        try await withModel { model, _, _ in
            model.refresh()
            try await Task.sleep(for: .milliseconds(20))
            model.settings.walletAddress = "0x2222222222222222222222222222222222222222"
            model.refresh(replacing: true)
            await model.waitForRefresh()
            XCTAssertEqual(model.balance, 200)
        }
    }

    func testWakeReplacesInFlightRefresh() async throws {
        try await withModel { model, service, _ in
            model.refresh()
            try await Task.sleep(for: .milliseconds(20))
            model.handleWake()
            await model.waitForRefresh()
            let calls = await service.equityCalls
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(model.balance, 100)
            XCTAssertFalse(model.stale)
        }
    }

    func testPermissionDenialStillSavesSettings() async throws {
        try await withModel { model, _, _ in
            var movement = model.settings.balanceMovement
            movement.enabled = true
            try await model.applySettings(wallet: model.settings.walletAddress, vault: model.settings.vaultAddress,
                                          interval: 300, enabled: false, threshold: 5, login: false,
                                          balanceMovement: movement, aprMovement: model.settings.aprMovement)
            await model.waitForRefresh()
            XCTAssertEqual(model.settings.refreshInterval, 300)
            XCTAssertTrue(model.settings.balanceMovement.enabled)
            XCTAssertNotNil(model.notificationError)
        }
    }
}
