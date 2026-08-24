#if os(iOS)
import SwiftUI
import UIKit

/// The public-facing SwiftUI surface. Drop this inside a `.sheet { … }`
/// from your settings screen. The look is "ink-on-paper" — no host accent,
/// no system blue, mono caps everywhere identity matters.
public struct LoopReporterView: View {
    @StateObject private var model: LoopReporterModel
    @State private var kind: LoopItem.Kind = .bug
    /// Setting this presents the compose sheet pre-selected to the bound
    /// kind. Using a single Identifiable trigger (instead of a Bool +
    /// separate kind state) avoids the race where SwiftUI reads the cover
    /// content closure before the kind state has actually applied.
    @State private var composeRequest: ComposeRequest?
    @State private var submittedId: String?

    private struct ComposeRequest: Identifiable {
        let kind: LoopItem.Kind
        var id: String { kind.rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    public init() {
        let runtime = LoopSDK.runtime()
        _model = StateObject(wrappedValue: runtime.makeReporterModel())
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                LoopColors.bg(dark: dark).ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    titleBlock
                    tabs
                    content
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: String.self) { itemId in
                LoopDetailView(model: model, itemId: itemId)
            }
        }
        .preferredColorScheme(.dark)  // Brutalist palette is designed dark-first
        .task { await model.bootstrap() }
        .fullScreenCover(item: $composeRequest) { req in
            LoopComposeSheet(model: model, initialKind: req.kind) { result in
                composeRequest = nil
                submittedId = result.id
            }
            .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: Binding(
            get: { submittedId.map(SubmittedId.init) },
            set: { if $0 == nil { submittedId = nil } }
        )) { wrap in
            LoopSubmittedView(
                itemId: wrap.id,
                onSeeBoard: { submittedId = nil },
                onFileAnother: {
                    submittedId = nil
                    let next = kind
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        composeRequest = ComposeRequest(kind: next)
                    }
                },
                // Nil unless this project has `collect_email` on, which keeps
                // the promise that the decision ships with the developer's
                // project settings and never with an SDK bump. Nil while the
                // project blob is still loading too — an unknown flag is not
                // permission to ask for an address.
                onSubmitEmail: LoopEmailPrompt.handler(client: model.client, project: model.project)
            )
            .preferredColorScheme(.dark)
        }
        .alert(
            Text("Loop", bundle: .module),
            isPresented: errorPresented
        ) {
            Button(role: .cancel) { model.transientError = nil } label: {
                Text("OK", bundle: .module)
            }
        } message: {
            Text(model.transientError ?? "")
        }
    }

    private struct SubmittedId: Identifiable { let id: String }

    // MARK: - Header

    private var header: some View {
        let projectName = model.project?.name ?? String(localized: "Loop", bundle: .module)
        let headerTitle = String(
            localized: "\(projectName) · Feedback",
            bundle: .module
        )
        return HStack(alignment: .center) {
            Button(action: { dismiss() }) {
                Text("Close", bundle: .module)
                    .font(LoopFont.sf(15, .regular))
                    .kerning(-0.2)
                    .foregroundStyle(LoopColors.textSecondary(dark: dark))
            }

            Spacer()

            MonoCaps(text: headerTitle, size: 11, kerning: 1.2)

            Spacer()

            Button(action: {
                composeRequest = ComposeRequest(kind: kind)
            }) {
                ZStack {
                    Circle().fill(LoopColors.ink(dark: dark))
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(LoopColors.onInk(dark: dark))
                }
                .frame(width: 34, height: 34)
            }
            .accessibilityLabel(Text("New report", bundle: .module))
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: - Title block

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind == .bug ? "Bugs" : "Features", bundle: .module)
                .font(LoopFont.sf(38, .heavy))
                .kerning(-1.4)
                .textCase(.uppercase)
                .foregroundStyle(LoopColors.text(dark: dark))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            MonoCaps(
                text: String(
                    localized: "\(currentCount) reports · sorted by votes",
                    bundle: .module
                ),
                kerning: 0.6
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var currentCount: Int {
        kind == .bug ? model.bugs.count : model.features.count
    }

    // MARK: - Tabs

    private var tabs: some View {
        HStack(spacing: 18) {
            tab(
                .bug,
                label: String(localized: "Bugs", bundle: .module),
                count: model.bugs.count
            )
            tab(
                .feature,
                label: String(localized: "Features", bundle: .module),
                count: model.features.count
            )
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LoopColors.separator(dark: dark))
                .frame(height: 1)
        }
    }

    private func tab(_ k: LoopItem.Kind, label: String, count: Int) -> some View {
        let active = kind == k
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { kind = k }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(LoopFont.sf(14, .semibold))
                    .kerning(-0.2)
                    .foregroundStyle(active
                        ? LoopColors.text(dark: dark)
                        : LoopColors.textSecondary(dark: dark))
                Text(verbatim: "\(count)")
                    .font(LoopFont.mono(11, .regular).monospacedDigit())
                    .foregroundStyle(active
                        ? LoopColors.text(dark: dark)
                        : LoopColors.textTertiary(dark: dark))
            }
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? LoopColors.ink(dark: dark) : Color.clear)
                    .frame(height: 2)
                    .offset(y: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .bug:
            LoopItemListView(
                state: model.bugsState,
                items: model.bugs,
                hasMore: model.bugsCursor != nil,
                kind: .bug,
                onRefresh: { await model.refreshBugs() },
                onLoadMore: { await model.loadMoreBugs() },
                onVote: { item, dir in await model.vote(item: item, dir: dir) },
                onCompose: {
                    composeRequest = ComposeRequest(kind: .bug)
                }
            )
        case .feature:
            LoopItemListView(
                state: model.featuresState,
                items: model.features,
                hasMore: model.featuresCursor != nil,
                kind: .feature,
                onRefresh: { await model.refreshFeatures() },
                onLoadMore: { await model.loadMoreFeatures() },
                onVote: { item, dir in await model.vote(item: item, dir: dir) },
                onCompose: {
                    composeRequest = ComposeRequest(kind: .feature)
                }
            )
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.transientError != nil },
            set: { if !$0 { model.transientError = nil } }
        )
    }
}

