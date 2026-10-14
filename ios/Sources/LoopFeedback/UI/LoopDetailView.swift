#if os(iOS)
import SwiftUI

/// Single-item detail screen. Pushed from `LoopReporterView` when the user
/// taps a row. Matches the brutalist "ink-on-paper" board design — big
/// vote bar, auto-captured meta strip on bugs, full thread, and a pill
/// composer pinned to the bottom.
struct LoopDetailView: View {
    @ObservedObject var model: LoopReporterModel
    let itemId: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var replyText: String = ""
    @State private var sendingReply = false
    @FocusState private var replyFocus: Bool

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            LoopColors.bg(dark: dark).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                switch model.detailState {
                case .loaded where model.detail?.id == itemId:
                    if let detail = model.detail {
                        scroll(detail)
                        composer
                    }

                case .failed(let message):
                    failurePane(message)

                default:
                    ProgressView()
                        .tint(LoopColors.text(dark: dark))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .task(id: itemId) {
            await model.loadDetail(for: itemId)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .heavy))
                    Text("Back", bundle: .module)
                        .font(LoopFont.sf(15, .regular))
                        .kerning(-0.2)
                }
                .foregroundStyle(LoopColors.textSecondary(dark: dark))
            }
            Spacer()
            MonoCaps(text: itemId, size: 11, kerning: 0.6)
            Spacer()
            // Keeps the title centred — invisible match for the back button.
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .heavy))
                Text("Back", bundle: .module).font(LoopFont.sf(15))
            }
            .opacity(0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: - Scrollable body

    private func scroll(_ detail: LoopItemDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                tagsRow(detail)
                title(detail)
                body(detail)
                voteBar(detail)
                if detail.kind == .bug, let meta = detail.meta {
                    metaStrip(meta)
                }
                threadSection(detail)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func tagsRow(_ detail: LoopItemDetail) -> some View {
        HStack(spacing: 8) {
            LoopKindTag(kind: detail.kind)
            LoopStatusLabel(status: detail.status)
            Spacer()
        }
        .padding(.bottom, 14)
    }

    private func title(_ detail: LoopItemDetail) -> some View {
        Text(detail.title)
            .font(LoopFont.sf(26, .bold))
            .kerning(-0.6)
            .foregroundStyle(LoopColors.text(dark: dark))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)
    }

    private func body(_ detail: LoopItemDetail) -> some View {
        Text(detail.body)
            .font(LoopFont.sf(15))
            .kerning(-0.2)
            .foregroundStyle(LoopColors.textSecondary(dark: dark))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 22)
    }

    // MARK: - Vote bar (big)

    private func voteBar(_ detail: LoopItemDetail) -> some View {
        HStack(spacing: 14) {
            voteButton(direction: .up, current: detail.my)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(detail.votes)")
                    .font(LoopFont.sf(22, .bold).monospacedDigit())
                    .foregroundStyle(LoopColors.text(dark: dark))
                MonoCaps(
                    text: String(localized: "Net votes", bundle: .module),
                    size: 10.5,
                    kerning: 0.6
                )
            }
            Spacer()
            voteButton(direction: .down, current: detail.my)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(LoopColors.surf(dark: dark), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LoopColors.separator(dark: dark), lineWidth: 1)
        )
        .padding(.bottom, 22)
    }

    private func voteButton(direction: VoteDir, current: VoteDir?) -> some View {
        let active = current == direction
        let icon = direction == .up ? "chevron.up" : "chevron.down"
        return Button {
            Task { await model.voteOnDetail(dir: active ? nil : direction) }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(active
                    ? LoopColors.onInk(dark: dark)
                    : LoopColors.textSecondary(dark: dark))
                .frame(width: 44, height: 44)
                .background(
                    active ? LoopColors.ink(dark: dark) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(active ? Color.clear : LoopColors.separator(dark: dark), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text(direction == .up ? "Vote up" : "Vote down", bundle: .module)
        )
    }

    // MARK: - Auto-captured meta

    private func metaStrip(_ meta: LoopItemMeta) -> some View {
        let rows: [(String, String?)] = [
            (String(localized: "Device", bundle: .module), meta.device),
            (String(localized: "iOS", bundle: .module), meta.os?.replacingOccurrences(of: "iOS ", with: "")),
            (String(localized: "App", bundle: .module), meta.appVersion),
            (String(localized: "Session", bundle: .module), meta.sessionId.map { String($0.prefix(10)) + "…" })
        ]

        return VStack(alignment: .leading, spacing: 10) {
            MonoCaps(text: String(localized: "Auto-captured", bundle: .module))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        MonoCaps(text: row.0, size: 9.5, kerning: 0.6)
                        Text(row.1 ?? "—")
                            .font(LoopFont.sf(13, .semibold))
                            .kerning(-0.15)
                            .foregroundStyle(LoopColors.text(dark: dark))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(LoopColors.bg(dark: dark))
                }
            }
            .background(LoopColors.separator(dark: dark))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LoopColors.separator(dark: dark), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.bottom, 22)
    }

    // MARK: - Thread

    private func threadSection(_ detail: LoopItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoCaps(
                text: String(
                    localized: "Thread · \(detail.replyCount)",
                    bundle: .module
                )
            )
            if detail.thread.isEmpty {
                Text("Be the first to reply.", bundle: .module)
                    .font(LoopFont.sf(13))
                    .foregroundStyle(LoopColors.textTertiary(dark: dark))
                    .padding(.vertical, 4)
            } else {
                ForEach(detail.thread) { reply in
                    threadEntry(reply, projectName: model.project?.name)
                }
            }
        }
    }

    private func threadEntry(_ reply: LoopReply, projectName: String?) -> some View {
        let isDev = reply.from == .dev
        let label: String = {
            if isDev {
                if let author = reply.authorName { return author }
                if let project = projectName {
                    return String(localized: "\(project) team", bundle: .module)
                }
                return String(localized: "Team", bundle: .module)
            }
            return String(localized: "Anonymous", bundle: .module)
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(isDev ? LoopColors.ink(dark: dark) : LoopColors.subtleFill(dark: dark))
                    Text(String(label.prefix(1)).uppercased())
                        .font(LoopFont.sf(10, .semibold))
                        .foregroundStyle(isDev ? LoopColors.onInk(dark: dark) : LoopColors.text(dark: dark))
                }
                .frame(width: 22, height: 22)
                Text(label)
                    .font(LoopFont.sf(13, .semibold))
                    .kerning(-0.15)
                    .foregroundStyle(LoopColors.text(dark: dark))
                Spacer()
                Text(reply.whenLabel)
                    .font(LoopFont.mono(10.5))
                    .kerning(0.4)
                    .foregroundStyle(LoopColors.textTertiary(dark: dark))
            }
            Text(reply.body)
                .font(LoopFont.sf(14))
                .foregroundStyle(LoopColors.text(dark: dark))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            isDev ? LoopColors.surf(dark: dark) : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LoopColors.separator(dark: dark), lineWidth: 1)
        )
    }

    // MARK: - Reply composer (pill at bottom)

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: $replyText,
                prompt: Text("Add a reply…", bundle: .module)
                    .foregroundColor(LoopColors.textTertiary(dark: dark))
            )
            .focused($replyFocus)
            .textInputAutocapitalization(.sentences)
            .font(LoopFont.sf(14))
            .foregroundStyle(LoopColors.text(dark: dark))
            .padding(.leading, 14)

            Button {
                let body = replyText
                replyText = ""
                replyFocus = false
                sendingReply = true
                Task {
                    await model.postReply(body: body)
                    sendingReply = false
                }
            } label: {
                ZStack {
                    Circle().fill(LoopColors.ink(dark: dark))
                    if sendingReply {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(LoopColors.onInk(dark: dark))
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(LoopColors.onInk(dark: dark))
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(sendingReply || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            .padding(.trailing, 6)
        }
        .frame(height: 44)
        .background(LoopColors.surf(dark: dark), in: Capsule())
        .overlay(Capsule().stroke(LoopColors.separator(dark: dark), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Failure pane

    private func failurePane(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(LoopColors.textSecondary(dark: dark))
            Text("Couldn't load", bundle: .module)
                .font(LoopFont.sf(18, .semibold))
                .foregroundStyle(LoopColors.text(dark: dark))
            Text(message)
                .font(LoopFont.sf(13))
                .foregroundStyle(LoopColors.textSecondary(dark: dark))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await model.loadDetail(for: itemId) }
            } label: {
                Text("Try again", bundle: .module)
            }
            .font(LoopFont.sf(14, .semibold))
            .foregroundStyle(LoopColors.onInk(dark: dark))
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(LoopColors.ink(dark: dark), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
