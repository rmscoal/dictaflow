import Foundation

/// Small helpers for the audio benchmark report. Medians only: run counts are
/// too small for percentile claims.
public enum LiquidBenchmarkStatistics: Sendable {
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}
