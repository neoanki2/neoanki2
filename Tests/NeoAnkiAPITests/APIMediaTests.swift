import Foundation
@testable import NeoAnkiAPI
import NeoAnkiCore
import Testing

@Test func mediaUploadDownloadDeduplicatesBytesAndReservationsAdoptIndependently() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(
        api,
        scopes: ["library.read", "media.write", "items.write"]
    )
    let auth = ["Authorization": "Bearer \(token)"]
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x41])
    func upload(_ key: String, kind: String = "image") async -> APIResponse {
        return await api.handle(APIRequest(
            method: .post,
            path: "/v1/media",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": key,
                "NeoAnki-Media-Kind": kind,
            ],
            body: bytes
        ))
    }
    let first = await upload("first-upload")
    let firstReplay = await upload("first-upload")
    let second = await upload("second-upload")
    #expect(first.status == 201)
    #expect(first.body == firstReplay.body)
    let firstObject = try jsonObject(first)
    let secondObject = try jsonObject(second)
    let hash = try #require(firstObject["assetHash"] as? String)
    #expect(secondObject["assetHash"] as? String == hash)
    #expect(secondObject["reservationId"] as? String != firstObject["reservationId"] as? String)

    let downloaded = await api.handle(request(.get, "/v1/media/\(hash)", headers: auth))
    #expect(downloaded.status == 200)
    #expect(downloaded.body == bytes)
    #expect(downloaded.headers["Content-Type"] == "image/png")
    let head = await api.handle(request(.head, "/v1/media/\(hash)", headers: auth))
    #expect(head.status == 200)
    #expect(head.body.isEmpty)
    #expect(head.headers["Content-Length"] == String(bytes.count))
    let range = await api.handle(request(
        .get,
        "/v1/media/\(hash)",
        headers: auth.merging(["Range": "bytes=0-3"]) { _, new in new }
    ))
    #expect(range.status == 416)
    #expect(range.headers["Accept-Ranges"] == "none")
    #expect(await api.handle(
        request(.get, "/v1/media/\(String(repeating: "0", count: 64))", headers: auth)
    ).status == 404)
    let wrongKind = await upload("wrong-kind", kind: "audio")
    #expect(wrongKind.status == 422)

    let imageField = FieldDef(name: "Image", type: .image, isRequired: true)
    let answerField = FieldDef(name: "Answer", type: .text, isRequired: true)
    let template = Template(
        name: "Image card",
        prompt: Side(slots: [Slot(source: .field(imageField.id))]),
        answer: Side(slots: [Slot(source: .field(answerField.id))]),
        interaction: .reveal,
        skill: Skill(input: .image, output: .text, operation: .recall)
    )
    let type = ItemType(name: "Media API", fields: [imageField, answerField], templates: [template])
    _ = try await store.createItemType(type)

    func createMediaItem(
        _ key: String,
        reservation: [String: Any],
        assetHash: String? = nil
    ) async throws -> APIResponse {
        let body: [String: Any] = [
            "itemTypeId": type.id.uuidString.lowercased(),
            "deckId": NSNull(),
            "fields": [
                [
                    "fieldId": imageField.id.uuidString.lowercased(),
                    "value": [
                        "type": "media",
                        "mediaId": UUID().uuidString.lowercased(),
                        "kind": "image",
                        "sha256": assetHash ?? hash,
                        "fileExtension": "png",
                        "reservationId": try #require(reservation["reservationId"] as? String),
                    ],
                ],
                [
                    "fieldId": answerField.id.uuidString.lowercased(),
                    "value": ["type": "text", "text": "Answer"],
                ],
            ],
            "tags": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return await api.handle(APIRequest(
            method: .post,
            path: "/v1/items",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": key,
            ],
            body: data
        ))
    }

    let fabricatedReservation: [String: Any] = [
        "reservationId": UUID().uuidString.lowercased(),
    ]
    let unresolvedReservation = try await createMediaItem(
        "fabricated-media-reservation",
        reservation: fabricatedReservation
    )
    #expect(unresolvedReservation.status == 422)
    #expect(try jsonObject(unresolvedReservation)["code"] as? String == "validation_failed")

    let unresolvedAsset = try await createMediaItem(
        "missing-media-asset",
        reservation: firstObject,
        assetHash: String(repeating: "0", count: 64)
    )
    #expect(unresolvedAsset.status == 422)
    #expect(try await store.listItems().isEmpty)

    let itemOne = try await createMediaItem("media-item-one", reservation: firstObject)
    let itemTwo = try await createMediaItem("media-item-two", reservation: secondObject)
    #expect(itemOne.status == 201)
    #expect(itemTwo.status == 201)
    let metadata = await api.handle(request(.get, "/v1/media/\(hash)/metadata", headers: auth))
    #expect(try jsonObject(metadata)["referenceCount"] as? Int == 2)

    let itemOneID = try #require(try jsonObject(itemOne)["id"] as? String)
    var deleteHeaders = auth
    deleteHeaders["If-Match"] = itemOne.headers["ETag"]
    #expect(await api.handle(
        request(.delete, "/v1/items/\(itemOneID)", headers: deleteHeaders)
    ).status == 204)
    #expect(await api.handle(request(.get, "/v1/media/\(hash)", headers: auth)).body == bytes)
}

