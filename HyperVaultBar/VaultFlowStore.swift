import Foundation

/// A verified, contiguous ledger range for one wallet and vault.
final class VaultFlowStore {
    private struct State: Codable {
        var version: Int?
        var coveredFrom: Date
        var coveredThrough: Date
        var flows: [VaultCashFlow]
    }

    private let url: URL
    private var state: State?

    init(wallet: String, vault: String, directory: URL? = nil) throws {
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("HyperVaultBar", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("flows-\(wallet.lowercased())-\(vault.lowercased()).json")
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            do {
                let decoded = try JSONDecoder().decode(State.self, from: data)
                if decoded.version == 2 { state = decoded }
            } catch is DecodingError {
                try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt-" + UUID().uuidString))
            }
        }
    }

    func flows(since: Date, through: Date,
               fetch: (Date, Date) async throws -> [VaultCashFlow]) async throws -> [VaultCashFlow] {
        let usable = state.flatMap { $0.coveredFrom <= since && $0.coveredThrough <= through ? $0 : nil }
        // Replace the overlapping window wholesale: this preserves identical legitimate
        // transactions and picks up entries that appeared late in the API.
        let start = usable.map { max(since, $0.coveredThrough.addingTimeInterval(-3600)) } ?? since
        let added = start <= through
            ? try await fetch(start, through)
            : []
        try Task.checkCancellation()
        let combined = (usable?.flows.filter { $0.date < start } ?? []) + added
        let newState = State(version: 2, coveredFrom: since, coveredThrough: through,
                             flows: combined.filter { $0.date >= since && $0.date <= through })
        try JSONEncoder().encode(newState).write(to: url, options: .atomic)
        state = newState
        return newState.flows
    }
}
