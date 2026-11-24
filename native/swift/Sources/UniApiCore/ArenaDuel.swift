public struct ArenaDuel: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public let left: Int
        public let right: Int
    }

    public enum Choice: Sendable { case left, tie, right }

    private let contestants: [Int]
    private var cursor = 1
    private var low = 0
    private var high = 1
    public private(set) var groups: [[Int]]
    public private(set) var decisions = 0

    public init(contestants: [Int]) {
        self.contestants = contestants
        groups = contestants.first.map { [[$0]] } ?? []
    }

    private var midpoint: Int { (low + high) / 2 }
    public var pair: Pair? {
        guard cursor < contestants.count, low < high else { return nil }
        return Pair(left: groups[midpoint][0], right: contestants[cursor])
    }

    public var maximumDecisions: Int {
        (1..<max(1, contestants.count)).reduce(0) { $0 + Int.bitWidth - $1.leadingZeroBitCount }
    }

    public mutating func choose(_ choice: Choice) {
        guard let pair else { return }
        decisions += 1
        switch choice {
        case .tie:
            groups[midpoint].append(pair.right)
        case .left:
            low = midpoint + 1
            if low < high { return }
            groups.insert([pair.right], at: low)
        case .right:
            high = midpoint
            if low < high { return }
            groups.insert([pair.right], at: low)
        }
        cursor += 1
        low = 0
        high = groups.count
    }
}

enum ArenaVoteOrder {
    static func groups(ranking: JSONValue, rankGroups: JSONValue, finished: [Int]) throws -> [[Int]] {
        let values: [[JSONValue]]
        if rankGroups.isNull {
            values = ranking.array.map { [$0] }
        } else {
            guard case .array(let groups) = rankGroups, groups.allSatisfy({
                if case .array(let group) = $0 { return !group.isEmpty }
                return false
            }) else { throw NativeFailure("Each rank needs at least one contestant") }
            values = groups.map(\.array)
        }
        let flat = values.flatMap { $0 }
        guard flat.allSatisfy({
            if case .number(let n) = $0 { return n.isFinite && n == n.rounded() }
            return false
        }), flat.map(\.int).sorted() == finished.sorted() else {
            throw NativeFailure("Rank every finished contestant exactly once")
        }
        return values.map { $0.map(\.int).sorted() }
    }

    static func ranks(_ groups: [[Int]]) -> [Int: Int] {
        var next = 1, ranks: [Int: Int] = [:]
        for group in groups {
            for contestant in group { ranks[contestant] = next }
            next += group.count
        }
        return ranks
    }
}
