import AppKit

/// The resource boundary is deliberately injectable: unit tests never read the general clipboard.
@MainActor
protocol InsertionPasteboard: AnyObject {
    var changeCount: Int { get }
    func readItems() throws -> [[String: Data]]
    /// Returns the ownership generation established by this clear, not a later observed count.
    func clearContents() -> Int
    func writeItems(_ items: [[String: Data]]) -> Bool
}

struct PasteboardSnapshot: Sendable {
    let items: [[String: Data]]
    let changeCount: Int

    @MainActor
    init(pasteboard: any InsertionPasteboard) throws {
        changeCount = pasteboard.changeCount
        do { items = try pasteboard.readItems() }
        catch { throw TextInsertionError.snapshotFailed }
        guard pasteboard.changeCount == changeCount else { throw TextInsertionError.clipboardChanged }
    }

    @MainActor
    func restore(to pasteboard: any InsertionPasteboard, ifOwnedBy generation: Int) throws {
        // An external copy takes precedence, including a copy made while setup was failing.
        guard pasteboard.changeCount == generation else { return }
        let restoredGeneration = pasteboard.clearContents()
        guard pasteboard.changeCount == restoredGeneration else { return }
        guard items.isEmpty || pasteboard.writeItems(items) else {
            throw TextInsertionError.clipboardRestoreFailed
        }
    }
}

@MainActor
final class SystemInsertionPasteboard: InsertionPasteboard {
    private var pasteboard: NSPasteboard { .general }
    var changeCount: Int { pasteboard.changeCount }

    func readItems() throws -> [[String: Data]] {
        try Self.materialize(pasteboard.pasteboardItems)
    }

    /// Interpret the native read result before any mutation. Kept separate from the global clipboard.
    static func materialize(_ nativeItems: [NSPasteboardItem]?) throws -> [[String: Data]] {
        // NSPasteboard documents nil as retrieval failure; only an actual empty array
        // establishes an empty clipboard. A second metadata read cannot prove otherwise.
        guard let items = nativeItems else { throw TextInsertionError.snapshotFailed }
        return try items.map { item in
            var representations: [String: Data] = [:]
            for type in item.types {
                // Materialize promised data now. A partial snapshot must never destroy the original.
                guard let data = item.data(forType: type) else { throw TextInsertionError.snapshotFailed }
                representations[type.rawValue] = data
            }
            return representations
        }
    }

    func clearContents() -> Int { pasteboard.clearContents() }

    func writeItems(_ items: [[String: Data]]) -> Bool {
        var objects: [NSPasteboardItem] = []
        for representations in items {
            let item = NSPasteboardItem()
            for (type, data) in representations {
                guard item.setData(data, forType: NSPasteboard.PasteboardType(type)) else { return false }
            }
            objects.append(item)
        }
        return objects.isEmpty || pasteboard.writeObjects(objects)
    }
}
