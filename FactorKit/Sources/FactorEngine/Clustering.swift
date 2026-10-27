import Foundation

/// Agglomerative hierarchical clustering on a correlation matrix, average linkage,
/// distance d = 1 - ρ. Clusters are merged while the closest pair is within `threshold`.
public enum Clustering {
    public struct Merge: Sendable, Hashable {
        public var left: [Int]
        public var right: [Int]
        public var distance: Double
    }

    public struct Output: Sendable, Hashable {
        /// Clusters as lists of item indices, largest first; singletons included.
        public var clusters: [[Int]]
        /// Every merge performed, in order (a truncated dendrogram).
        public var merges: [Merge]
    }

    /// - Parameter threshold: maximum average distance to merge. 0.5 groups items whose
    ///   average pairwise correlation is at least 0.5.
    public static func hierarchical(correlation: [[Double]], threshold: Double = 0.5) -> Output {
        let n = correlation.count
        var clusters: [[Int]] = (0..<n).map { [$0] }
        var merges: [Merge] = []
        func dist(_ i: Int, _ j: Int) -> Double {
            let c = correlation[i][j]
            return c.isNaN ? 1 : 1 - c   // unknown correlation treated as uncorrelated
        }
        func linkage(_ a: [Int], _ b: [Int]) -> Double {
            var s = 0.0
            for i in a { for j in b { s += dist(i, j) } }
            return s / Double(a.count * b.count)
        }
        while clusters.count > 1 {
            var best = (i: -1, j: -1, d: Double.infinity)
            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let d = linkage(clusters[i], clusters[j])
                    if d < best.d { best = (i, j, d) }
                }
            }
            guard best.d <= threshold else { break }
            let merged = (clusters[best.i] + clusters[best.j]).sorted()
            merges.append(Merge(left: clusters[best.i], right: clusters[best.j], distance: best.d))
            clusters.remove(at: best.j)
            clusters[best.i] = merged
        }
        clusters.sort { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
        return Output(clusters: clusters, merges: merges)
    }

    /// Order of items that places members of the same cluster next to each other,
    /// for drawing a heatmap with visible blocks.
    public static func seriation(_ output: Output) -> [Int] {
        output.clusters.flatMap { $0 }
    }
}