@Test func mediaUploadRecoversTheSameReservationAfterProcessExit() async throws {
    let store = try ItemStore(databaseURL: apiTestDatabaseURL())
    try await store.bootstrap()
    let authorization = APIAuthorizationStore(
        persistence: InMemoryAPICredentialPersistence()
    )
    func service(faultInjector: any APIFaultInjector = NoAPIFaultInjector()) -> NeoAnkiAPIService {
        NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: ApproveAllPairings(),
            applicationVersion: "test",
            faultInjector: faultInjector
        )
    }

    let faultedService = service(
        faultInjector: ConfiguredAPIFaultInjector(point: .mediaAfterReservation)
    )
    let token = try await pair(
        faultedService,
        scopes: ["library.read", "media.write"]
    )
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x42])
    let key = "media-process-exit"
    func upload(using api: NeoAnkiAPIService) async -> APIResponse {
        await api.handle(APIRequest(
            method: .post,
            path: "/v1/media",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": key,
                "NeoAnki-Media-Kind": "image",
            ],
            body: bytes
        ))
    }

    let interrupted = await upload(using: faultedService)
    #expect(interrupted.status == 500)

    let grant = try #require(try await authorization.authenticate(token: token))
    var hashInput = Data("POST\n/v1/media\nimage\n\n".utf8)
    hashInput.append(bytes)
    let requestHash = APICrypto.sha256Hex(hashInput)
    let pendingClaim = try #require(try await store.idempotencyClaim(
        clientID: grant.id,
        route: "POST /v1/media",
        key: key,
        requestHash: requestHash
    ))
    let reservationID: String
    switch pendingClaim {
    case let .pending(resultResourceID):
        reservationID = try #require(resultResourceID)
    default:
        Issue.record("The interrupted upload must leave a recoverable pending claim.")
        return
    }
    let assetHash = APICrypto.sha256Hex(bytes)
    #expect(try await store.mediaAsset(hash: assetHash)?.refCount == 0)

    let restartedService = service()
    let recovered = await upload(using: restartedService)
    #expect(recovered.status == 201)
    #expect(try jsonObject(recovered)["reservationId"] as? String == reservationID)
    #expect(try jsonObject(recovered)["assetHash"] as? String == assetHash)

    let replay = await upload(using: restartedService)
    #expect(replay.status == 201)
    #expect(replay.body == recovered.body)
    #expect(try await store.mediaAsset(hash: assetHash)?.refCount == 0)
    let downloaded = await restartedService.handle(request(
        .get,
        "/v1/media/\(assetHash)",
        headers: ["Authorization": "Bearer \(token)"]
    ))
    #expect(downloaded.status == 200)
    #expect(downloaded.body == bytes)
}