// MARK: - List

private struct LoopItemListView: View {
    let state: LoopReporterModel.LoadState
    let items: [LoopItem]
    let hasMore: Bool
    let kind: LoopItem.Kind
    let onRefresh: () async -> Void
    let onLoadMore: () async -> Void
    let onVote: (LoopItem, VoteDir?) async -> Void
    let onCompose: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        switch state {
        case .idle:
            ProgressView()
                .tint(LoopColors.text(dark: dark))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loading where items.isEmpty:
            ProgressView()
                .tint(LoopColors.text(dark: dark))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message) where items.isEmpty:
            LoopErrorPanel(message: message, retry: onRefresh)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded where items.isEmpty:
            LoopEmptyPanel(kind: kind, onCompose: onCompose)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        default:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        NavigationLink(value: item.id) {
                            LoopItemRow(
                                item: item,
                                onVote: { dir in Task { await onVote(item, dir) } }
                            )
                        }
                        .buttonStyle(.plain)
                        if idx < items.count - 1 {
                            Rectangle()
                                .fill(LoopColors.separator(dark: dark))
                                .frame(height: 1)
                                .padding(.horizontal, 20)
                        }
                    }

                    if hasMore {
                        ProgressView()
                            .tint(LoopColors.text(dark: dark))
                            .padding()
                            .task { await onLoadMore() }
                    }
                }
                .padding(.vertical, 4)
            }
            .refreshable { await onRefresh() }
        }
    }
}

// MARK: - Empty panel

private struct LoopEmptyPanel: View {
    let kind: LoopItem.Kind
    let onCompose: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        (dark ? Color.white.opacity(0.2) : Color.black.opacity(0.18)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                    )
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(LoopColors.textSecondary(dark: dark))
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 8) {
                Text("Nothing reported yet", bundle: .module)
                    .font(LoopFont.sf(22, .bold))
                    .kerning(-0.5)
                    .foregroundStyle(LoopColors.text(dark: dark))
                    .multilineTextAlignment(.center)
                Text("Hit something odd, or got an idea? Be the first to log it — the team gets it instantly.", bundle: .module)
                    .font(LoopFont.sf(14))
                    .kerning(-0.15)
                    .foregroundStyle(LoopColors.textSecondary(dark: dark))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .lineSpacing(2)
            }

            Button(action: onCompose) {
                Text(kind == .bug ? "File a bug" : "File a feature request", bundle: .module)
                    .font(LoopFont.sf(15, .semibold))
                    .kerning(-0.2)
                    .foregroundStyle(LoopColors.onInk(dark: dark))
                    .padding(.horizontal, 22)
                    .frame(height: 46)
                    .background(LoopColors.ink(dark: dark), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
    }
}

// MARK: - Error panel

private struct LoopErrorPanel: View {
    let message: String
    let retry: () async -> Void

    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(LoopColors.textSecondary(dark: dark))
            Text("Couldn't load", bundle: .module)
                .font(LoopFont.sf(18, .semibold))
                .foregroundStyle(LoopColors.text(dark: dark))
            Text(message)
                .font(LoopFont.sf(13))
                .foregroundStyle(LoopColors.textSecondary(dark: dark))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button { Task { await retry() } } label: {
                Text("Try again", bundle: .module)
            }
                .font(LoopFont.sf(14, .semibold))
                .foregroundStyle(LoopColors.onInk(dark: dark))
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(LoopColors.ink(dark: dark), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 4)
        }
    }
}
#endif
