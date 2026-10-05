import Foundation
import NeoAnkiAPI
import NeoAnkiCore
import PoemDeckBuilder

private struct DeckPlan {
    let deck: APIDeck
    let originals: [APIItem]
    let preview: PoemDeckReconciliationPreview
    let openingCards: Bool
}

private struct LocalAPI {
    let baseURL: URL
    let token: String

    func request(_ path: String, method: String = "GET", body: Data? = nil, key: String? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw RepairError.message("Invalid local API path.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RepairError.message("Local API request failed (HTTP \(status), \(path)).")
        }
        return data
    }

    func all<Element: Codable & Sendable & Equatable>(_ path: String) async throws -> [Element] {
        var result: [Element] = []
        var cursor: String?
        repeat {
            var components = URLComponents(string: path)!
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            components.queryItems = query
            let data = try await request(components.string!)
            let page = try Self.decoder.decode(APICollection<Element>.self, from: data)
            result.append(contentsOf: page.data)
            cursor = page.page.nextCursor
        } while cursor != nil
        return result
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            return try Date(value, strategy: .iso8601)
        }
        return decoder
    }
}

private enum RepairError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}

@main
private enum PoemRepairCommand {
    static func main() async {
        do { try await run() }
        catch {
            fputs("poem repair: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var snapshotPath: String?
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            snapshotPath = args[index + 1]
            args.removeSubrange(index...index + 1)
        }
        guard args.allSatisfy({ ["--apply", "--dry-run", "--opening-cards"].contains($0) }),
              !(args.contains("--apply") && args.contains("--dry-run")) else {
            throw RepairError.message("Usage: neoanki-poem-repair [--opening-cards] [--dry-run | --apply] [--snapshot /path/to/backup.sqlite]")
        }
        let shouldApply = args.contains("--apply")
        let openingCards = args.contains("--opening-cards")
        if let snapshotPath {
            guard !shouldApply else { throw RepairError.message("Snapshot mode is dry-run only. Apply repairs through the local API.") }
            try await auditSnapshot(at: URL(fileURLWithPath: snapshotPath), openingCards: openingCards)
            return
        }
        guard let token = ProcessInfo.processInfo.environment["NEOANKI_API_TOKEN"], !token.isEmpty else {
            throw RepairError.message("Set NEOANKI_API_TOKEN with library.read and items.write scopes.")
        }
        guard let port = Int(ProcessInfo.processInfo.environment["NEOANKI_API_PORT"] ?? "8766"),
              (1_024 ... 65_535).contains(port),
              let url = URL(string: "http://127.0.0.1:\(port)/") else {
            throw RepairError.message("NEOANKI_API_PORT must be a local API port.")
        }
        let api = LocalAPI(baseURL: url, token: token)
        // Refuse an ordered commit until the server explicitly advertises
        // the ordering contract, rather than relying on unknown-key behavior.
        if shouldApply {
            let document = try JSONSerialization.jsonObject(with: await api.request("/v1/openapi.json")) as? [String: Any]
            let components = document?["components"] as? [String: Any]
            let schemas = components?["schemas"] as? [String: Any]
            let bulk = schemas?["BulkItemsInput"] as? [String: Any]
            let properties = bulk?["properties"] as? [String: Any]
            guard properties?["order"] != nil else {
                throw RepairError.message("Install a NeoAnki2 build supporting ordered bulk requests before applying repairs.")
            }
        }
        let decks: [APIDeck] = try await api.all("/v1/decks")
        let types: [APIItemType] = try await api.all("/v1/item-types")
        let items: [APIItem] = try await api.all("/v1/items")
        let typeByID = Dictionary(uniqueKeysWithValues: types.map { ($0.id, $0) })
        let itemsByDeck = Dictionary(grouping: items.filter { $0.deckId != nil }, by: { $0.deckId! })
        var plans: [DeckPlan] = []
        var skipped = 0
        for deck in decks {
            let members = itemsByDeck[deck.id] ?? []
            guard members.contains(where: { typeByID[$0.itemTypeId]?.name == "Poem Line" }) else { continue }
            do {
                let plan = try plan(deck: deck, items: members, types: typeByID, openingCards: openingCards)
                plans.append(plan)
                print("\(deck.name): \(plan.preview.addedCount) to add, \(plan.preview.changes.count) to update, \(plan.preview.retiredCount) to retire")
            } catch {
                skipped += 1
                print("\(deck.name): skipped — \(error.localizedDescription)")
            }
        }
        guard skipped == 0 else { throw RepairError.message("Some poem decks need manual review; no repairs were applied.") }
        if shouldApply {
            for plan in plans where plan.preview.hasChanges {
                try await apply(plan, api: api)
                print("\(plan.deck.name): verified")
            }
        } else {
            print("Dry run only. Back up the library, then pass --apply to repair the listed decks.")
        }
        print("\(plans.count) poem deck(s) checked; \(plans.reduce(0) { $0 + $1.preview.addedCount }) opening card(s) planned")
    }

    /// Audits a disposable copy of a consistent SQLite backup. The snapshot
    /// and live library are never opened for writing by this mode.
    private static func auditSnapshot(at snapshotURL: URL, openingCards: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("neoanki-poem-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("library.sqlite")
        // Copy bytes from the resolved file, never a symlink that could make
        // ItemStore open the original snapshot or live library for writing.
        try FileManager.default.copyItem(at: snapshotURL.resolvingSymlinksInPath(), to: copy)
        let store = try ItemStore(databaseURL: copy)
        let types = try await store.listItemTypes()
        let byID = Dictionary(uniqueKeysWithValues: types.map { ($0.id, $0) })
        let items = try await store.itemRecords()
        var checked = 0
        var additions = 0
        var skipped = 0
        for deck in try await store.listDecks() {
            let members = items.filter { $0.item.deckID == deck.id }
            guard members.contains(where: { byID[$0.item.itemTypeID]?.name == "Poem Line" }) else { continue }
            do {
                let records = try members.map { record -> PoemDeckItemRecord in
                    guard record.cardIDs.count == 1, let type = byID[record.item.itemTypeID] else {
                        throw RepairError.message("Missing type or invalid card count.")
                    }
                    return .init(item: record.item, itemType: type, createdAt: record.createdAt)
                }
                let snapshot = try PoemDeckReconciler.snapshot(records: records)
                let preview = try PoemDeckReconciler.preview(
                    sourceText: snapshot.sourceText, records: records,
                    title: openingCards ? deck.name : nil, deckID: deck.id
                )
                print("\(deck.name): \(preview.addedCount) to add, \(preview.changes.count) to update, \(preview.retiredCount) to retire")
                checked += 1
                additions += preview.addedCount
            } catch {
                skipped += 1
                print("\(deck.name): skipped — \(error.localizedDescription)")
            }
        }
        print("Snapshot dry run: \(checked) poem deck(s) checked; \(additions) opening card(s) planned; \(skipped) skipped")
        if skipped > 0 { throw RepairError.message("Some poem decks need manual review.") }
    }

    private static func plan(
        deck: APIDeck, items: [APIItem], types: [String: APIItemType], openingCards: Bool
    ) throws -> DeckPlan {
        guard !items.isEmpty, items.allSatisfy({ $0.cardIds.count == 1 }),
              zip(items, items.dropFirst()).allSatisfy({ $0.0.createdAt <= $0.1.createdAt }),
              let deckID = UUID(uuidString: deck.id) else {
            throw RepairError.message("The deck's card count or creation order is unreliable.")
        }
        let records = try items.enumerated().map { index, item -> PoemDeckItemRecord in
            guard let type = types[item.itemTypeId] else { throw RepairError.message("Missing item type.") }
            // The endpoint preserves full database creation order; JSON dates
            // round to milliseconds. Use that order instead of re-sorting ties.
            return try .init(
                item: item.domain(), itemType: type.domain(),
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let snapshot = try PoemDeckReconciler.snapshot(records: records)
        let preview = try PoemDeckReconciler.preview(
            sourceText: snapshot.sourceText, records: records,
            title: openingCards ? deck.name : nil, deckID: deckID
        )
        guard preview.operations.count <= 500 else {
            throw RepairError.message("The atomic repair exceeds the API's 500-operation limit.")
        }
        return .init(deck: deck, originals: items, preview: preview, openingCards: openingCards)
    }

    private static func itemObject(_ item: Item) throws -> [String: Any] {
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item.fields.map(APIFieldValue.init)))
        return ["id": item.id.uuidString.lowercased(), "itemTypeId": item.itemTypeID.uuidString.lowercased(),
                "deckId": item.deckID?.uuidString.lowercased() as Any? ?? NSNull(), "fields": fields, "tags": item.tags]
    }

    private static func apply(_ plan: DeckPlan, api: LocalAPI) async throws {
        guard let order = plan.preview.order else { throw RepairError.message("Missing deck order.") }
        var preservedCards: [String: Data] = [:]
        for item in plan.originals {
            let current = try LocalAPI.decoder.decode(APIItem.self, from: await api.request("/v1/items/\(item.id)"))
            guard current == item else { throw RepairError.message("Item changed since preview; run the command again.") }
            for id in item.cardIds {
                preservedCards[id] = try await api.request("/v1/cards/\(id)")
            }
        }
        let operations = try plan.preview.operations.map { operation -> [String: Any] in
            switch operation.action {
            case let .create(item):
                return ["operationId": operation.operationID, "action": "create", "item": try itemObject(item)]
            case let .replace(item):
                return ["operationId": operation.operationID, "action": "replace", "item": try itemObject(item)]
            case let .delete(id):
                return ["operationId": operation.operationID, "action": "delete", "itemId": id.uuidString.lowercased()]
            }
        }
        let orderObject: [String: Any] = [
            "deckId": order.deckID.uuidString.lowercased(),
            "expectedItems": try order.expectedItems.map(itemObject),
            "orderedItemIds": order.orderedItemIDs.map { $0.uuidString.lowercased() },
        ]
        let dryRun = try JSONSerialization.data(withJSONObject: [
            "atomic": true, "dryRun": true, "operations": operations, "order": orderObject,
        ])
        _ = try await api.request("/v1/items/bulk", method: "POST", body: dryRun)
        let commit = try JSONSerialization.data(withJSONObject: [
            "atomic": true, "dryRun": false, "operations": operations, "order": orderObject,
        ])
        _ = try await api.request("/v1/items/bulk", method: "POST", body: commit, key: UUID().uuidString)
        let final: [APIItem] = try await api.all("/v1/items")
        let members = final.filter { $0.deckId == plan.deck.id }
        let types: [APIItemType] = try await api.all("/v1/item-types")
        let verified = try Self.plan(deck: plan.deck, items: members,
                                types: Dictionary(uniqueKeysWithValues: types.map { ($0.id, $0) }),
                                openingCards: plan.openingCards)
        guard !verified.preview.hasChanges,
              members.map(\.id) == order.orderedItemIDs.map({ $0.uuidString.lowercased() }) else {
            throw RepairError.message("Post-repair sequence verification failed.")
        }
        let retired = plan.preview.retiredOpeningCard?.id.uuidString.lowercased()
        for item in plan.originals where item.id != retired {
            guard members.first(where: { $0.id == item.id })?.cardIds == item.cardIds else {
                throw RepairError.message("Existing card identities changed.")
            }
            for id in item.cardIds {
                let before = try JSONSerialization.jsonObject(with: preservedCards[id]!) as? [String: Any]
                let after = try JSONSerialization.jsonObject(with: await api.request("/v1/cards/\(id)")) as? [String: Any]
                let oldMemory = before?["memory"] as? NSDictionary
                let newMemory = after?["memory"] as? NSDictionary
                // New-card introduction times intentionally change; learned
                // memory and schedules must remain byte-for-byte equivalent.
                if oldMemory?["phase"] as? String != "new", oldMemory != newMemory {
                    throw RepairError.message("A learned card's memory or schedule changed.")
                }
            }
        }
    }
}
