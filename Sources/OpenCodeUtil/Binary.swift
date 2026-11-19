public struct BinarySearchResult: Equatable, Sendable, Codable {
    public let found: Bool
    public let index: Int

    public init(found: Bool, index: Int) {
        self.found = found
        self.index = index
    }
}

/// Lexicographical comparison over UTF-16 code units, matching JavaScript's `<` operator on strings.
@inline(__always)
internal func jsStringLessThan(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
}

// parity: util/src/binary.ts#Binary [status=implemented hash=fefcc0b3ce3f]
public enum Binary {
    // parity: util/src/binary.ts#Binary.search [status=implemented hash=b0a2dd0f16cc]
    public static func search<T>(
        _ array: [T],
        id: String,
        compare: (T) -> String
    ) -> BinarySearchResult {
        var left = 0
        var right = array.count - 1

        while left <= right {
            let middle = (left + right) / 2
            let value = compare(array[middle])
            if value == id {
                return BinarySearchResult(found: true, index: middle)
            }
            if jsStringLessThan(value, id) {
                left = middle + 1
            } else {
                right = middle - 1
            }
        }
        return BinarySearchResult(found: false, index: left)
    }

    // parity: util/src/binary.ts#Binary.insert [status=implemented hash=dd454b37fe2a]
    public static func insert<T>(
        _ array: [T],
        item: T,
        compare: (T) -> String
    ) -> [T] {
        let id = compare(item)
        var left = 0
        var right = array.count

        while left < right {
            let middle = (left + right) / 2
            if jsStringLessThan(compare(array[middle]), id) {
                left = middle + 1
            } else {
                right = middle
            }
        }

        var result = array
        result.insert(item, at: left)
        return result
    }
}
