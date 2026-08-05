import Foundation
import NeoAnkiAPI
import NeoAnkiCore
import Network
import Observation

struct APIPairingPrompt: Identifiable {
    let id = UUID()
    let request: APIPairingRequest
}

private struct AppPairingApprover: APIPairingApprover {
    let handler: @Sendable (APIPairingRequest) async -> Bool
    let cancellationHandler: @Sendable (APIPairingRequest) async -> Void

    func approve(_ request: APIPairingRequest) async -> Bool {
        await handler(request)
    }

    func cancel(_ request: APIPairingRequest) async {
        await cancellationHandler(request)
    }
}

@MainActor
@Observable
final class APIControlModel {
    private let store: ItemStore
    private let vocabularyRootURL: URL
    private let authorization: APIAuthorizationStore
    private var server: NeoAnkiLocalAPIServer?
    private var pairingContinuation: CheckedContinuation<Bool, Never>?

    var isEnabled = false
    var port = 8_766
    private(set) var isRunning = false
    private(set) var isChangingState = false
    private(set) var diagnostic: String?
    private(set) var clients: [APIClientGrant] = []
    var pendingPairing: APIPairingPrompt?

    init(store: ItemStore, vocabularyRootURL: URL) {
        self.store = store
        self.vocabularyRootURL = vocabularyRootURL
        authorization = APIAuthorizationStore(
            persistence: VerifierFileAPICredentialPersistence(
                fileURL: vocabularyRootURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(".neoanki-api", isDirectory: true)
                    .appendingPathComponent(
                        VerifierFileAPICredentialPersistence.fileName,
                        isDirectory: false
                    )
            )
        )
        port = UserDefaults.standard.object(forKey: AppPreferences.localAPIPort) as? Int
            ?? 8_766
        isEnabled = UserDefaults.standard.bool(forKey: AppPreferences.localAPIEnabled)
    }

    func restore() async {
        await reloadClients()
        if isEnabled { await start() }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isChangingState else { return }
        if enabled {
            await start()
        } else {
            await stop()
        }
    }

    func applyPort(_ value: Int) async {
        guard (1_024 ... 65_535).contains(value), value != port else { return }
        let wasEnabled = isEnabled
        if isRunning { await stop(persistDisabled: false) }
        port = value
        UserDefaults.standard.set(value, forKey: AppPreferences.localAPIPort)
        if wasEnabled { await start() }
    }

    func reloadClients() async {
        clients = (try? await authorization.listGrants()) ?? []
    }

    func revoke(_ client: APIClientGrant) async {
        _ = try? await authorization.revoke(clientID: client.id)
        await reloadClients()
    }

    func resolvePairing(approved: Bool) {
        pairingContinuation?.resume(returning: approved)
        pairingContinuation = nil
        pendingPairing = nil
        Task { await reloadClients() }
    }

    private func start() async {
        guard !isChangingState, !isRunning else { return }
        guard (1_024 ... 65_535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            diagnostic = "Choose a port from 1024 through 65535."
            isEnabled = false
            return
        }
        isChangingState = true
        diagnostic = nil
        defer { isChangingState = false }
        let approver = AppPairingApprover(
            handler: { [weak self] request in
                guard let self else { return false }
                return await self.requestPairingApproval(request)
            },
            cancellationHandler: { [weak self] request in
                await self?.cancelPairingApproval(request)
            }
        )
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "development"
        let service = NeoAnkiAPIService(
            store: store,
            authorization: authorization,
            pairingApprover: approver,
            applicationVersion: version,
            authority: "127.0.0.1:\(port)",
            vocabularyRootURL: vocabularyRootURL
        )
        let candidate = NeoAnkiLocalAPIServer(
            service: service,
            configuration: .init(host: "127.0.0.1", port: endpointPort)
        )
        do {
            try await candidate.start()
            server = candidate
            isRunning = true
            isEnabled = true
            UserDefaults.standard.set(true, forKey: AppPreferences.localAPIEnabled)
        } catch {
            await candidate.stop()
            server = nil
            isRunning = false
            isEnabled = false
            UserDefaults.standard.set(false, forKey: AppPreferences.localAPIEnabled)
            diagnostic = "Port \(port) is unavailable. NeoAnki did not try another port."
        }
    }

    private func stop(persistDisabled: Bool = true) async {
        guard !isChangingState else { return }
        isChangingState = true
        defer { isChangingState = false }
        await server?.stop()
        server = nil
        isRunning = false
        isEnabled = false
        diagnostic = nil
        resolvePairing(approved: false)
        if persistDisabled {
            UserDefaults.standard.set(false, forKey: AppPreferences.localAPIEnabled)
        }
    }

    private func requestPairingApproval(_ request: APIPairingRequest) async -> Bool {
        guard pairingContinuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            pairingContinuation = continuation
            pendingPairing = APIPairingPrompt(request: request)
        }
    }

    private func cancelPairingApproval(_ request: APIPairingRequest) {
        guard pendingPairing?.request == request else { return }
        resolvePairing(approved: false)
    }
}
