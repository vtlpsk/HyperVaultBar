import CoreFoundation
import Foundation

struct VaultDetails {
    let name: String?
    let vaultEquity: Decimal?
    let vaultEquityAt: Date?
    let apr: Decimal?
}

struct VaultPosition {
    let equity: Decimal
    let hasPosition: Bool
}

struct VaultCashFlow: Codable {
    let date: Date
    let amount: Decimal // Deposit positive, withdrawal negative.
}

enum BalanceError: LocalizedError {
    case invalidResponse, missingEquity, incompleteLedger, rateLimited, serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The vault API returned an invalid response."
        case .missingEquity: "The vault API did not return an equity value."
        case .incompleteLedger: "Vault cash flows could not be verified; drawdown alerts are paused."
        case .rateLimited: "Hyperliquid is limiting requests; retrying later."
        case .serverError(let status): "Hyperliquid returned HTTP \(status)."
        }
    }
}

protocol BalanceProviding {
    func fetchEquity(wallet: String, vaultAddress: String) async throws -> VaultPosition
    func fetchDetails(wallet: String, vaultAddress: String) async throws -> VaultDetails
    func fetchVaultFlows(wallet: String, vaultAddress: String, since: Date, until: Date) async throws -> [VaultCashFlow]
}

struct BalanceService: BalanceProviding {
    private struct EquityRow: Decodable {
        let vaultAddress: String
        let equity: String
    }

    private static func decode<T: Decodable>(_ type: T.Type, response: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: response))
    }

    func fetchEquity(wallet: String, vaultAddress: String) async throws -> VaultPosition {
        let response = try await post(["type": "userVaultEquities", "user": wallet])
        return try Self.decodeEquity(response, vaultAddress: vaultAddress)
    }

    func fetchDetails(wallet: String, vaultAddress: String) async throws -> VaultDetails {
        let response = try await post(["type": "vaultDetails", "vaultAddress": vaultAddress, "user": wallet])
        return try Self.decodeDetails(response)
    }

    func fetchVaultFlows(wallet: String, vaultAddress: String, since: Date, until: Date) async throws -> [VaultCashFlow] {
        try await Self.fetchFlowRange(wallet: wallet, vaultAddress: vaultAddress,
                                 start: Int64(since.timeIntervalSince1970 * 1_000),
                                 end: Int64(until.timeIntervalSince1970 * 1_000), post: post)
    }

    static func fetchFlowRange(wallet: String, vaultAddress: String, start: Int64, end: Int64,
                               post: ([String: Any]) async throws -> Any) async throws -> [VaultCashFlow] {
        let response = try await post([
            "type": "userNonFundingLedgerUpdates",
            "user": wallet,
            "startTime": start,
            "endTime": end
        ])
        guard let rows = response as? [[String: Any]] else { throw BalanceError.invalidResponse }
        if rows.count >= 500 {
            // Split the time range before decoding so unrelated wallet activity cannot hide vault flows.
            guard start < end else { throw BalanceError.incompleteLedger }
            let middle = start + (end - start) / 2
            let left = try await fetchFlowRange(wallet: wallet, vaultAddress: vaultAddress, start: start, end: middle, post: post)
            let right = try await fetchFlowRange(wallet: wallet, vaultAddress: vaultAddress, start: middle + 1, end: end, post: post)
            return left + right
        }
        return try Self.decodeFlows(rows, vaultAddress: vaultAddress)
    }

    static func decodeEquity(_ response: Any, vaultAddress: String) throws -> VaultPosition {
        let rows = try decode([EquityRow].self, response: response)
        var total = Decimal.zero
        var hasPosition = false
        for row in rows where row.vaultAddress.caseInsensitiveCompare(vaultAddress) == .orderedSame {
            guard let value = Decimal(string: row.equity, locale: Locale(identifier: "en_US_POSIX")) else { throw BalanceError.missingEquity }
            hasPosition = true
            total += value
        }
        return VaultPosition(equity: total, hasPosition: hasPosition)
    }

    static func decodeDetails(_ response: Any) throws -> VaultDetails {
        guard let object = response as? [String: Any] else { throw BalanceError.invalidResponse }
        guard object["vaultAddress"] is String || object["name"] is String || object["portfolio"] is [[Any]] else {
            throw BalanceError.invalidResponse
        }
        let apr = decimal(object["apr"])
        var vaultEquity: Decimal?
        var vaultEquityAt: Date?
        if let portfolio = object["portfolio"] as? [[Any]],
           let day = portfolio.first(where: { $0.first as? String == "day" }),
           day.count > 1,
           let history = (day[1] as? [String: Any])?["accountValueHistory"] as? [[Any]],
           let latest = history.last, latest.count > 1 {
            vaultEquity = decimal(latest[1])
            if let timestamp = latest[0] as? NSNumber {
                vaultEquityAt = Date(timeIntervalSince1970: timestamp.doubleValue / 1_000)
            }
        }
        return VaultDetails(name: object["name"] as? String,
                            vaultEquity: vaultEquity,
                            vaultEquityAt: vaultEquityAt,
                            apr: apr)
    }

    static func decodeFlows(_ rows: [[String: Any]], vaultAddress: String) throws -> [VaultCashFlow] {
        var flows: [VaultCashFlow] = []
        for row in rows {
            guard let delta = row["delta"] as? [String: Any],
                  let address = delta["vault"] as? String,
                  address.caseInsensitiveCompare(vaultAddress) == .orderedSame else { continue }
            guard let type = delta["type"] as? String else { throw BalanceError.incompleteLedger }
            let amount: Decimal
            switch type {
            case "vaultDeposit":
                guard let value = decimal(delta["usdc"]) else { throw BalanceError.incompleteLedger }
                amount = value
            case "vaultWithdraw":
                guard let value = decimal(delta["netWithdrawnUsd"]) else { throw BalanceError.incompleteLedger }
                amount = -value
            default:
                // Unknown vault movement must not be silently treated as investment PnL.
                throw BalanceError.incompleteLedger
            }
            guard let timestamp = row["time"] as? NSNumber else { throw BalanceError.incompleteLedger }
            flows.append(VaultCashFlow(date: Date(timeIntervalSince1970: timestamp.doubleValue / 1_000),
                                       amount: amount))
        }
        return flows
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    private func post(_ body: [String: Any]) async throws -> Any {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { throw BalanceError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BalanceError.invalidResponse }
        if http.statusCode == 429 { throw BalanceError.rateLimited }
        if (500..<600).contains(http.statusCode) { throw BalanceError.serverError(http.statusCode) }
        guard (200..<300).contains(http.statusCode) else { throw BalanceError.invalidResponse }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func decimal(_ value: Any?) -> Decimal? {
        if let string = value as? String { return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }
}
