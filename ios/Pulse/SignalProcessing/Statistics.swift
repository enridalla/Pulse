import Foundation

/// Small, dependency-free numeric helpers shared across the pipeline. Pure functions only.
enum Statistics {
    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Population standard deviation.
    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
        return variance.squareRoot()
    }

    /// Median absolute deviation, scaled to be a consistent estimator of the std for normal data.
    static func medianAbsoluteDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let m = median(values)
        let deviations = values.map { abs($0 - m) }
        return 1.4826 * median(deviations)
    }

    /// Linear-interpolated percentile (`p` in 0...1).
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let position = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// Root-mean-square.
    static func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sumSquares = values.reduce(0) { $0 + $1 * $1 }
        return (sumSquares / Double(values.count)).squareRoot()
    }

    /// Removes the mean in place-style (returns a new array).
    static func removeMean(_ values: [Double]) -> [Double] {
        let m = mean(values)
        return values.map { $0 - m }
    }

    /// Removes a best-fit straight line (least squares) — linear detrending.
    static func detrendLinear(_ values: [Double]) -> [Double] {
        let n = values.count
        guard n > 2 else { return removeMean(values) }
        // x = 0...n-1
        let nD = Double(n)
        let sumX = nD * (nD - 1) / 2
        let sumX2 = (nD - 1) * nD * (2 * nD - 1) / 6
        var sumY = 0.0
        var sumXY = 0.0
        for (i, y) in values.enumerated() {
            sumY += y
            sumXY += Double(i) * y
        }
        let denominator = nD * sumX2 - sumX * sumX
        guard abs(denominator) > .ulpOfOne else { return removeMean(values) }
        let slope = (nD * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / nD
        return values.enumerated().map { index, y in y - (slope * Double(index) + intercept) }
    }

    /// Pearson correlation between two equal-length signals.
    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let ma = mean(a)
        let mb = mean(b)
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let x = a[i] - ma
            let y = b[i] - mb
            num += x * y
            da += x * x
            db += y * y
        }
        let denominator = (da * db).squareRoot()
        return denominator > .ulpOfOne ? num / denominator : 0
    }

    /// Fraction of `values` for which `predicate` is true.
    static func fraction(_ values: [Double], where predicate: (Double) -> Bool) -> Double {
        guard !values.isEmpty else { return 0 }
        let count = values.reduce(0) { predicate($1) ? $0 + 1 : $0 }
        return Double(count) / Double(values.count)
    }
}
