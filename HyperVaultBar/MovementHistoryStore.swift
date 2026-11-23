import Foundation

/// Persists movement alert samples and delivery state for each wallet and vault.
struct MovementHistoryStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(kind: String, wallet: String, vault: String) throws -> MovementAlertHistory {
        let key = key(kind: kind, wallet: wallet, vault: vault)
        guard let stored = defaults.object(forKey: key) else { return MovementAlertHistory() }
        guard let data = stored as? Data else { throw CocoaError(.coderReadCorrupt) }
        return try JSONDecoder().decode(MovementAlertHistory.self, from: data)
    }

    func archiveUnreadableHistory(kind: String, wallet: String, vault: String) {
        let key = key(kind: kind, wallet: wallet, vault: vault)
        guard let stored = defaults.object(forKey: key) else { return }
        defaults.set(stored, forKey: key + ".corrupt-" + UUID().uuidString)
        defaults.removeObject(forKey: key)
    }

    func save(_ history: MovementAlertHistory, kind: String, wallet: String, vault: String) throws {
        let data = try JSONEncoder().encode(history)
        defaults.set(data, forKey: key(kind: kind, wallet: wallet, vault: vault))
    }

    private func key(kind: String, wallet: String, vault: String) -> String {
        "movement.\(kind).\(wallet.lowercased()).\(vault.lowercased())"
    }
}
