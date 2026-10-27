import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Thin vector helpers. On Apple platforms these use vDSP; elsewhere (Linux CI)
/// they fall back to plain loops with identical semantics.
public enum VectorMath {
    public static func sum(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        #if canImport(Accelerate)
        return vDSP.sum(x)
        #else
        var s = 0.0
        for v in x { s += v }
        return s
        #endif
    }

    public static func mean(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return .nan }
        #if canImport(Accelerate)
        return vDSP.mean(x)
        #else
        return sum(x) / Double(x.count)
        #endif
    }

    public static func dot(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count, "dot: length mismatch")
        guard !a.isEmpty else { return 0 }
        #if canImport(Accelerate)
        return vDSP.dot(a, b)
        #else
        var s = 0.0
        for i in a.indices { s += a[i] * b[i] }
        return s
        #endif
    }

    /// x - scalar
    public static func subtract(_ x: [Double], scalar: Double) -> [Double] {
        #if canImport(Accelerate)
        return vDSP.add(-scalar, x)
        #else
        return x.map { $0 - scalar }
        #endif
    }

    public static func multiply(_ x: [Double], scalar: Double) -> [Double] {
        #if canImport(Accelerate)
        return vDSP.multiply(scalar, x)
        #else
        return x.map { $0 * scalar }
        #endif
    }

    /// Sum of squared deviations from `m`.
    public static func sumSquaredDeviations(_ x: [Double], from m: Double) -> Double {
        let d = subtract(x, scalar: m)
        return dot(d, d)
    }

    /// Element-wise clip to [lo, hi].
    public static func clip(_ x: [Double], lo: Double, hi: Double) -> [Double] {
        #if canImport(Accelerate)
        return vDSP.clip(x, to: lo...hi)
        #else
        return x.map { Swift.min(Swift.max($0, lo), hi) }
        #endif
    }
}
