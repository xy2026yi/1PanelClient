//
//  ComposeDiff.swift
//  1PanelClient
//
//  应用升级 docker-compose.yml 的行级差异计算：
//  LCS 对齐新旧行 → 相邻增删聚合成 hunk → 按采纳集合生成合并结果。
//  纯逻辑无 UI，行为由 ComposeDiffTests 覆盖。
//

import Foundation

/// 行级 diff 结果：差异块（hunk）+ 新旧行的逐行标记
nonisolated struct ComposeDiff {
    enum LineKind: Equatable {
        case same
        case changed
    }

    /// 一个差异块：旧区间与新区间（可为空区间，但携带位置信息，
    /// 空 = 该侧没有对应行；位置用于按序渲染与原地替换）
    struct Hunk: Equatable {
        let oldRange: Range<Int>
        let newRange: Range<Int>

        /// 仅新增（旧无此段）
        var isInsertionOnly: Bool { oldRange.isEmpty && !newRange.isEmpty }
        /// 仅删除（新无此段）
        var isDeletionOnly: Bool { newRange.isEmpty && !oldRange.isEmpty }
        /// 替换（两侧都非空）
        var isReplacement: Bool { !oldRange.isEmpty && !newRange.isEmpty }
    }

    /// 渲染序片段：相同段 或 差异块（携带 hunk 在 hunks 中的下标）
    enum Segment: Equatable {
        case equal(oldRange: Range<Int>, newRange: Range<Int>)
        case hunk(index: Int, hunk: Hunk)
    }

    let oldLines: [String]
    let newLines: [String]
    let hunks: [Hunk]
    let segments: [Segment]
    private(set) var oldKinds: [LineKind]
    private(set) var newKinds: [LineKind]

    init(old: [String], new: [String]) {
        oldLines = old
        newLines = new
        let r = Self.compute(old: old, new: new)
        hunks = r.hunks
        segments = r.segments
        oldKinds = r.oldKinds
        newKinds = r.newKinds
    }

    /// LCS 对齐 + 编辑脚本聚合（静态方法：计算过程不触碰 self）
    private static func compute(old: [String], new: [String])
        -> (hunks: [Hunk], segments: [Segment], oldKinds: [LineKind], newKinds: [LineKind]) {
        var oldKinds = Array(repeating: LineKind.same, count: old.count)
        var newKinds = Array(repeating: LineKind.same, count: new.count)

        // LCS 长度表（升序对齐需要从后往前填）
        let n = old.count
        let m = new.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if old[i] == new[j] {
                        lcs[i][j] = lcs[i + 1][j + 1] + 1
                    } else {
                        lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                    }
                }
            }
        }

        // 回溯产出编辑脚本，边走边聚合成 segment：相同行连成 equal，
        // 相邻的删/增（任意交错）合入同一个 hunk
        var builtHunks: [Hunk] = []
        var builtSegments: [Segment] = []
        var i = 0
        var j = 0
        var eqOldStart = 0
        var eqNewStart = 0
        var pendingOld: Range<Int>?
        var pendingNew: Range<Int>?

        func flushEqual() {
            let eqOld = eqOldStart..<i
            let eqNew = eqNewStart..<j
            if !eqOld.isEmpty || !eqNew.isEmpty {
                builtSegments.append(.equal(oldRange: eqOld, newRange: eqNew))
            }
            eqOldStart = i
            eqNewStart = j
        }

        func flushHunk() {
            if let po = pendingOld, let pn = pendingNew {
                let hunk = Hunk(oldRange: po, newRange: pn)
                builtSegments.append(.hunk(index: builtHunks.count, hunk: hunk))
                builtHunks.append(hunk)
                for k in po { oldKinds[k] = .changed }
                for k in pn { newKinds[k] = .changed }
            } else if let po = pendingOld {
                // 仅删除：新区间为空，位置 = 当前 j
                let hunk = Hunk(oldRange: po, newRange: j..<j)
                builtSegments.append(.hunk(index: builtHunks.count, hunk: hunk))
                builtHunks.append(hunk)
                for k in po { oldKinds[k] = .changed }
            } else if let pn = pendingNew {
                // 仅新增：旧区间为空，位置 = 当前 i
                let hunk = Hunk(oldRange: i..<i, newRange: pn)
                builtSegments.append(.hunk(index: builtHunks.count, hunk: hunk))
                builtHunks.append(hunk)
                for k in pn { newKinds[k] = .changed }
            }
            pendingOld = nil
            pendingNew = nil
            // hunk 之后的相同段从这里重新起算
            eqOldStart = i
            eqNewStart = j
        }

        while i < n || j < m {
            if i < n && j < m && old[i] == new[j] {
                if pendingOld != nil || pendingNew != nil { flushHunk() }
                i += 1
                j += 1
            } else if j >= m || (i < n && lcs[i + 1][j] >= lcs[i][j + 1]) {
                // 删除旧行 i
                if pendingOld == nil && pendingNew == nil { flushEqual() }
                pendingOld = (pendingOld?.lowerBound ?? i)..<i + 1
                i += 1
            } else {
                // 新增新行 j
                if pendingOld == nil && pendingNew == nil { flushEqual() }
                pendingNew = (pendingNew?.lowerBound ?? j)..<j + 1
                j += 1
            }
        }
        if pendingOld != nil || pendingNew != nil { flushHunk() }
        else { flushEqual() }

        return (builtHunks, builtSegments, oldKinds, newKinds)
    }

    // MARK: - 采纳应用

    /// 按采纳的 hunk 集合生成合并结果：在每个采纳块的位置用旧行替换新行。
    /// 从后往前替换避免索引位移；采纳全部块的结果与旧文本完全一致。
    func applying(adoption: Set<Int>) -> [String] {
        var result = newLines
        let order = adoption.sorted {
            hunks[$0].newRange.lowerBound > hunks[$1].newRange.lowerBound
        }
        for idx in order {
            let h = hunks[idx]
            result.replaceSubrange(h.newRange, with: oldLines[h.oldRange])
        }
        return result
    }

    /// 文本 ↔ 行数组（保留末尾换行产生的空行，join 后与原文一致）
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func text(of lines: [String]) -> String {
        lines.joined(separator: "\n")
    }
}
