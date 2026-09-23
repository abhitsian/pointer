import Foundation

extension Array where Element == String {
    /// The value that appears most often, ignoring empties.
    func mostCommon() -> String? {
        let counts = reduce(into: [String: Int]()) { counts, value in
            guard !value.isEmpty else { return }
            counts[value, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }
}