@Test func everySupportedMediaSignatureRoundTripsAndHostileUploadsDoNotPersist() async throws {
    let (api, store) = try await makeAPIAndStore()
    let token = try await pair(api, scopes: ["library.read", "media.write"])
    let auth = ["Authorization": "Bearer \(token)"]

    func ascii(_ value: String) -> [UInt8] { Array(value.utf8) }
    func iso(_ brand: String, compatible: String? = nil) -> Data {
        var bytes: [UInt8] = [0, 0, 0, compatible == nil ? 16 : 20]
        bytes += ascii("ftyp") + ascii(brand) + [0, 0, 0, 0]
        if let compatible { bytes += ascii(compatible) }
        return Data(bytes)
    }
    let fixtures: [(kind: String, ext: String, bytes: Data)] = [
        ("audio", "mp3", Data(ascii("ID3fixture"))),
        ("audio", "wav", Data(ascii("RIFF0000WAVEfixture"))),
        ("audio", "aac", Data([0xFF, 0xF0, 0x50, 0x80])),
        ("audio", "caf", Data(ascii("cafffixture"))),
        ("audio", "m4a", iso("M4A ")),
        ("image", "png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1])),
        ("image", "jpg", Data([0xFF, 0xD8, 0xFF, 0xE0])),
        ("image", "heic", iso("heic")),
        ("image", "webp", Data(ascii("RIFF0000WEBPfixture"))),
        ("image", "tiff", Data([0x49, 0x49, 0x2A, 0x00, 1])),
        ("gif", "gif", Data(ascii("GIF89afixture"))),
        ("video", "mov", iso("qt  ")),
        ("video", "m4v", iso("M4V ")),
        ("video", "mp4", iso("isom")),
    ]
    for (index, fixture) in fixtures.enumerated() {
        let uploaded = await api.handle(APIRequest(
            method: .post,
            path: "/v1/media",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": "format-\(index)",
                "NeoAnki-Media-Kind": fixture.kind,
            ],
            body: fixture.bytes
        ))
        #expect(uploaded.status == 201)
        let object = try jsonObject(uploaded)
        let hash = try #require(object["assetHash"] as? String)
        #expect(hash == APICrypto.sha256Hex(fixture.bytes))
        #expect(object["fileExtension"] as? String == fixture.ext)
        let downloaded = await api.handle(request(
            .get, "/v1/media/\(hash)", headers: auth
        ))
        #expect(downloaded.status == 200)
        #expect(downloaded.body == fixture.bytes)
        #expect(await api.handle(request(
            .head, "/v1/media/\(hash)", headers: auth
        )).status == 200)
    }

    func rejected(_ key: String, kind: String, bytes: Data) async -> APIResponse {
        await api.handle(APIRequest(
            method: .post,
            path: "/v1/media",
            headers: [
                "Host": "127.0.0.1:8766",
                "Authorization": "Bearer \(token)",
                "Idempotency-Key": key,
                "NeoAnki-Media-Kind": kind,
            ],
            body: bytes
        ))
    }
    let beforeHostile = try await store.currentChangeCursor()
    #expect(await rejected("wrong-magic", kind: "image", bytes: Data("not-media".utf8)).status == 422)
    #expect(await rejected("kind-mismatch", kind: "audio", bytes: fixtures[5].bytes).status == 422)
    #expect(await rejected("ambiguous", kind: "audio", bytes: iso("M4A ", compatible: "isom")).status == 422)
    #expect(try await store.currentChangeCursor() == beforeHostile)

    for (index, kind) in [MediaKind.audio, .image, .gif, .video].enumerated() {
        var bytes = Data(repeating: 0, count: MediaValidation.maxBytes(for: kind) + 1)
        bytes.replaceSubrange(0 ..< min(fixtures[index == 0 ? 0 : index + 4].bytes.count, bytes.count),
                              with: fixtures[index == 0 ? 0 : index + 4].bytes.prefix(bytes.count))
        let response = await rejected("oversize-\(kind.rawValue)", kind: kind.rawValue, bytes: bytes)
        #expect(response.status == 413)
    }
}
