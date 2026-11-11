import Foundation

struct DrawdownAlertState {
    private(set) var armed: Bool

    init(armed: Bool = true) { self.armed = armed }

    mutating func shouldNotify(current: Decimal, peak: Decimal, threshold: Decimal, enabled: Bool) -> Bool {
        guard peak > 0, threshold > 0 else { return false }
        let drawdown = (peak - current) / peak * 100
        if drawdown < threshold / 2 { armed = true }
        guard enabled, armed, drawdown >= threshold else { return false }
        armed = false
        return true
    }

    mutating func reset() { armed = true }
}

struct MovementAlertConfiguration: Codable, Equatable {
    var enabled = false
    var threshold: Double
    var window: Double
    var cooldown: Double = 1800
    var direction = "both"

    var valid: Bool {
        threshold.isFinite && threshold > 0 && window >= 60 && window <= 86400 &&
        cooldown >= 60 && cooldown <= 86400 && ["both", "up", "down"].contains(direction)
    }
}

/// Persisted separately for each wallet/vault; failed deliveries leave the crossing armed.
struct MovementAlertHistory: Codable {
    struct Point: Codable { let date: Date; let value: Decimal }
    var configuration: MovementAlertConfiguration?
    var points: [Point] = []
    var lastSent: Date?
    var lastDirection = 0
    var armed = true

    mutating func record(_ value: Decimal, at now: Date) {
        points.removeAll { $0.date < now.addingTimeInterval(-2 * 86400) }
        points.append(Point(date: now, value: value))
    }

    func comparisonPoint(at now: Date, window: Double) -> Point? {
        let target = now.addingTimeInterval(-window)
        // Require a nearly complete window, but tolerate small request-time jitter.
        let jitter = min(30, window * 0.05)
        guard let first = points.first, now.timeIntervalSince(first.date) >= window - jitter else { return nil }
        return points.filter { $0.date < now && now.timeIntervalSince($0.date) >= window - jitter }
            .min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
            .flatMap { abs($0.date.timeIntervalSince(target)) <= max(120, window / 2) ? $0 : nil }
    }

    mutating func candidate(current: Decimal, at now: Date, config: MovementAlertConfiguration,
                            flows: [VaultCashFlow]? = nil) -> (change: Decimal, previous: Decimal, elapsed: Double)? {
        guard config.enabled, config.valid else { return nil }
        guard let baseline = comparisonPoint(at: now, window: config.window) else { return nil }
        let netFlow = flows.map { FlowAdjustedMetrics.netFlows(after: baseline.date, through: now, flows: $0) } ?? 0
        let difference = current - baseline.value - netFlow
        let magnitude: Decimal
        if flows != nil {
            guard baseline.value > 0 else { return nil }
            magnitude = difference / baseline.value * 100
        } else { magnitude = difference * 100 } // APR fractions -> percentage points.
        let sign = magnitude >= 0 ? 1 : -1
        if abs(magnitude) < Decimal(config.threshold / 2) || sign != lastDirection { armed = true }
        guard armed, abs(magnitude) >= Decimal(config.threshold),
              config.direction == "both" || (config.direction == "up" && sign > 0) || (config.direction == "down" && sign < 0),
              lastSent.map({ now.timeIntervalSince($0) >= config.cooldown }) ?? true else { return nil }
        return (magnitude, baseline.value, now.timeIntervalSince(baseline.date))
    }

    mutating func delivered(at now: Date, change: Decimal) {
        lastSent = now
        lastDirection = change >= 0 ? 1 : -1
        armed = false
    }
}
