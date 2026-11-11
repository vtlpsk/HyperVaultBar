import Foundation
import XCTest

final class HyperVaultBarTests: XCTestCase {
    private let vault = "0xdfc24b077bc1425ad1dea75bcb6f8158e10df303"
    private let walletA = "0x1111111111111111111111111111111111111111"
    private let walletB = "0x2222222222222222222222222222222222222222"

    @MainActor
    func testNewSettingsDefaultTo15Minutes() {
        let suite = "HyperVaultBarDefaults-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SettingsStore(defaults: defaults).refreshInterval, 900)
        XCTAssertEqual(SettingsStore(defaults: defaults).walletAddress, "")
    }

    func testEquityDecodingFiltersAndSums() throws {
        let rows: [[String: Any]] = [
            ["vaultAddress": vault, "equity": "100.25"],
            ["vaultAddress": vault.uppercased(), "equity": "2.75"],
            ["vaultAddress": walletA, "equity": "900"]
        ]
        XCTAssertEqual(try BalanceService.decodeEquity(rows, vaultAddress: vault).equity, Decimal(103))
        XCTAssertTrue(try BalanceService.decodeEquity(rows, vaultAddress: vault).hasPosition)
        XCTAssertEqual(try BalanceService.decodeEquity([], vaultAddress: vault).equity, .zero)
        XCTAssertFalse(try BalanceService.decodeEquity([], vaultAddress: vault).hasPosition)
        XCTAssertThrowsError(try BalanceService.decodeEquity([["vaultAddress": vault]], vaultAddress: vault))
    }

    func testVaultDetailsDecodesOptionalValues() throws {
        let response: [String: Any] = [
            "name": "Example vault",
            "apr": -0.00023,
            "followerState": ["pnl": "15909.57", "allTimePnl": "19271.55"],
            "portfolio": [["day", ["accountValueHistory": [[1, "150000000.25"], [2, "150000100.75"]]]]]
        ]
        let details = try BalanceService.decodeDetails(response)
        XCTAssertEqual(details.name, "Example vault")
        XCTAssertEqual(details.vaultEquity, Decimal(string: "150000100.75"))
        XCTAssertNotNil(details.vaultEquityAt)
        XCTAssertNotNil(details.apr)

        XCTAssertThrowsError(try BalanceService.decodeDetails([:]))
    }

    func testVaultDetailsAcceptsStringAPRAndIgnoresInvalidOptionalAPR() throws {
        let stringAPR = try BalanceService.decodeDetails(["name": "Vault", "apr": "0.123456789"])
        XCTAssertEqual(stringAPR.apr, Decimal(string: "0.123456789"))
        XCTAssertNil(try BalanceService.decodeDetails(["name": "Vault", "apr": "unavailable"]).apr)
        XCTAssertNil(try BalanceService.decodeDetails(["name": "Vault", "apr": true]).apr)
    }

    func testLedgerRejectsMatchingVaultEntryWithoutMovementType() {
        XCTAssertThrowsError(try BalanceService.decodeFlows(
            [["time": 1000, "delta": ["vault": vault]]], vaultAddress: vault
        )) { error in
            guard case BalanceError.incompleteLedger = error else {
                return XCTFail("Expected incomplete ledger, got \(error)")
            }
        }
    }

