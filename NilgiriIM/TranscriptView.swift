import SwiftUI

private let terminalColumns = 80
private let ink = Color(white: 0.78)
private let screen = Color.black
private let transcriptBottomID = "transcript-bottom"

struct TranscriptView: View {
    @EnvironmentObject private var session: IMSession
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var commandFocused: Bool
    /// Last resume reveal this view has started. A newer token runs the separator ease.
    @State private var scrolledBacklogToken = 0
    /// While a reveal is in flight, appear and line-change must not jump to the bottom.
    @State private var suppressBottomScroll = false
    /// A live line arrived during the reveal and should jump to the bottom once it ends.
    @State private var bottomScrollDeferred = false
    /// Content-size pinning is what snaps a resume to the end and leaves the ease
    /// with nowhere to travel. It is suspended until the ease finishes. The initial
    /// bottom anchor stays in place on iOS 18, so this does not rebuild the scroll view.
    @State private var pinToBottom = true
    /// Invalidates a bottom scroll still waiting on the layout delay.
    @State private var bottomScrollGeneration = 0
    /// Invalidates an older reveal when a newer backlog arrives.
    @State private var revealGeneration = 0
    /// Height of the input bar overlaid on the transcript. The scroll content's
    /// minimum height stays above it, so a short log still fills the visible area.
    @State private var inputBarHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fontSize = max(8, (geo.size.width - 16) / CGFloat(terminalColumns) / 0.62)
                let transcriptHeight = max(0, geo.size.height - inputBarHeight)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(session.lines) { line in
                                    transcriptLine(line, fontSize: fontSize)
                                        .id(line.id)
                                }
                            }
                            .padding(.vertical, 8)
                            .frame(minWidth: geo.size.width, minHeight: transcriptHeight, alignment: .topLeading)
                            Color.clear
                                .frame(height: 1)
                                .allowsHitTesting(false)
                                .id(transcriptBottomID)
                        }
                        .frame(width: geo.size.width)
                    }
                    .modifier(TranscriptBottomAnchor(suspendSizePin: pinToBottom == false))
                    .onAppear { handleTranscriptScroll(proxy, linesChanged: false) }
                    .onChange(of: session.lines) { _, _ in
                        handleTranscriptScroll(proxy, linesChanged: true)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        inputBar
                    }
                }
            }
            .background(screen)
            .onPreferenceChange(InputBarHeightKey.self) { inputBarHeight = $0 }
            .preferredColorScheme(.dark)
            .toolbarBackground(screen, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle(session.character ?? "IM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Unlink") {
                        Task { await session.logout(closeMud: true) }
                    }
                    .foregroundStyle(ink)
                    .accessibilityLabel("Unlink")
                }
            }
            .onChange(of: scenePhase) { _, phase in
                Task {
                    if phase == .background {
                        await session.sceneWentBackground()
                    } else if phase == .active {
                        await session.sceneBecameActive()
                    }
                }
            }
            .task {
                await PushRegistration.request(session: session)
            }
        }
    }

    private func sendCommand() async {
        await session.send()
        commandFocused = false
    }

    /// Sits in the scroll view's bottom safe area, so lines travel under the blur
    /// and the bottom anchor still rests above the bar.
    private var inputBar: some View {
        HStack {
            Text(">")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(ink)
            TextField("command", text: $session.command)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($commandFocused)
                .onSubmit { Task { await sendCommand() } }
            Button("Send") { Task { await sendCommand() } }
                .foregroundStyle(ink)
        }
        .padding(12)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: InputBarHeightKey.self, value: proxy.size.height)
            }
        }
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .bottom)
        .simultaneousGesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    let translation = value.translation
                    if translation.height > abs(translation.width), translation.height > 0 {
                        commandFocused = false
                    }
                }
        )
    }

    /// Login fills `lines` before this view exists, so the first backlog is an appear,
    /// not an onChange. A separator reveal owns the scroll until it eases to the bottom.
    /// Anything else jumps to the bottom after layout, including the short retry.
    private func handleTranscriptScroll(_ proxy: ScrollViewProxy, linesChanged: Bool) {
        if session.backlogScrollToken != scrolledBacklogToken, let separatorID = session.resumeSeparatorID {
            scrolledBacklogToken = session.backlogScrollToken
            runResumeReveal(proxy, separatorID: separatorID)
            return
        }
        if suppressBottomScroll {
            if linesChanged {
                bottomScrollDeferred = true
            }
            return
        }
        scrollToBottom(proxy)
    }

    /// (a) Sit on the separator with no animation, after the backlog has laid out.
    /// (b) Hold there ~0.45s. Bottom scrolls and the bottom default anchor stay off,
    ///     so a layout pass cannot snap the transcript to the end.
    /// (c) Ease to the bottom over 1s. Then bottom-pinning and live-line jumps resume.
    private func runResumeReveal(_ proxy: ScrollViewProxy, separatorID: String) {
        revealGeneration += 1
        bottomScrollGeneration += 1
        let generation = revealGeneration
        suppressBottomScroll = true
        bottomScrollDeferred = false
        pinToBottom = false

        let gate = RevealGate()
        let placeOnSeparator = {
            guard generation == revealGeneration, gate.eased == false else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(separatorID, anchor: .top)
            }
        }
        DispatchQueue.main.async(execute: placeOnSeparator)
        // Lazy rows often miss the first scrollTo. This second placement is still
        // the unanimated separator pin, inside the settle window, and it will not
        // run once the ease has started.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: placeOnSeparator)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard generation == revealGeneration else { return }
            gate.eased = true
            withAnimation(.easeInOut(duration: 1.0)) {
                proxy.scrollTo(transcriptBottomID, anchor: .bottom)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
                guard generation == revealGeneration else { return }
                suppressBottomScroll = false
                pinToBottom = true
                if bottomScrollDeferred {
                    bottomScrollDeferred = false
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        bottomScrollGeneration += 1
        let generation = bottomScrollGeneration
        let scroll = {
            guard generation == bottomScrollGeneration, suppressBottomScroll == false else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(transcriptBottomID, anchor: .bottom)
            }
        }
        DispatchQueue.main.async(execute: scroll)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: scroll)
    }

    @ViewBuilder
    private func transcriptLine(_ line: LineDTO, fontSize: CGFloat) -> some View {
        if line.isSeparator {
            separatorRow(line)
        } else {
            Ansi.text(line.text, fontSize: fontSize, columns: terminalColumns)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
    }

    /// Full-width hairline with the disconnect time centered on it. The row has no
    /// horizontal padding, so the line meets both edges of the transcript.
    private func separatorRow(_ line: LineDTO) -> some View {
        let stamp = line.disconnectAt.map { DisconnectSeparator.stamp(at: $0) } ?? line.text
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
            Text(stamp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle()
                .fill(Color.secondary)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Disconnected \(stamp)")
    }

}

private struct InputBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Lets the late separator pin see that the ease has already begun.
private final class RevealGate {
    var eased = false
}

/// `.defaultScrollAnchor(.bottom)` applies to the first layout and to later content-size
/// changes. The size-change half is what yanks a resume backlog to the end while an
/// ease is running, so the animation has no distance to travel. On iOS 18 the two roles
/// are separate and the size-change anchor can be cleared without rebuilding the scroll
/// view. On iOS 17 the single modifier has to come off for the same interval.
private struct TranscriptBottomAnchor: ViewModifier {
    var suspendSizePin: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            let sizeAnchor: UnitPoint? = suspendSizePin ? nil : .bottom
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(sizeAnchor, for: .sizeChanges)
        } else if suspendSizePin {
            content
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}
