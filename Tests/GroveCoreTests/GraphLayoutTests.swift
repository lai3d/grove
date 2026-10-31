import Testing

@testable import GroveCore

@Suite struct GraphLayoutTests {
    private func seg(_ from: Int, _ to: Int) -> (Int, Int) { (from, to) }
    private func pairs(_ s: [GraphSegment]) -> Set<[Int]> { Set(s.map { [$0.from, $0.to] }) }

    @Test func linearHistoryStaysInOneLane() {
        var g = GraphLayout()
        let c = g.add(id: "c", parents: ["b"])
        let b = g.add(id: "b", parents: ["a"])
        let a = g.add(id: "a", parents: [])
        #expect([c.lane, b.lane, a.lane] == [0, 0, 0])
        #expect(c.top.isEmpty)
        #expect(pairs(c.bottom) == [[0, 0]])
        #expect(pairs(b.top) == [[0, 0]] && pairs(b.bottom) == [[0, 0]])
        #expect(a.bottom.isEmpty)
        #expect([c.width, b.width, a.width] == [1, 1, 1])
        #expect(c.color == b.color && b.color == a.color)
    }

    @Test func mergeOpensAndClosesSideLane() {
        // d = merge(c, b); c and b both branch from a.
        var g = GraphLayout()
        let d = g.add(id: "d", parents: ["c", "b"])
        let c = g.add(id: "c", parents: ["a"])
        let b = g.add(id: "b", parents: ["a"])
        let a = g.add(id: "a", parents: [])

        #expect(d.lane == 0 && pairs(d.bottom) == [[0, 0], [0, 1]])
        #expect(c.lane == 0 && pairs(c.top) == [[0, 0], [1, 1]] && pairs(c.bottom) == [[0, 0], [1, 1]])
        #expect(b.lane == 1 && pairs(b.top) == [[0, 0], [1, 1]])
        // b's parent a is already awaited by lane 0, so b's lane folds into it.
        #expect(pairs(b.bottom) == [[1, 0], [0, 0]])
        #expect(a.lane == 0 && pairs(a.top) == [[0, 0]] && a.width == 1)
        #expect(d.width == 2 && b.width == 2)
        #expect(b.color != c.color)
    }

    @Test func twoTipsConvergeOnCommonParent() {
        var g = GraphLayout()
        let x = g.add(id: "x", parents: ["a"])
        let y = g.add(id: "y", parents: ["a"])
        let a = g.add(id: "a", parents: [])
        #expect(x.lane == 0)
        #expect(y.lane == 1 && pairs(y.top) == [[0, 0]] && pairs(y.bottom) == [[1, 0], [0, 0]])
        #expect(a.lane == 0 && pairs(a.top) == [[0, 0]])
    }

    @Test func freedLanesAreReused() {
        var g = GraphLayout()
        _ = g.add(id: "m2", parents: ["m1", "f2"])
        _ = g.add(id: "f2", parents: ["m1"])  // lane 1 merges back into lane 0
        _ = g.add(id: "m1", parents: ["m0", "g1"])
        let g1 = g.add(id: "g1", parents: ["m0"])
        #expect(g1.lane == 1)
    }

    @Test func octopusMergeGetsALanePerParent() {
        var g = GraphLayout()
        let m = g.add(id: "m", parents: ["a", "b", "c"])
        #expect(pairs(m.bottom) == [[0, 0], [0, 1], [0, 2]] && m.width == 3)
    }
}

@Suite struct GraphMainlineTests {
    private func pairs(_ s: [GraphSegment]) -> Set<[Int]> { Set(s.map { [$0.from, $0.to] }) }

    @Test func mainlineIsNotPushedRightBySideBranch() {
        // m2 -> m1 -> m0 on main; f1 (tip, appears first) branches from m0 too... and
        // s1 (shown between m2 and m1) is a side tip whose parent m0 is awaited to the right.
        var g = GraphLayout()
        let m2 = g.add(id: "m2", parents: ["m1"])
        let s1 = g.add(id: "s1", parents: ["m0"])
        let m1 = g.add(id: "m1", parents: ["m0"])
        let m0 = g.add(id: "m0", parents: [])
        #expect(m2.lane == 0 && s1.lane == 1)
        #expect(m1.lane == 0)
        // m1 keeps lane 0 and pulls the side lane in instead of jumping right.
        #expect(pairs(m1.bottom) == [[0, 0], [1, 0]])
        #expect(m0.lane == 0 && pairs(m0.top) == [[0, 0]])
    }

    @Test func headPinnedToLaneZeroEvenIfAnotherTipComesFirst() {
        var g = GraphLayout(mainline: "h")
        let other = g.add(id: "x", parents: ["base"])
        let head = g.add(id: "h", parents: ["base"])
        let base = g.add(id: "base", parents: [])
        #expect(other.lane == 1)
        // Reserved lane 0 is not drawn before HEAD is reached.
        #expect(!other.top.contains { $0.from == 0 } && !other.bottom.contains { $0.from == 0 || $0.to == 0 })
        #expect(head.lane == 0 && head.top.allSatisfy { $0.from != 0 })
        #expect(pairs(head.bottom) == [[0, 0], [1, 0]])
        #expect(base.lane == 0)
    }

    @Test func branchOffHeadMakesReservedLaneLive() {
        var g = GraphLayout(mainline: "h")
        let f = g.add(id: "f", parents: ["h"])
        let h = g.add(id: "h", parents: [])
        #expect(f.lane == 1 && pairs(f.bottom) == [[1, 0]])
        #expect(h.lane == 0 && pairs(h.top) == [[0, 0]])
    }
}
