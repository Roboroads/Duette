import CoreAudio

/// One stream of a device in one scope, as the HAL lists it.
public struct StreamInfo: Equatable, Hashable, Codable {
    /// The stream object, or 0 when there is no object (a tap's stream is described by its format).
    public var id: AudioObjectID
    public var channels: Int
    /// IOProc buffers the stream fills: 1 if it is interleaved, one per channel if not.
    public var buffers: Int
    /// kAudioObjectPropertyOwner of the stream, 0 if unknown.
    public var owner: AudioObjectID

    public init(id: AudioObjectID, channels: Int, buffers: Int = 1, owner: AudioObjectID = 0) {
        self.id = id
        self.channels = channels
        self.buffers = buffers
        self.owner = owner
    }
}

/// What a member of the aggregate is to the engine.
public enum StreamRole: String, Codable, Hashable, CaseIterable {
    case sink
    case mic
    case tap
}

/// A run of buffers in an IOProc's AudioBufferList.
public struct BufferRange: Equatable, Hashable, Codable {
    public var first: Int
    public var count: Int

    public init(first: Int, count: Int) {
        self.first = first
        self.count = count
    }

    public static let none = BufferRange(first: 0, count: 0)
}

/// A device (or tap) in the aggregate, with its own streams in one scope.
public struct LayoutMember: Equatable {
    public var role: StreamRole
    public var objectID: AudioObjectID
    public var streams: [StreamInfo]

    public init(role: StreamRole, objectID: AudioObjectID, streams: [StreamInfo]) {
        self.role = role
        self.objectID = objectID
        self.streams = streams
    }
}

/// How the owner of each aggregate stream was found.
public enum LayoutMethod: String, Codable {
    /// The aggregate lists the members' own stream objects.
    case streamIDs
    /// kAudioObjectPropertyOwner of each aggregate stream names a member.
    case owners
    /// Only one order of the members matches the channel count of every stream.
    case channelCounts
    /// Nothing told the members apart, so the composition order was used: subdevices in list
    /// order, then taps. Recorded in diagnostics because it is the one case that is assumed.
    case memberOrder
}

/// Which buffers of the aggregate's buffer list belong to which member.
public struct StreamLayout: Equatable, Codable {
    public var ranges: [StreamRole: BufferRange]
    public var method: LayoutMethod

    public init(ranges: [StreamRole: BufferRange], method: LayoutMethod) {
        self.ranges = ranges
        self.method = method
    }

    public func range(_ role: StreamRole) -> BufferRange { ranges[role] ?? .none }
}

public enum StreamLayoutError: Error, Equatable {
    /// The aggregate has a different number of streams than its members together.
    case streamCountMismatch(expected: Int, actual: Int)
}

/// Works out which streams of the aggregate belong to which member. The order of tap streams
/// against subdevice streams is not documented, so it is never assumed while there is evidence:
/// first stream identity, then stream ownership, then the channel counts.
public enum StreamLayoutResolver {
    /// - Parameters:
    ///   - streams: the aggregate's streams in one scope, in buffer-list order.
    ///   - members: the aggregate's members in composition order (subdevices, then taps), each
    ///     with its own streams in that scope. Members without streams are ignored.
    public static func resolve(streams: [StreamInfo], members: [LayoutMember]) throws -> StreamLayout {
        let present = members.filter { !$0.streams.isEmpty }
        let expected = present.reduce(0) { $0 + $1.streams.count }
        guard streams.count == expected else {
            throw StreamLayoutError.streamCountMismatch(expected: expected, actual: streams.count)
        }
        if present.isEmpty { return StreamLayout(ranges: [:], method: .memberOrder) }

        if let assignment = assign(streams, present, match: { stream, member in
            stream.id != 0 && member.streams.contains { $0.id == stream.id }
        }) {
            return StreamLayout(ranges: ranges(streams, present, assignment), method: .streamIDs)
        }
        if let assignment = assign(streams, present, match: { stream, member in
            stream.owner != 0 && stream.owner == member.objectID
        }) {
            return StreamLayout(ranges: ranges(streams, present, assignment), method: .owners)
        }

        // Channel counts: every order of the members whose streams line up with the aggregate's.
        let signature = streams.map(\.channels)
        var matches: [[Int]] = []
        for order in permutations(Array(present.indices)) {
            let candidate = order.flatMap { present[$0].streams.map(\.channels) }
            if candidate == signature { matches.append(order) }
        }
        let composition = Array(present.indices)
        let distinct = Set(matches.map { ranges(streams, present, owners(for: $0, present)) })
        if distinct.count == 1, let order = matches.first {
            return StreamLayout(ranges: ranges(streams, present, owners(for: order, present)), method: .channelCounts)
        }
        return StreamLayout(ranges: ranges(streams, present, owners(for: composition, present)), method: .memberOrder)
    }

    /// Member index for each aggregate stream, if `match` places every stream and every member's
    /// streams form one block of the right size. A single member that no stream matched (a tap,
    /// whose stream has no object) may take the streams nobody matched.
    private static func assign(_ streams: [StreamInfo], _ members: [LayoutMember],
                               match: (StreamInfo, LayoutMember) -> Bool) -> [Int]? {
        var owner = [Int?](repeating: nil, count: streams.count)
        var anyHit = false
        for (index, stream) in streams.enumerated() {
            let hits = members.indices.filter { match(stream, members[$0]) }
            if hits.count > 1 { return nil }
            if let hit = hits.first {
                owner[index] = hit
                anyHit = true
            }
        }
        guard anyHit else { return nil }
        let unmatched = owner.indices.filter { owner[$0] == nil }
        if !unmatched.isEmpty {
            let unused = members.indices.filter { m in !owner.contains(where: { $0 == m }) }
            guard unused.count == 1 else { return nil }
            for index in unmatched { owner[index] = unused[0] }
        }
        let result = owner.compactMap { $0 }
        guard result.count == streams.count else { return nil }
        for m in members.indices {
            let positions = result.indices.filter { result[$0] == m }
            guard positions.count == members[m].streams.count else { return nil }
            if let first = positions.first, let last = positions.last, last - first + 1 != positions.count {
                return nil
            }
        }
        return result
    }

    /// Member index for each stream when the members come in `order`.
    private static func owners(for order: [Int], _ members: [LayoutMember]) -> [Int] {
        order.flatMap { m in Array(repeating: m, count: members[m].streams.count) }
    }

    /// Buffer ranges per role, from the member index of each stream.
    private static func ranges(_ streams: [StreamInfo], _ members: [LayoutMember],
                               _ owners: [Int]) -> [StreamRole: BufferRange] {
        var result: [StreamRole: BufferRange] = [:]
        var buffer = 0
        for (index, stream) in streams.enumerated() {
            let role = members[owners[index]].role
            let width = max(stream.buffers, 1)
            if var range = result[role] {
                range.count += width
                result[role] = range
            } else {
                result[role] = BufferRange(first: buffer, count: width)
            }
            buffer += width
        }
        return result
    }

    private static func permutations(_ items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        var result: [[Int]] = []
        for (index, item) in items.enumerated() {
            var rest = items
            rest.remove(at: index)
            for tail in permutations(rest) { result.append([item] + tail) }
        }
        return result
    }
}
