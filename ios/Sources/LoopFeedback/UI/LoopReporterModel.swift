#if os(iOS)
import Foundation
import SwiftUI

/// View-model behind `LoopReporterView`. Holds the bug + feature lists,
/// drives loading/voting/submitting, and surfaces user-visible errors.
///
/// Uses `ObservableObject` instead of `@Observable` so we keep iOS 16
/// compatibility (Observation framework is iOS 17+).
@MainActor
final class LoopReporterModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published var project: LoopProject?
    @Published var projectState: LoadState = .idle

    @Published var bugs: [LoopItem] = []
    @Published var bugsCursor: String?
    @Published var bugsState: LoadState = .idle

    @Published var features: [LoopItem] = []
    @Published var featuresCursor: String?
    @Published var featuresState: LoadState = .idle

    @Published var transientError: String?

    // Detail-view state — populated when the user pushes into a row.
    @Published var detail: LoopItemDetail?
    @Published var detailState: LoadState = .idle

    let client: LoopClient
    let reporterId: String
    let sessionId: String
    let tierProvider: LoopConfiguration.TierProvider?

    init(
        client: LoopClient,
        reporterId: String,
        sessionId: String,
        tierProvider: LoopConfiguration.TierProvider? = nil
    ) {
        self.client = client
        self.reporterId = reporterId
        self.sessionId = sessionId
        self.tierProvider = tierProvider
    }

    func bootstrap() async {
        await loadProject()
        async let b: Void = refreshBugs()
        async let f: Void = refreshFeatures()
        _ = await (b, f)
    }

    func loadProject() async {
        projectState = .loading
        do {
            project = try await client.fetchProject()
            projectState = .loaded
        } catch let error as LoopError {
            projectState = .failed(humanise(error))
        } catch {
            projectState = .failed(String(localized: "Couldn't reach Loop.", bundle: .module))
        }
    }

    func refreshBugs() async {
        bugsState = .loading
        do {
            let page = try await client.fetchBugs()
            bugs = page.items
            bugsCursor = page.nextCursor
            bugsState = .loaded
        } catch {
            bugsState = .failed(humanise(error))
        }
    }

    func loadMoreBugs() async {
        guard let cursor = bugsCursor else { return }
        do {
            let page = try await client.fetchBugs(cursor: cursor)
            bugs.append(contentsOf: page.items)
            bugsCursor = page.nextCursor
        } catch {
            transientError = humanise(error)
        }
    }

    func refreshFeatures() async {
        featuresState = .loading
        do {
            let page = try await client.fetchFeatures()
            features = page.items
            featuresCursor = page.nextCursor
            featuresState = .loaded
        } catch {
            featuresState = .failed(humanise(error))
        }
    }

    func loadMoreFeatures() async {
        guard let cursor = featuresCursor else { return }
        do {
            let page = try await client.fetchFeatures(cursor: cursor)
            features.append(contentsOf: page.items)
            featuresCursor = page.nextCursor
        } catch {
            transientError = humanise(error)
        }
    }

    /// Optimistic vote — updates local state immediately, rolls back on
    /// failure.
    func vote(item: LoopItem, dir: VoteDir?) async {
        let kind = item.kind
        let originalIndex = index(of: item.id, in: kind)
        guard let idx = originalIndex else { return }
        let original = items(for: kind)[idx]

        let optimistic = optimisticUpdate(item: original, newDir: dir)
        update(item: optimistic, kind: kind)

        do {
            let result = try await client.vote(itemId: item.id, dir: dir)
            // Server is the source of truth — re-sync the count.
            let synced = LoopItem(
                id: original.id,
                kind: original.kind,
                status: original.status,
                title: original.title,
                body: original.body,
                whenLabel: original.whenLabel,
                createdAt: original.createdAt,
                votes: result.votes,
                my: result.my,
                replyCount: original.replyCount
            )
            update(item: synced, kind: kind)
        } catch {
            update(item: original, kind: kind)
            transientError = humanise(error)
        }
    }

    // MARK: - Detail

    /// Loads `LoopItemDetail` for the given `LP-####` id. The result is
    /// published on `detail`; `detailState` reflects loading/error.
    func loadDetail(for itemId: String) async {
        detailState = .loading
        do {
            let item = try await client.fetchItem(itemId: itemId)
            detail = item
            detailState = .loaded
        } catch {
            detailState = .failed(humanise(error))
        }
    }

    /// Casts a vote on the currently-loaded detail item. Optimistic, with
    /// rollback on failure. Also syncs the matching list row so the inbox
    /// stays consistent when you swipe back.
    func voteOnDetail(dir: VoteDir?) async {
        guard let original = detail else { return }
        let delta = voteDelta(from: original.my, to: dir)

        detail = LoopItemDetail(
            id: original.id, kind: original.kind, status: original.status,
            title: original.title, body: original.body,
            whenLabel: original.whenLabel, createdAt: original.createdAt,
            votes: original.votes + delta, my: dir, replyCount: original.replyCount,
            thread: original.thread, meta: original.meta
        )

        do {
            let result = try await client.vote(itemId: original.id, dir: dir)
            let synced = LoopItemDetail(
                id: original.id, kind: original.kind, status: original.status,
                title: original.title, body: original.body,
                whenLabel: original.whenLabel, createdAt: original.createdAt,
                votes: result.votes, my: result.my, replyCount: original.replyCount,
                thread: original.thread, meta: original.meta
            )
            detail = synced

            // Also patch the corresponding list row.
            let synced_list = LoopItem(
                id: original.id, kind: original.kind, status: original.status,
                title: original.title, body: original.body,
                whenLabel: original.whenLabel, createdAt: original.createdAt,
                votes: result.votes, my: result.my, replyCount: original.replyCount
            )
            update(item: synced_list, kind: original.kind)
        } catch {
            detail = original
            transientError = humanise(error)
        }
    }

    /// Posts a reply on the currently-loaded detail item. Pre-pends the
    /// reply locally so the user sees it instantly; rolls back on failure.
    func postReply(body: String) async {
        guard let original = detail else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let reply = try await client.postReply(itemId: original.id, body: trimmed)
            let withReply = LoopItemDetail(
                id: original.id, kind: original.kind, status: original.status,
                title: original.title, body: original.body,
                whenLabel: original.whenLabel, createdAt: original.createdAt,
                votes: original.votes, my: original.my,
                replyCount: original.replyCount + 1,
                thread: original.thread + [reply],
                meta: original.meta
            )
            detail = withReply

            // Bump the list row's replyCount too so the inbox count is fresh.
            if let row = items(for: original.kind).first(where: { $0.id == original.id }) {
                let bumped = LoopItem(
                    id: row.id, kind: row.kind, status: row.status,
                    title: row.title, body: row.body,
                    whenLabel: row.whenLabel, createdAt: row.createdAt,
                    votes: row.votes, my: row.my, replyCount: row.replyCount + 1
                )
                update(item: bumped, kind: row.kind)
            }
        } catch {
            transientError = humanise(error)
        }
    }

    private func voteDelta(from old: VoteDir?, to new: VoteDir?) -> Int {
        switch (old, new) {
        case (nil, .up?): return 1
        case (nil, .down?): return -1
        case (.up, nil): return -1
        case (.down, nil): return 1
        case (.up, .down?): return -2
        case (.down, .up?): return 2
        default: return 0
        }
    }

    /// Submits a new bug or feature.
    func submit(kind: LoopItem.Kind, title: String, body: String) async throws -> LoopSubmissionResult {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        let device = DeviceMeta.capture(sessionId: sessionId)
        // Resolved fresh on every submit so a downgrade (paid → free)
        // shows up on the next report without the host having to call
        // any setter. nil when the host didn't configure a tierProvider.
        let resolvedTier = LoopConfiguration.resolveTier(from: tierProvider)
        let payload = LoopClient.SubmitPayload(
            type: kind.rawValue,
            title: trimmedTitle,
            body: trimmedBody,
            reporter_id: reporterId,
            device_meta: LoopClient.DeviceMetaPayload(
                device: device.device,
                os: device.os,
                appVersion: device.appVersion,
                locale: device.locale,
                network: device.network,
                sessionId: device.sessionId
            ),
            user: resolvedTier.map { LoopClient.UserPayload(tier: $0) }
        )

        let result = try await client.submit(payload: payload)
        // Refresh whichever list changed.
        switch kind {
        case .bug: await refreshBugs()
        case .feature: await refreshFeatures()
        }
        return result
    }

    // MARK: - Helpers

    private func optimisticUpdate(item: LoopItem, newDir: VoteDir?) -> LoopItem {
        let delta: Int
        switch (item.my, newDir) {
        case (nil, .up?): delta = 1
        case (nil, .down?): delta = -1
        case (.up, nil): delta = -1
        case (.down, nil): delta = 1
        case (.up, .down?): delta = -2
        case (.down, .up?): delta = 2
        case (.up, .up?), (.down, .down?), (nil, nil): delta = 0
        default: delta = 0
        }

        return LoopItem(
            id: item.id,
            kind: item.kind,
            status: item.status,
            title: item.title,
            body: item.body,
            whenLabel: item.whenLabel,
            createdAt: item.createdAt,
            votes: item.votes + delta,
            my: newDir,
            replyCount: item.replyCount
        )
    }

    private func items(for kind: LoopItem.Kind) -> [LoopItem] {
        kind == .bug ? bugs : features
    }

    private func index(of id: String, in kind: LoopItem.Kind) -> Int? {
        items(for: kind).firstIndex(where: { $0.id == id })
    }

    private func update(item: LoopItem, kind: LoopItem.Kind) {
        switch kind {
        case .bug:
            if let i = bugs.firstIndex(where: { $0.id == item.id }) { bugs[i] = item }
        case .feature:
            if let i = features.firstIndex(where: { $0.id == item.id }) { features[i] = item }
        }
    }

    private func humanise(_ error: Error) -> String {
        if let err = error as? LoopError {
            switch err {
            case .invalidApiKey:
                return String(localized: "Loop SDK isn't configured correctly.", bundle: .module)
            case .badRequest(let m):
                return m ?? String(localized: "That didn't go through. Try again.", bundle: .module)
            case .notFound:
                return String(localized: "Couldn't find that report.", bundle: .module)
            case .serverError:
                return String(localized: "Loop is having trouble — try again in a moment.", bundle: .module)
            case .transport(.notConnectedToInternet),
                 .transport(.networkConnectionLost):
                return String(localized: "You're offline.", bundle: .module)
            case .transport(.timedOut):
                return String(localized: "Loop took too long to respond.", bundle: .module)
            case .transport(.cancelled):
                return String(localized: "Cancelled.", bundle: .module)
            case .transport:
                return String(localized: "Network problem.", bundle: .module)
            case .decoding:
                return String(localized: "Got an unexpected response from Loop.", bundle: .module)
            case .unknown:
                return String(localized: "Something went wrong.", bundle: .module)
            }
        }
        return error.localizedDescription
    }
}
#endif
