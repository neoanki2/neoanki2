import Foundation
import NeoAnkiAPI
import PoemDeckBuilder

private struct PlannedItem {
    let original: APIItem
    let fields: [[String: Any]]
}

private struct DeckPlan {
    let deck: APIDeck
    let changes: [PlannedItem]
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
              (200 ..< 300).contains(response.statusCode)
        else {
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
        do {
            try await run()
        } catch {
            fputs("poem repair: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.allSatisfy({ $0 == "--apply" || $0 == "--dry-run" }),
              !(args.contains("--apply") && args.contains("--dry-run")) else {
            throw RepairError.message("Usage: neoanki-poem-repair [--dry-run | --apply]")
        }
        let shouldApply = args.contains("--apply")
        guard let token = ProcessInfo.processInfo.environment["NEOANKI_API_TOKEN"], !token.isEmpty else {
            throw RepairError.message("Set NEOANKI_API_TOKEN with library.read and items.write scopes.")
        }
        let port = Int(ProcessInfo.processInfo.environment["NEOANKI_API_PORT"] ?? "8766") ?? 8_766
        guard (1_024 ... 65_535).contains(port),
              let url = URL(string: "http://127.0.0.1:\(port)/") else {
            throw RepairError.message("NEOANKI_API_PORT must be a local API port.")
        }
        let api = LocalAPI(baseURL: url, token: token)
        let decks: [APIDeck] = try await api.all("/v1/decks")
        let types: [APIItemType] = try await api.all("/v1/item-types")
        let items: [APIItem] = try await api.all("/v1/items")
        let typeByID = Dictionary(uniqueKeysWithValues: types.map { ($0.id, $0) })
        let itemsByDeck = Dictionary(grouping: items.compactMap { item -> (String, APIItem)? in
            item.deckId.map { ($0, item) }
        }, by: \.0)

        var plans: [DeckPlan] = []
        var skipped = 0
        for deck in decks {
            let members = itemsByDeck[deck.id]?.map(\.1) ?? []
            guard members.contains(where: { typeByID[$0.itemTypeId]?.name == "Poem Line" }) else {
                continue
            }
            do {
                let plan = try plan(deck: deck, items: members, types: typeByID)
                plans.append(plan)
                print("\(deck.name): \(plan.changes.count) card(s) to repair")
            } catch {
                skipped += 1
                print("\(deck.name): skipped — \(error.localizedDescription)")
            }
        }

        if shouldApply {
            for plan in plans where !plan.changes.isEmpty {
                do {
                    try await apply(plan, api: api)
                    print("\(plan.deck.name): verified")
                } catch {
                    skipped += 1
                    print("\(plan.deck.name): incomplete — \(error.localizedDescription)")
                }
            }
        } else {
            print("Dry run only. Pass --apply to repair the listed local decks.")
        }
        print("\(plans.count) poem deck(s) checked; \(skipped) skipped or incomplete")
        if skipped > 0 { throw RepairError.message("Some poem decks need manual review.") }
    }

    private static func plan(
        deck: APIDeck,
        items: [APIItem],
        types: [String: APIItemType]
    ) throws -> DeckPlan {
        guard !items.isEmpty,
              Set(items.map(\.itemTypeId)).count == 1,
              let type = types[items[0].itemTypeId],
              type.name == "Poem Line", type.templates.count == 1,
              items.allSatisfy({ $0.cardIds.count == 1 }),
              let front = type.fields.first(where: { $0.name == "Front" && $0.type == "text" }),
              let back = type.fields.first(where: { $0.name == "Back" && $0.type == "text" }),
              let attribution = type.fields.first(where: { $0.name == "Attribution" && $0.type == "text" })
        else { throw RepairError.message("deck is mixed or does not have the generated poem schema") }
        let marker = type.fields.first(where: { $0.name == "Stanza Break" && $0.type == "text" })
        // The unfiltered items endpoint is ordered by the database's full
        // creation timestamp. Its JSON timestamps have only millisecond
        // precision, so sorting or rejecting ties here would lose that order.
        let ordered = items
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.0.createdAt <= $0.1.createdAt }) else {
            throw RepairError.message("creation order is not reliable")
        }
        guard let first = text(front.id, in: ordered[0]),
              !first.isEmpty, !first.contains("\n") else {
            throw RepairError.message("first poem line cannot be recovered")
        }
        var parts = [first]
        let caption = text(attribution.id, in: ordered[0])
        guard caption != nil else { throw RepairError.message("attribution is missing") }
        var previousLine = first
        for item in ordered {
            guard text(attribution.id, in: item) == caption,
                  text(front.id, in: item)?
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .last.map(String.init) == previousLine,
                  let raw = text(back.id, in: item) else {
                throw RepairError.message("poem order, metadata, or answer is inconsistent")
            }
            let answer = raw.hasPrefix("\n") ? String(raw.dropFirst()) : raw
            guard !answer.isEmpty, !answer.contains("\n") else {
                throw RepairError.message("an answer contains multiple lines")
            }
            if raw.hasPrefix("\n") || (marker.flatMap { text($0.id, in: item) } ?? "") != "" {
                parts.append("")
            }
            parts.append(answer)
            previousLine = answer
        }
        let poem = PoemDeckGenerator.parse(parts.joined(separator: "\n"))
        guard poem.lines.count == ordered.count + 1,
              poem.lines.map(\.text) == [first] + ordered.map({ item in
                  let raw = text(back.id, in: item)!
                  return raw.hasPrefix("\n") ? String(raw.dropFirst()) : raw
              }) else {
            throw RepairError.message("source is not a canonical generated poem")
        }
        let prompts = PoemPromptPlanner.prompts(for: poem)
        var changes: [PlannedItem] = []
        for (index, item) in ordered.enumerated() {
            let answer = poem.lines[index + 1]
            let desiredBack = (answer.startsStanza ? "\n" : "") + answer.text
            let oldBack = text(back.id, in: item)!
            let oldFront = text(front.id, in: item)
            let oldMarker = marker.flatMap { text($0.id, in: item) } ?? ""
            guard oldFront != nil else {
                throw RepairError.message("a prompt is missing")
            }
            if oldFront == prompts[index], oldBack == desiredBack, oldMarker.isEmpty { continue }
            var fields = try fieldObjects(item)
            replace(front.id, with: ["type": "text", "text": prompts[index]], in: &fields)
            replace(back.id, with: ["type": "text", "text": desiredBack], in: &fields)
            if let marker { replace(marker.id, with: ["type": "empty"], in: &fields) }
            changes.append(.init(original: item, fields: fields))
        }
        return .init(deck: deck, changes: changes)
    }

