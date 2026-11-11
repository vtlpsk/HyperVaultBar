import Foundation

enum FlowAdjustedMetrics {
    static func netFlows(after date: Date, through now: Date, flows: [VaultCashFlow]) -> Decimal {
        flows.filter { $0.date > date && $0.date <= now }
            .reduce(.zero) { $0 + $1.amount }
    }

    static func change(current: Decimal, from snapshot: EquitySnapshot,
                       at now: Date, flows: [VaultCashFlow]) -> Decimal {
        current - snapshot.equity - netFlows(after: snapshot.date, through: now, flows: flows)
    }

    static func adjustedPeak(snapshots: [EquitySnapshot], at now: Date,
                             flows: [VaultCashFlow]) -> Decimal? {
        snapshots.filter { $0.date >= now.addingTimeInterval(-7 * 86_400) }
            .map { $0.equity + netFlows(after: $0.date, through: now, flows: flows) }
            .filter { $0 > 0 }
            .max()
    }
}
