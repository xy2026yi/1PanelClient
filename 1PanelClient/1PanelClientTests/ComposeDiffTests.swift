//
//  ComposeDiffTests.swift
//  1PanelClientTests
//
//  应用升级 docker-compose 差异计算：hunk 划分、位置保持、采纳合并
//

import Testing
import Foundation
@testable import _PanelClient

@Suite("ComposeDiff 行级差异")
struct ComposeDiffTests {
    private func lines(_ s: String) -> [String] {
        s.components(separatedBy: "\n")
    }

    private func text(_ a: [String]) -> String {
        a.joined(separator: "\n")
    }

    @Test("完全相同：无差异块，全部行标记 same")
    func identical() {
        let d = ComposeDiff(old: lines("a\nb\nc"), new: lines("a\nb\nc"))
        #expect(d.hunks.isEmpty)
        #expect(d.oldKinds.allSatisfy { $0 == .same })
        #expect(d.newKinds.allSatisfy { $0 == .same })
        #expect(text(d.applying(adoption: [])) == "a\nb\nc")
    }

    @Test("仅新增：单个 insertion hunk，采纳后移除新增行")
    func insertionOnly() {
        let d = ComposeDiff(old: lines("a\nc"), new: lines("a\nb\nc"))
        #expect(d.hunks.count == 1)
        #expect(d.hunks[0].isInsertionOnly)
        #expect(d.hunks[0].newRange == 1..<2)
        #expect(d.hunks[0].oldRange == 1..<1)   // 空区间携带位置
        #expect(text(d.applying(adoption: [0])) == "a\nc")
    }

    @Test("仅删除：单个 deletion hunk，采纳后在原位恢复旧行")
    func deletionOnly() {
        let d = ComposeDiff(old: lines("a\nb\nc"), new: lines("a\nc"))
        #expect(d.hunks.count == 1)
        #expect(d.hunks[0].isDeletionOnly)
        #expect(d.hunks[0].oldRange == 1..<2)
        #expect(d.hunks[0].newRange == 1..<1)
        #expect(text(d.applying(adoption: [0])) == "a\nb\nc")
    }

    @Test("多处 1:1 替换：可单独采纳任意一块，位置不变")
    func multipleReplacements() {
        let d = ComposeDiff(old: lines("a\nold1\nc\nold2\ne"), new: lines("a\nnew1\nc\nnew2\ne"))
        #expect(d.hunks.count == 2)
        #expect(d.hunks.allSatisfy { $0.isReplacement })
        #expect(text(d.applying(adoption: [0])) == "a\nold1\nc\nnew2\ne")
        #expect(text(d.applying(adoption: [1])) == "a\nnew1\nc\nold2\ne")
        #expect(text(d.applying(adoption: [0, 1])) == "a\nold1\nc\nold2\ne")
    }

    @Test("M:N 替换：旧 3 行对新 1 行，整块采纳")
    func multiLineReplacement() {
        let d = ComposeDiff(old: lines("x\no1\no2\no3\ny"), new: lines("x\nn1\ny"))
        #expect(d.hunks.count == 1)
        #expect(text(d.applying(adoption: [0])) == "x\no1\no2\no3\ny")
    }

    @Test("不变式：采纳全部差异块的结果与旧文本逐字一致")
    func adoptAllEqualsOld() {
        let old = "services:\n  db:\n    image: mysql:8.0\n    ports:\n      - 3306"
        let new = "services:\n  db:\n    image: mysql:8.4\n    volumes:\n      - data:/var/lib/mysql"
        let d = ComposeDiff(old: lines(old), new: lines(new))
        #expect(!d.hunks.isEmpty)
        #expect(text(d.applying(adoption: Set(d.hunks.indices))) == old)
    }

    @Test("末尾换行：行数组与文本往返一致")
    func trailingNewlineRoundTrip() {
        #expect(text(ComposeDiff.lines(of: "a\nb\n")) == "a\nb\n")
        let d = ComposeDiff(old: lines("a\n"), new: lines("a\nb\n"))
        #expect(text(d.applying(adoption: [0])) == "a\n")
    }

    @Test("空边界：空旧/空新仍能对齐与采纳")
    func emptySides() {
        let insertAll = ComposeDiff(old: [], new: lines("a\nb"))
        #expect(insertAll.hunks.count == 1)
        #expect(insertAll.hunks[0].oldRange == 0..<0)
        #expect(text(insertAll.applying(adoption: [0])) == "")

        let removeAll = ComposeDiff(old: lines("a"), new: [])
        #expect(removeAll.hunks.count == 1)
        #expect(removeAll.hunks[0].newRange == 0..<0)
        #expect(text(removeAll.applying(adoption: [0])) == "a")
    }

    @Test("段序列完整：equal + hunk 按序拼接可还原两侧全文")
    func segmentsRebuildBothSides() {
        let d = ComposeDiff(old: lines("a\nold1\nb\nb2\nc"), new: lines("a\nnew1\nb\nb2\nc"))
        var oldRebuilt: [String] = []
        var newRebuilt: [String] = []
        for seg in d.segments {
            switch seg {
            case .equal(let o, let n):
                oldRebuilt += d.oldLines[o]
                newRebuilt += d.newLines[n]
            case .hunk(_, let h):
                oldRebuilt += d.oldLines[h.oldRange]
                newRebuilt += d.newLines[h.newRange]
            }
        }
        #expect(oldRebuilt == d.oldLines)
        #expect(newRebuilt == d.newLines)
    }

    @Test("行标记：差异行 changed、相同行 same")
    func lineKinds() {
        let d = ComposeDiff(old: lines("a\nold\nc"), new: lines("a\nnew\nc"))
        #expect(d.oldKinds == [.same, .changed, .same])
        #expect(d.newKinds == [.same, .changed, .same])
    }
}
