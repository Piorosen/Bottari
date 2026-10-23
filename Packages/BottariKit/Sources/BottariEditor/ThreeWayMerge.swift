import Foundation

/// Line-based three-way merge, for a file that changed on the server while it
/// was being edited: if both sides changed different lines, both changes are kept.
public enum ThreeWayMerge {
    public enum Result: Equatable, Sendable {
        case merged(String)
        /// Both sides changed the same or neighbouring lines differently.
        case conflict
    }

    /// One change against the base: base lines `start..<end` became `lines`.
    struct Hunk: Equatable {
        let start: Int
        let end: Int
        let lines: [String]
    }

    public static func merge(base: String, mine: String, theirs: String) -> Result {
        let baseLines = base.components(separatedBy: "\n")
        let ours = hunks(from: baseLines, to: mine.components(separatedBy: "\n"))
        let others = hunks(from: baseLines, to: theirs.components(separatedBy: "\n"))
        var merged: [String] = []
        var position = 0
        var i = 0, j = 0

        func apply(_ hunk: Hunk) {
            merged += baseLines[position..<hunk.start]
            merged += hunk.lines
            position = hunk.end
        }

        while i < ours.count || j < others.count {
            if i < ours.count, j < others.count {
                let a = ours[i], b = others[j]
                // Changes that overlap or touch would have to be ordered by hand.
                if a.start <= b.end && b.start <= a.end {
                    guard a == b else { return .conflict }
                    apply(a)
                    i += 1
                    j += 1
                } else if a.start < b.start {
                    apply(a)
                    i += 1
                } else {
                    apply(b)
                    j += 1
                }
            } else if i < ours.count {
                apply(ours[i])
                i += 1
            } else {
                apply(others[j])
                j += 1
            }
        }
        merged += baseLines[position...]
        return .merged(merged.joined(separator: "\n"))
    }

    /// The changes from `old` to `new`, as runs of replaced lines.
    static func hunks(from old: [String], to new: [String]) -> [Hunk] {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
                i += 1
                j += 1
                continue
            }
            let start = i, firstNew = j
            while i < old.count, removed.contains(i) { i += 1 }
            while j < new.count, inserted.contains(j) { j += 1 }
            if i == start, j == firstNew { break }
            hunks.append(Hunk(start: start, end: i, lines: Array(new[firstNew..<j])))
        }
        return hunks
    }
}

/// Lines of two versions side by side, for "차이 보기".
public enum LineDiff {
    public struct Line: Equatable, Sendable {
        public enum Kind: Sendable { case same, removed, added }
        public let kind: Kind
        public let text: String
    }

    /// `old` turned into `new`, line by line; unchanged runs longer than
    /// `context` lines on each side of a change are left out.
    public static func lines(from old: String, to new: String, context: Int = 3) -> [Line] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var all: [Line] = []
        var position = 0
        for hunk in ThreeWayMerge.hunks(from: oldLines, to: newLines) {
            all += oldLines[position..<hunk.start].map { Line(kind: .same, text: $0) }
            all += oldLines[hunk.start..<hunk.end].map { Line(kind: .removed, text: $0) }
            all += hunk.lines.map { Line(kind: .added, text: $0) }
            position = hunk.end
        }
        all += oldLines[position...].map { Line(kind: .same, text: $0) }
        let changed = all.indices.filter { all[$0].kind != .same }
        return all.indices.filter { index in
            changed.contains { abs($0 - index) <= context }
        }.map { all[$0] }
    }
}
