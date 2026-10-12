import Foundation

/// Named signal representation used by the estimators.
struct SignalComponent {
    let name: String
    let samples: [Double]
    let bandEnergyRatio: Double?

    init(name: String, samples: [Double], bandEnergyRatio: Double? = nil) {
        self.name = name
        self.samples = samples
        self.bandEnergyRatio = bandEnergyRatio
    }
}

/// Multiaxial preprocessing used in the course-aligned pipeline.
///
/// PCA is fitted *after* band-pass filtering. Therefore the direction of maximum variance is
/// specific to the physiological band under study instead of being dominated by gravity/drift.
/// PC1 is a representation of the same tri-axial sensor, not an independent measurement.
enum ComponentSelector {
    static func bandLimitedCandidates(
        x: [Double],
        y: [Double],
        z: [Double],
        targetBand: ClosedRange<Double>,
        order: Int,
        sampleRateHz: Double
    ) -> (components: [SignalComponent], pcaWeights: [Double]) {
        guard x.count == y.count, y.count == z.count, !x.isEmpty, sampleRateHz > 0 else {
            return ([], [1, 0, 0])
        }

        let upper = min(targetBand.upperBound, 0.45 * sampleRateHz)
        guard upper > targetBand.lowerBound else { return ([], [1, 0, 0]) }
        let filter = ButterworthBandpass(
            order: order,
            lowCutoffHz: targetBand.lowerBound,
            highCutoffHz: upper,
            sampleRateHz: sampleRateHz
        )

        let fx = filter.filtfilt(Statistics.detrendLinear(x))
        let fy = filter.filtfilt(Statistics.detrendLinear(y))
        let fz = filter.filtfilt(Statistics.detrendLinear(z))
        let pca = principalComponents(x: fx, y: fy, z: fz)

        return (
            [
                SignalComponent(name: "x", samples: fx),
                SignalComponent(name: "y", samples: fy),
                SignalComponent(name: "z", samples: fz),
                SignalComponent(name: "PC1-band", samples: pca.first),
                // PC2 is retained only for transparent PCA diagnostics. Production RR/HR
                // does not use it in the physiological decision.
                SignalComponent(name: "PC2-band", samples: pca.second)
            ],
            pca.firstWeights
        )
    }

    /// Simple unfiltered representations retained for standalone diagnostics.
    static func candidates(
        x: [Double], y: [Double], z: [Double]
    ) -> (components: [SignalComponent], pcaWeights: [Double]) {
        let pca = principalComponents(x: x, y: y, z: z)
        return (
            [
                SignalComponent(name: "x", samples: x),
                SignalComponent(name: "y", samples: y),
                SignalComponent(name: "z", samples: z),
                SignalComponent(name: "PC1", samples: pca.first)
            ],
            pca.firstWeights
        )
    }

    static func principalComponents(
        x: [Double],
        y: [Double],
        z: [Double]
    ) -> (first: [Double], second: [Double], firstWeights: [Double], secondWeights: [Double]) {
        guard x.count == y.count, y.count == z.count, !x.isEmpty else {
            return ([], [], [1, 0, 0], [0, 1, 0])
        }

        let cx = Statistics.removeMean(x)
        let cy = Statistics.removeMean(y)
        let cz = Statistics.removeMean(z)
        let n = Double(x.count)
        let covariance = [
            [dot(cx, cx) / n, dot(cx, cy) / n, dot(cx, cz) / n],
            [dot(cy, cx) / n, dot(cy, cy) / n, dot(cy, cz) / n],
            [dot(cz, cx) / n, dot(cz, cy) / n, dot(cz, cz) / n]
        ]

        let firstWeights = dominantEigenvector(
            covariance,
            seed: normalized([1, 1, 1]),
            orthogonalTo: nil
        )
        let firstEigenvalue = dot(firstWeights, multiply(covariance, firstWeights))
        var deflated = covariance
        for row in 0..<3 {
            for column in 0..<3 {
                deflated[row][column] -= firstEigenvalue * firstWeights[row] * firstWeights[column]
            }
        }
        let secondWeights = dominantEigenvector(
            deflated,
            seed: normalized(orthogonalized([1, -1, 0.5], against: firstWeights)),
            orthogonalTo: firstWeights
        )
        return (
            projection(centeredX: cx, centeredY: cy, centeredZ: cz, weights: firstWeights),
            projection(centeredX: cx, centeredY: cy, centeredZ: cz, weights: secondWeights),
            firstWeights,
            secondWeights
        )
    }

    private static func projection(
        centeredX: [Double], centeredY: [Double], centeredZ: [Double], weights: [Double]
    ) -> [Double] {
        guard weights.count == 3 else { return [] }
        return centeredX.indices.map {
            centeredX[$0] * weights[0] + centeredY[$0] * weights[1] + centeredZ[$0] * weights[2]
        }
    }

    private static func dominantEigenvector(
        _ matrix: [[Double]], seed: [Double], orthogonalTo basis: [Double]?
    ) -> [Double] {
        var vector = normalized(seed)
        for _ in 0..<60 {
            var next = multiply(matrix, vector)
            if let basis { next = orthogonalized(next, against: basis) }
            let norm = vectorNorm(next)
            guard norm > 1e-14 else { break }
            next = next.map { $0 / norm }
            let change = zip(next, vector).reduce(0) { $0 + abs($1.0 - $1.1) }
            vector = next
            if change < 1e-10 { break }
        }
        return normalized(vector)
    }

    private static func multiply(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
        (0..<3).map { row in
            matrix[row][0] * vector[0] + matrix[row][1] * vector[1] + matrix[row][2] * vector[2]
        }
    }

    private static func orthogonalized(_ vector: [Double], against basis: [Double]) -> [Double] {
        let amount = dot(vector, basis)
        return zip(vector, basis).map { $0.0 - amount * $0.1 }
    }

    private static func normalized(_ vector: [Double]) -> [Double] {
        let norm = vectorNorm(vector)
        return norm > 1e-14 ? vector.map { $0 / norm } : [1, 0, 0]
    }

    private static func vectorNorm(_ vector: [Double]) -> Double {
        vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }

    private static func dot(_ left: [Double], _ right: [Double]) -> Double {
        zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
