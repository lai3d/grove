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
    /// Commit that lane 0 is reserved for before it has been reached (HEAD).
    /// While set, lane 0 is not drawn and tips that arrive earlier go right of it.
    private var reservedTip: String?

    /// - Parameter mainline: commit to pin to the leftmost lane (usually HEAD);
    ///   its first-parent chain then stays in lane 0.
    public init(mainline: String? = nil) {
        if let mainline {
            lanes = [mainline]
            laneColors = [takeColor()]
            reservedTip = mainline
        }
    }

    public mutating func add(id: String, parents: [String]) -> GraphRow {
        let reachedReserved = reservedTip == id
        if reachedReserved { reservedTip = nil }

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
            if h == reservedTip { continue }  // reserved lane not started yet
            if h == id {
                if !(reachedReserved && i == 0) {
                    top.append(GraphSegment(from: i, to: lane, color: laneColors[i]))
                }
                if i != lane { lanes[i] = nil }
            } else {
                top.append(GraphSegment(from: i, to: i, color: laneColors[i]))
            }
        }

        var passThrough = lanes.indices.filter { $0 != lane && lanes[$0] != nil && lanes[$0] != reservedTip }
        var bottom: [GraphSegment] = []

        // First parent continues in the leftmost lane that waits for it: if a lane
        // to the left already waits, fold into it; if one to the right does, pull it in.
        if let first = parents.first {
            if let j = lanes.firstIndex(of: first), j != lane {
                if lanes[j] == reservedTip { reservedTip = nil }  // joined: the reserved lane is live now
                if j < lane {
                    lanes[lane] = nil
                    bottom.append(GraphSegment(from: lane, to: j, color: laneColors[j]))
                } else {
                    lanes[lane] = first
                    lanes[j] = nil
                    passThrough.removeAll { $0 == j }
                    bottom.append(GraphSegment(from: lane, to: lane, color: color))
                    bottom.append(GraphSegment(from: j, to: lane, color: laneColors[j]))
                }
            } else {
                lanes[lane] = first
                bottom.append(GraphSegment(from: lane, to: lane, color: color))
            }
        } else {
            lanes[lane] = nil
        }

        for p in parents.dropFirst() {
            if let j = lanes.firstIndex(of: p) {
                if lanes[j] == reservedTip { reservedTip = nil }
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
