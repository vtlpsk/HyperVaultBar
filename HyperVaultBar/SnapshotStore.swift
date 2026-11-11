import Foundation

struct EquitySnapshot: Codable {
    let date: Date
    let equity: Decimal
}

final class SnapshotStore {
    private let url: URL
    private(set) var snapshots: [EquitySnapshot] = []

    init(wallet: String, vault: String = SettingsStore.hlpAddress, directory: URL? = nil, recoverCorrupted: Bool = false) throws {
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("HyperVaultBar", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Each wallet/vault pair keeps its own history.
        url = folder.appendingPathComponent("snapshots-\(wallet.lowercased())-\(vault.lowercased()).json")
        let previous = folder.appendingPathComponent("snapshots-\(wallet.lowercased()).json")
        let legacy = folder.appendingPathComponent("snapshots.json")
        if vault.caseInsensitiveCompare(SettingsStore.hlpAddress) == .orderedSame,
           !FileManager.default.fileExists(atPath: url.path) {
            if FileManager.default.fileExists(atPath: previous.path) {
                try FileManager.default.moveItem(at: previous, to: url)
            } else if FileManager.default.fileExists(atPath: legacy.path) {
                try FileManager.default.moveItem(at: legacy, to: url)
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            do { snapshots = try JSONDecoder().decode([EquitySnapshot].self, from: data) }
            catch is DecodingError where recoverCorrupted {
                try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt-" + UUID().uuidString))
            }
        }
        prune()
    }

    func append(_ equity: Decimal, at date: Date = .now, force: Bool = false) throws {
        // Keep each new seven-day high, even between regular five-minute samples.
        let isNewPeak = equity > (sevenDayPeak(now: date) ?? .zero)
        if let last = snapshots.last, date.timeIntervalSince(last.date) < 300, !isNewPeak, !force { return }
        if snapshots.last?.date == date { return }
        let updated = snapshots.filter { $0.date >= date.addingTimeInterval(-8 * 86_400) }
            + [EquitySnapshot(date: date, equity: equity)]
        let data = try JSONEncoder().encode(updated)
        try data.write(to: url, options: .atomic)
        snapshots = updated
    }

    func closestTo24Hours(before now: Date = .now) -> EquitySnapshot? {
        let target = now.addingTimeInterval(-86_400)
        // A sparse history is not presented as a 24-hour comparison.
        return snapshots.min(by: { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) })
            .flatMap { abs($0.date.timeIntervalSince(target)) <= 3_600 ? $0 : nil }
    }

    func sevenDayPeak(now: Date = .now) -> Decimal? {
        snapshots.filter { $0.date >= now.addingTimeInterval(-7 * 86_400) }
            .map(\.equity).max()
    }

    private func prune(now: Date = .now) {
        snapshots.removeAll { $0.date < now.addingTimeInterval(-8 * 86_400) }
    }
}
