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
        /// What to leave for the other Mac: every change, and its side of each conflict.
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
        var order = local.map(\.id)
        var seen = Set(order)
        for item in remote + base where seen.insert(item.id).inserted { order.append(item.id) }

        var merged: [Item] = [], newRemote: [Item] = [], newBase: [Item] = []
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
                    newRemote.append(item)
                    newBase.append(item)
                }
            } else {
                conflicts.append(Conflict(local: mine, remote: theirs))
                if let mine { merged.append(mine) }
                if let theirs { newRemote.append(theirs) }
                if let agreed { newBase.append(agreed) }
            }
        }
        return Result(merged: merged, conflicts: conflicts, remote: newRemote, base: newBase)
    }
}
