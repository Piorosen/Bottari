import Foundation

/// Merges a list kept on two Macs: what this Mac has, what the other one
/// wrote, and the last state both agreed on. An item changed (or removed) on
/// one side only takes that change; changed differently on both sides, it is
/// a conflict, kept as each Mac has it until the user decides.
public enum ThreeWaySync {
    public struct Conflict<Item: Identifiable>: Identifiable {
        public var id: Item.ID { (local ?? remote)!.id }
        /// Nil when this Mac removed it.
        public let local: Item?
        /// Nil when the other Mac removed it.
        public let remote: Item?
    }

    public struct Result<Item: Identifiable> {
        /// What this Mac keeps: every change, and its own side of each conflict.
        public let merged: [Item]
        public let conflicts: [Conflict<Item>]
        /// What to leave for the other Mac: every change, and its side of each
        /// conflict, in the shared file's order with new items last.
        public let remote: [Item]
        /// The new agreed state: every change, and conflicts as last agreed, so
        /// they stay conflicts until resolved.
        public let base: [Item]
    }

    public static func merge<Item: Identifiable & Equatable>(base: [Item], local: [Item], remote: [Item]) -> Result<Item> {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // This Mac's order first, then what only the other Mac has, in its order.
        let order = ids(local.map(\.id), then: (remote + base).map(\.id))

        var merged: [Item] = [], newBase: [Item] = []
        var forRemote: [Item.ID: Item] = [:]
        var conflicts: [Conflict<Item>] = []
        for id in order {
            let mine = localByID[id], theirs = remoteByID[id], agreed = baseByID[id]
            let settled: Item??
            if mine == theirs || theirs == agreed {
                settled = .some(mine)
            } else if mine == agreed {
                settled = .some(theirs)
            } else {
                settled = nil
            }
            if let settled {
                if let item = settled {
                    merged.append(item)
                    forRemote[id] = item
                    newBase.append(item)
                }
            } else {
                conflicts.append(Conflict(local: mine, remote: theirs))
                if let mine { merged.append(mine) }
                if let theirs { forRemote[id] = theirs }
                if let agreed { newBase.append(agreed) }
            }
        }
        let newRemote = ids(remote.map(\.id), then: order).compactMap { forRemote[$0] }
        return Result(merged: merged, conflicts: conflicts, remote: newRemote, base: newBase)
    }

    private static func ids<ID: Hashable>(_ first: [ID], then rest: [ID]) -> [ID] {
        var seen = Set<ID>()
        return (first + rest).filter { seen.insert($0).inserted }
    }
}

extension ThreeWaySync.Conflict: Sendable where Item: Sendable {}
extension ThreeWaySync.Result: Sendable where Item: Sendable {}