    func testSnapshotsArePerWalletAndChooseARecent24HourPoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let first = try SnapshotStore(wallet: walletA, directory: directory)
        try first.append(Decimal(500), at: now.addingTimeInterval(-9 * 86_400))
        try first.append(Decimal(120), at: now.addingTimeInterval(-86_400 + 600))
        try first.append(Decimal(200), at: now.addingTimeInterval(-3_600))
        XCTAssertEqual(first.closestTo24Hours(before: now)?.equity, Decimal(120))
        XCTAssertEqual(first.sevenDayPeak(now: now), Decimal(200))
        XCTAssertEqual(first.snapshots.count, 2) // The point older than 8 days was pruned.
        XCTAssertNil(try SnapshotStore(wallet: walletB, directory: directory).closestTo24Hours(before: now))
        XCTAssertEqual(try SnapshotStore(wallet: walletA, directory: directory).closestTo24Hours(before: now)?.equity, Decimal(120))
    }

    func testLegacySnapshotsMigrateToTheCurrentWallet() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("HyperVaultBar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = folder.appendingPathComponent("snapshots.json")
        try JSONEncoder().encode([EquitySnapshot(date: .now, equity: Decimal(42))]).write(to: legacy)
        XCTAssertEqual(try SnapshotStore(wallet: walletA, directory: directory).snapshots.first?.equity, Decimal(42))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(try SnapshotStore(wallet: walletB, directory: directory).snapshots.isEmpty)
    }

    func testCorruptedStoresPreserveFilesAndRecover() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("HyperVaultBar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshotURL = folder.appendingPathComponent("snapshots-\(walletA)-\(vault).json")
        let ledgerURL = folder.appendingPathComponent("flows-\(walletA)-\(vault).json")
        let broken = Data("invalid JSON".utf8)
        try broken.write(to: snapshotURL)
        try broken.write(to: ledgerURL)
        XCTAssertThrowsError(try SnapshotStore(wallet: walletA, directory: directory))
        let snapshots = try SnapshotStore(wallet: walletA, directory: directory, recoverCorrupted: true)
        try snapshots.append(42)
        XCTAssertEqual(try SnapshotStore(wallet: walletA, directory: directory).snapshots.count, 1)
        let ledger = try VaultFlowStore(wallet: walletA, vault: vault, directory: directory)
        let now = Date()
        _ = try await ledger.flows(since: now.addingTimeInterval(-100), through: now) { _, _ in [] }
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(backups.count, 2)
        for backup in backups { XCTAssertEqual(try Data(contentsOf: backup), broken) }
    }

    func testSnapshotWriteErrorIsReported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnapshotStore(wallet: walletA, directory: directory)
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try store.append(Decimal(10)))
    }

    func testFiveMinuteSamplingAndVaultIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let first = try SnapshotStore(wallet: walletA, vault: vault, directory: directory)
        try first.append(100, at: now)
        try first.append(99, at: now.addingTimeInterval(15))
        XCTAssertEqual(first.snapshots.count, 1)
        try first.append(102, at: now.addingTimeInterval(300))
        XCTAssertEqual(first.snapshots.count, 2)
        let other = try SnapshotStore(wallet: walletA, vault: walletB, directory: directory)
        XCTAssertTrue(other.snapshots.isEmpty)
    }

    func testNewPeakIsStoredBetweenRegularSamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let store = try SnapshotStore(wallet: walletA, directory: directory)
        try store.append(100, at: now)
        try store.append(110, at: now.addingTimeInterval(15))
        try store.append(90, at: now.addingTimeInterval(30))
        XCTAssertEqual(store.snapshots.count, 2)
        XCTAssertEqual(store.sevenDayPeak(now: now.addingTimeInterval(30)), 110)
    }

    func testLedgerCacheFetchesOnlyMissingRangeAndPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultFlowStore(wallet: walletA, vault: vault, directory: directory)
        let start = Date(timeIntervalSince1970: 1_000)
        let firstEnd = start.addingTimeInterval(7_200)
        let secondEnd = firstEnd.addingTimeInterval(60)
        let first = try await store.flows(since: start, through: firstEnd) { _, _ in
            [VaultCashFlow(date: start.addingTimeInterval(10), amount: 5)]
        }
        XCTAssertEqual(first.count, 1)
        let restored = try VaultFlowStore(wallet: walletA, vault: vault, directory: directory)
        let second = try await restored.flows(since: start, through: secondEnd) { fetchedStart, _ in
            XCTAssertEqual(fetchedStart, firstEnd.addingTimeInterval(-3600))
            return [VaultCashFlow(date: firstEnd.addingTimeInterval(-10), amount: 3), VaultCashFlow(date: firstEnd.addingTimeInterval(10), amount: -2)]
        }
        XCTAssertEqual(second.map(\.amount), [5, 3, -2])
    }

    func testLedgerSplitHandlesFullPageWithoutMissingBoundary() async throws {
        let result = try await BalanceService.fetchFlowRange(wallet: walletA, vaultAddress: vault, start: 1000, end: 1001) { body in
            let start = body["startTime"] as? Int64
            let end = body["endTime"] as? Int64
            if start != end { return Array(repeating: ["unused": 1], count: 500) }
            return [["time": NSNumber(value: start ?? 0), "delta": ["type": "vaultDeposit", "vault": self.vault, "usdc": "1"]]]
        }
        XCTAssertEqual(result.count, 2)
    }

    func testLedgerRetryKeepsPreviousCoverageAndDuplicateTransactions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 10_000)
        let end = start.addingTimeInterval(7200)
        let store = try VaultFlowStore(wallet: walletA, vault: vault, directory: directory)
        _ = try await store.flows(since: start, through: end) { _, _ in [] }
        do {
            _ = try await store.flows(since: start, through: end.addingTimeInterval(60)) { _, _ in
                throw URLError(.timedOut)
            }
            XCTFail("Expected a network failure")
        } catch is URLError { }
        let restored = try VaultFlowStore(wallet: walletA, vault: vault, directory: directory)
        let repeated = VaultCashFlow(date: end.addingTimeInterval(-10), amount: 5)
        let result = try await restored.flows(since: start, through: end.addingTimeInterval(60)) { from, _ in
            XCTAssertEqual(from, end.addingTimeInterval(-3600))
            return [repeated, repeated]
        }
        XCTAssertEqual(result.count, 2)
    }

    func testCashFlowAdjustedPeakAfterWithdrawal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let store = try SnapshotStore(wallet: walletA, directory: directory)
        try store.append(100, at: now)
        let later = now.addingTimeInterval(15)
        let flows = [VaultCashFlow(date: now.addingTimeInterval(5), amount: -50)]
        let peak = FlowAdjustedMetrics.adjustedPeak(snapshots: store.snapshots, at: later, flows: flows)
        XCTAssertEqual(peak, 50)
        if let peak, Decimal(55) > peak { try store.append(55, at: later, force: true) }
        XCTAssertEqual(store.snapshots.count, 2)
        XCTAssertEqual(FlowAdjustedMetrics.adjustedPeak(snapshots: store.snapshots, at: later, flows: flows), 55)
    }

    func testVaultFlowsAdjustChangeAndPeak() throws {
        let now = Date()
        let snapshot = EquitySnapshot(date: now.addingTimeInterval(-86_400), equity: 100)
        let rows: [[String: Any]] = [
            ["time": NSNumber(value: Int64(now.addingTimeInterval(-43_200).timeIntervalSince1970 * 1_000)),
             "delta": ["type": "vaultDeposit", "vault": vault, "usdc": "50.0"]],
            ["time": NSNumber(value: Int64(now.addingTimeInterval(-21_600).timeIntervalSince1970 * 1_000)),
             "delta": ["type": "vaultWithdraw", "vault": vault, "netWithdrawnUsd": "10.0"]],
            ["time": NSNumber(value: Int64(now.timeIntervalSince1970 * 1_000)),
             "delta": ["type": "deposit", "usdc": "1000.0"]]
        ]
        let flows = try BalanceService.decodeFlows(rows, vaultAddress: vault)
        XCTAssertEqual(flows.count, 2)
        XCTAssertEqual(FlowAdjustedMetrics.change(current: 135, from: snapshot, at: now, flows: flows), Decimal(-5))
        XCTAssertEqual(FlowAdjustedMetrics.adjustedPeak(snapshots: [snapshot], at: now, flows: flows), Decimal(140))
        XCTAssertThrowsError(try BalanceService.decodeFlows([
            ["time": NSNumber(value: 1), "delta": ["type": "vaultDistribution", "vault": vault, "usdc": "1"]]
        ], vaultAddress: vault))
    }

    func testMovementComparisonToleratesRequestJitterAndReportsElapsed() {
        let now = Date(timeIntervalSince1970: 100000)
        var history = MovementAlertHistory()
        history.record(100, at: now.addingTimeInterval(-1800))
        history.record(100, at: now.addingTimeInterval(-897))
        history.record(101, at: now)
        var config = MovementAlertConfiguration(threshold: 0.1, window: 900)
        config.enabled = true
        let result = history.candidate(current: 101, at: now, config: config, flows: [])
        XCTAssertEqual(result?.elapsed, 897)
        XCTAssertEqual(result?.change, 1)
        var sparse = MovementAlertHistory()
        sparse.record(100, at: now.addingTimeInterval(-1800))
        sparse.record(101, at: now)
        XCTAssertNil(sparse.candidate(current: 101, at: now, config: config, flows: []))
    }

    func testMovementBalanceExcludesDepositsAndSuppressesRepeatedCrossing() {
        let now = Date(timeIntervalSince1970: 100000)
        var history = MovementAlertHistory()
        history.record(1000, at: now.addingTimeInterval(-900))
        var config = MovementAlertConfiguration(threshold: 0.1, window: 900)
        config.enabled = true
        let flows = [VaultCashFlow(date: now.addingTimeInterval(-10), amount: 500)]
        XCTAssertNil(history.candidate(current: 1500, at: now, config: config, flows: flows))
        let movement = history.candidate(current: 1498, at: now, config: config, flows: flows)
        XCTAssertEqual(movement?.change, Decimal(string: "-0.2"))
        history.delivered(at: now, change: -0.2)
        XCTAssertNil(history.candidate(current: 1490, at: now, config: config, flows: flows))
    }

    func testAPRMovementUsesPercentagePointsAndDirection() {
        let now = Date(timeIntervalSince1970: 100000)
        var history = MovementAlertHistory()
        history.record(Decimal(string: "0.08") ?? 0, at: now.addingTimeInterval(-3600))
        var config = MovementAlertConfiguration(threshold: 1, window: 3600)
        config.enabled = true
        XCTAssertEqual(history.candidate(current: 0.10, at: now, config: config)?.change, 2)
        config.direction = "down"
        XCTAssertNil(history.candidate(current: 0.10, at: now, config: config))
        XCTAssertNil(history.candidate(current: 0.10, at: now.addingTimeInterval(-60), config: config))
    }

    func testMovementRearmsButRespectsCooldownAndSurvivesEncoding() throws {
        let now = Date(timeIntervalSince1970: 100000)
        var history = MovementAlertHistory()
        history.record(0.08, at: now.addingTimeInterval(-3600))
        var config = MovementAlertConfiguration(threshold: 1, window: 3600)
        config.enabled = true
        history.delivered(at: now, change: 2)
        XCTAssertNil(history.candidate(current: 0.081, at: now, config: config))
        XCTAssertTrue(history.armed)
        XCTAssertNil(history.candidate(current: 0.10, at: now, config: config))
        history = try JSONDecoder().decode(MovementAlertHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(history.lastSent, now)
        history.record(0.08, at: now.addingTimeInterval(-1800))
        XCTAssertNotNil(history.candidate(current: 0.10, at: now.addingTimeInterval(1800), config: config))
    }

    func testDrawdownNotifiesOnceAndRearmsBelowHalfThreshold() {
        var state = DrawdownAlertState()
        XCTAssertTrue(state.shouldNotify(current: 94, peak: 100, threshold: 5, enabled: true))
        XCTAssertFalse(state.shouldNotify(current: 90, peak: 100, threshold: 5, enabled: true))
        XCTAssertFalse(state.shouldNotify(current: 97, peak: 100, threshold: 5, enabled: true))
        XCTAssertFalse(state.shouldNotify(current: 98, peak: 100, threshold: 5, enabled: true))
        XCTAssertTrue(state.shouldNotify(current: 94, peak: 100, threshold: 5, enabled: true))
        state.reset()
        XCTAssertFalse(state.shouldNotify(current: 90, peak: 100, threshold: 5, enabled: false))
    }
}
