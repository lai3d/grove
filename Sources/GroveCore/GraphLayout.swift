/// One line piece inside a row. `top` segments run from the row's top edge
/// (at lane `from`) to its vertical middle (at lane `to`); `bottom` segments run
/// from the middle (lane `from`) to the bottom edge (lane `to`).
public struct GraphSegment: Sendable, Hashable {
    public let from: Int
    public let to: Int
    public let color: Int

    public init(from: Int, to: Int, color: Int) {
        self.from = from
        self.to = to
        self.color = color
    }
}

public struct GraphRow: Sendable, Hashable {
    public let lane: Int
    public let color: Int
    public let top: [GraphSegment]
    public let bottom: [GraphSegment]
    /// Number of lane columns this row needs.
    public let width: Int
}

/// Incremental lane assignment for a commit graph. Feed commits in
/// `--topo-order` (children before parents); each call returns that row's
/// drawing instructions, so rows can be laid out while `git log` is streaming.
public struct GraphLayout: Sendable {
    /// lanes[i] = commit id that lane i is waiting to reach, nil = free slot.
    private var lanes: [String?] = []
    private var laneColors: [Int] = []
    private var nextColor = 0

    public init() {}

    public mutating func add(id: String, parents: [String]) -> GraphRow {
        let lane: Int
        if let l = lanes.firstIndex(of: id) {
            lane = l
        } else {
            lane = allocate()  // branch tip: nothing comes in from above
            laneColors[lane] = takeColor()
        }
        let color = laneColors[lane]

        // Top half: pass-through lines, plus every lane converging on this commit.
        var top: [GraphSegment] = []
        for i in lanes.indices {
            guard let h = lanes[i] else { continue }
            if h == id {
                top.append(GraphSegment(from: i, to: lane, color: laneColors[i]))
                if i != lane { lanes[i] = nil }
            } else {
                top.append(GraphSegment(from: i, to: i, color: laneColors[i]))
            }
        }

        let passThrough = lanes.indices.filter { $0 != lane && lanes[$0] != nil }
        var bottom: [GraphSegment] = []

        // First parent continues in this lane unless another lane already waits for it.
        if let first = parents.first {
            if let j = lanes.firstIndex(of: first), j != lane {
                lanes[lane] = nil
                bottom.append(GraphSegment(from: lane, to: j, color: laneColors[j]))
            } else {
                lanes[lane] = first
                bottom.append(GraphSegment(from: lane, to: lane, color: color))
            }
        } else {
            lanes[lane] = nil
        }

        for p in parents.dropFirst() {
            if let j = lanes.firstIndex(of: p) {
                bottom.append(GraphSegment(from: lane, to: j, color: laneColors[j]))
            } else {
                let k = allocate()
                lanes[k] = p
                laneColors[k] = takeColor()
                bottom.append(GraphSegment(from: lane, to: k, color: laneColors[k]))
            }
        }

        for i in passThrough {
            bottom.append(GraphSegment(from: i, to: i, color: laneColors[i]))
        }

        while let last = lanes.last, last == nil {
            lanes.removeLast()
            laneColors.removeLast()
        }

        let maxLane = (top + bottom).reduce(lane) { max($0, $1.from, $1.to) }
        return GraphRow(lane: lane, color: color, top: top, bottom: bottom, width: maxLane + 1)
    }

    private mutating func allocate() -> Int {
        if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
        lanes.append(nil)
        laneColors.append(0)
        return lanes.count - 1
    }

    private mutating func takeColor() -> Int {
        defer { nextColor += 1 }
        return nextColor
    }
}
