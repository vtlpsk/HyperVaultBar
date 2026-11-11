import Foundation

enum Money {
    static func format(_ value: Decimal, decimals: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        if decimals == 0 { formatter.roundingMode = .down }
        return formatter.string(from: value as NSDecimalNumber) ?? "—"
    }
    static func signed(_ value: Decimal) -> String { "\(value >= 0 ? "+" : "−")\(format(abs(value)))" }
    static func percent(_ value: Decimal, base: Decimal, signed: Bool = false) -> String {
        guard base != 0 else { return "—" }
        let number = NSDecimalNumber(decimal: value / base * 100).doubleValue
        let prefix = signed && number != 0 ? (number > 0 ? "+" : "−") : ""
        return prefix + String(format: "%.1f%%", abs(number))
    }
    static func significantPercent(_ value: Decimal, base: Decimal, signed: Bool = false) -> String? {
        guard base != 0, abs(value / base * 100) >= Decimal(1) / Decimal(10) else { return nil }
        return percent(value, base: base, signed: signed)
    }
    static func apr(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? "—"
    }
}
