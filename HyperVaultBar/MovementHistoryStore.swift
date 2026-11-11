import Foundation

/// Persists movement alert samples and delivery state for each wallet and vault.
struct MovementHistoryStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(kind: String, wallet: String, vault: String) -> MovementAlertHistory {
        guard let data = defaults.data(forKey: key(kind: kind, wallet: wallet, vault: vault)),
              let history = try? JSONDecoder().decode(MovementAlertHistory.self, from: data) else {
            return MovementAlertHistory()
        }
        return history
    }

    func save(_ history: MovementAlertHistory, kind: String, wallet: String, vault: String) throws {
        let data = try JSONEncoder().encode(history)
        defaults.set(data, forKey: key(kind: kind, wallet: wallet, vault: vault))
    }

    private func key(kind: String, wallet: String, vault: String) -> String {
        "movement.\(kind).\(wallet.lowercased()).\(vault.lowercased())"
    }
}
