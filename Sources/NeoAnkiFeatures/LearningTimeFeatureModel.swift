import Foundation
import NeoAnkiApplication
import NeoAnkiCore
import Observation

@MainActor @Observable
public final class LearningTimeFeatureModel {
    public var period: LearningTimePeriod = .today
    public private(set) var summary: LearningTimeSummary?
    public private(set) var today: LearningTimeSummary?
    public private(set) var allTime: LearningTimeSummary?
    public private(set) var error: String?
    public private(set) var isLoading = false
    public let scope: DeckScope
    private let capability: (any LibraryLearningTime)?
    private let library: any LibraryRepository
    private var generation = 0

    public init(library: any LibraryRepository, scope: DeckScope, learningTime: (any LibraryLearningTime)? = nil) {
        self.library = library; self.scope = scope
        capability = learningTime ?? (library as? any LibraryLearningTime)
    }

    public func refresh() async {
        guard let capability else { return }
        generation += 1
        let requested = generation; let requestedPeriod = period
        isLoading = true
        do {
            let now = Date.now; let calendar = Calendar.autoupdatingCurrent
            async let current = capability.learningTimeSummary(scope: scope, period: requestedPeriod, asOf: now, calendar: calendar)
            async let daily = capability.learningTimeSummary(scope: scope, period: .today, asOf: now, calendar: calendar)
            async let lifetime = capability.learningTimeSummary(scope: scope, period: .allTime, asOf: now, calendar: calendar)
            let result = try await (current, daily, lifetime)
            guard requested == generation else { return }
            summary = result.0; today = result.1; allTime = result.2; error = nil
        } catch {
            guard requested == generation else { return }
            self.error = "Could not refresh learning time. Showing the last saved totals. \(error.localizedDescription)"
        }
        if requested == generation { isLoading = false }
    }

    public func observe() async {
        await refresh()
        await withTaskGroup(of: Void.self) { group in
            if let capability {
                group.addTask { [weak self] in
                    let stream = await capability.learningTimeNotifications()
                    for await _ in stream { if Task.isCancelled { break }; await self?.refresh() }
                }
            }
            let library = library
            group.addTask { [weak self] in
                let stream = await library.changeNotifications()
                for await _ in stream { if Task.isCancelled { break }; await self?.refresh() }
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await self?.refresh()
                }
            }
            await group.waitForAll()
        }
    }
}