    private static func apply(_ plan: DeckPlan, api: LocalAPI) async throws {
        for batch in plan.changes.chunked(into: 500) {
            for change in batch {
                let current = try LocalAPI.decoder.decode(
                    APIItem.self,
                    from: await api.request("/v1/items/\(change.original.id)")
                )
                guard current.revision == change.original.revision else {
                    throw RepairError.message("item changed since preview; run the command again")
                }
            }
            let operations: [[String: Any]] = batch.map { change in
                ["operationId": change.original.id, "action": "replace", "item": [
                    "id": change.original.id,
                    "itemTypeId": change.original.itemTypeId,
                    "deckId": change.original.deckId as Any? ?? NSNull(),
                    "fields": change.fields,
                    "tags": change.original.tags,
                ]]
            }
            let dryRun = try JSONSerialization.data(withJSONObject: [
                "atomic": true, "dryRun": true, "operations": operations,
            ])
            _ = try await api.request("/v1/items/bulk", method: "POST", body: dryRun)
            let commit = try JSONSerialization.data(withJSONObject: [
                "atomic": true, "dryRun": false, "operations": operations,
            ])
            _ = try await api.request(
                "/v1/items/bulk", method: "POST", body: commit, key: UUID().uuidString
            )
            for change in batch {
                let current = try LocalAPI.decoder.decode(
                    APIItem.self,
                    from: await api.request("/v1/items/\(change.original.id)")
                )
                guard current.cardIds == change.original.cardIds,
                      try fieldObjects(current).elementsEqual(change.fields, by: fieldsEqual)
                else { throw RepairError.message("post-repair verification failed") }
            }
        }
    }

    private static func text(_ id: String, in item: APIItem) -> String? {
        guard let value = item.fields.first(where: { $0.fieldId == id })?.value,
              value.type == "text" else { return nil }
        return value.text
    }

    private static func fieldObjects(_ item: APIItem) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(item.fields)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw RepairError.message("item fields could not be encoded")
        }
        return fields
    }

    private static func replace(_ id: String, with value: [String: Any], in fields: inout [[String: Any]]) {
        if let index = fields.firstIndex(where: { $0["fieldId"] as? String == id }) {
            fields[index]["value"] = value
        } else {
            fields.append(["fieldId": id, "value": value])
        }
    }

    private static func fieldsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
