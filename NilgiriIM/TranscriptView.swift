import os
import SwiftUI

private let terminalColumns = 80
private let ink = Color(white: 0.78)
private let screen = Color.black
private let transcriptBottomID = "transcript-bottom"
/// Above this, the transcript stays lazy and the ease walks in short hops.
private let modestTranscriptCount = 600
private let scrollLog = Logger(subsystem: "net.nilgiri.imclient", category: "scroll")

struct TranscriptView: View {
    @EnvironmentObject private var session: IMSession
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var commandFocused: Bool
    /// Programmatic scroll target. Nil leaves the scroll view alone.
    @State private var positionedID: String?
    /// Where `positionedID` sits in the visible region. The separator jump uses
    /// `.top`; the ease to the latest line uses `.bottom`.
    @State private var positionAnchor: UnitPoint = .bottom
    /// A live line arrived during the reveal and should jump to the bottom once it ends.
    @State private var bottomScrollDeferred = false
    /// Invalidates a bottom scroll still waiting on the layout delay.
    @State private var bottomScrollGeneration = 0
    /// Invalidates an older reveal when a newer backlog arrives.
    @State private var revealGeneration = 0
    @State private var revealStarted: Date?
    @State private var runningSeparatorID: String?
    @State private var separatorVisibleID: String?
    @State private var easeStarted = false
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
                        lineStack(fontSize: fontSize)
                            .padding(.vertical, 8)
                            .frame(minWidth: geo.size.width, minHeight: transcriptHeight, alignment: .topLeading)
                            .frame(width: geo.size.width)
                    }
                    .scrollPosition(id: $positionedID, anchor: positionAnchor)
                    .modifier(TranscriptBottomAnchor(enabled: session.pendingResumeReveal == false))
                    .onAppear { considerReveal(proxy, reason: "appear") }
                    .onChange(of: session.lines) { _, _ in
                        considerReveal(proxy, reason: "lines")
                    }
                    .onChange(of: session.pendingResumeReveal) { _, _ in
                        considerReveal(proxy, reason: "pending")
                    }
                    .onChange(of: scenePhase) { _, phase in
                        let phaseName = String(describing: phase)
                        scrollLog.debug("scenePhase=\(phaseName, privacy: .public)")
                        considerReveal(proxy, reason: "phase")
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

    /// Bottom snaps stay off for the whole time a resume reveal is pending, including
    /// before the scene is active. Appear and line changes still jump to the bottom
    /// when nothing is pending.
    private func considerReveal(_ proxy: ScrollViewProxy, reason: String) {
        guard session.pendingResumeReveal, let separatorID = session.resumeSeparatorID else {
            if reason == "appear" || reason == "lines" {
                scrollToBottom(proxy)
            }
            return
        }
        guard scenePhase == .active else {
            let phaseName = String(describing: scenePhase)
            scrollLog.debug("reveal deferred reason=\(reason, privacy: .public) phase=\(phaseName, privacy: .public)")
            return
        }
        if runningSeparatorID == separatorID, revealStarted != nil {
            if reason == "lines" {
                bottomScrollDeferred = true
                scrollLog.debug("lines during reveal; bottom snap suppressed")
            }
            return
        }
        startReveal(proxy, separatorID: separatorID, reason: reason)
    }

    /// Jump to the separator only after the scene is active, then ease once a real
    /// layout pass has produced the row.
    private func startReveal(_ proxy: ScrollViewProxy, separatorID: String, reason: String) {
        revealGeneration += 1
        bottomScrollGeneration += 1
        let generation = revealGeneration
        revealStarted = Date()
        runningSeparatorID = separatorID
        easeStarted = false
        bottomScrollDeferred = false
        if separatorVisibleID != separatorID {
            separatorVisibleID = nil
        }
        scrollLog.debug("reveal start reason=\(reason, privacy: .public) separator=\(separatorID, privacy: .public) lines=\(session.lines.count) anchor=off")
        DispatchQueue.main.async {
            guard generation == self.revealGeneration else { return }
            self.jumpToSeparator(proxy, id: separatorID, attempt: 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard generation == self.revealGeneration, self.easeStarted == false else { return }
            guard self.separatorVisibleID != separatorID else { return }
            self.jumpToSeparator(proxy, id: separatorID, attempt: 2)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.maybeEase(generation: generation, separatorID: separatorID, reason: "0.4s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.maybeEase(generation: generation, separatorID: separatorID, reason: "fallback")
        }
    }

    private func jumpToSeparator(_ proxy: ScrollViewProxy, id: String, attempt: Int) {
        guard easeStarted == false else { return }
        scrollLog.debug("jump to separator attempt=\(attempt) id=\(id, privacy: .public)")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            positionAnchor = .top
            positionedID = id
            proxy.scrollTo(id, anchor: .top)
        }
    }

    private func separatorBecameVisible(_ id: String) {
        guard session.pendingResumeReveal, id == session.resumeSeparatorID else { return }
        guard separatorVisibleID != id else { return }
        separatorVisibleID = id
        scrollLog.debug("separator onAppear id=\(id, privacy: .public)")
        guard let separatorID = runningSeparatorID, revealStarted != nil else { return }
        maybeEase(generation: revealGeneration, separatorID: separatorID, reason: "separator onAppear")
    }

    /// Ease only after the separator row has appeared and at least 0.4s has passed
    /// since the reveal started. The 0.8s fallback eases even if the row never appeared.
    private func maybeEase(generation: Int, separatorID: String, reason: String) {
        guard generation == revealGeneration, easeStarted == false else { return }
        let elapsed = revealStarted.map { Date().timeIntervalSince($0) } ?? 0
        let visible = separatorVisibleID == separatorID
        let elapsedText = String(format: "%.2f", elapsed)
        let visibleText = visible ? "yes" : "no"
        let ready = elapsed >= 0.4 && (visible || reason == "fallback")
        guard ready else {
            scrollLog.debug("ease waiting reason=\(reason, privacy: .public) elapsed=\(elapsedText, privacy: .public) visible=\(visibleText, privacy: .public)")
            return
        }
        scrollLog.debug("ease go reason=\(reason, privacy: .public) elapsed=\(elapsedText, privacy: .public) visible=\(visibleText, privacy: .public) lines=\(session.lines.count)")
        easeToBottom(generation: generation, separatorID: separatorID)
    }

    private func easeToBottom(generation: Int, separatorID: String) {
        easeStarted = true
        let hops = easeHops(from: separatorID)
        let count = hops.count
        if count <= 1 {
            scrollLog.debug("ease single scrollPosition duration=1.0")
            withAnimation(.easeInOut(duration: 1.0)) {
                positionAnchor = .bottom
                positionedID = transcriptBottomID
            }
            scheduleEaseFinish(generation: generation, separatorID: separatorID, after: 1.05)
            return
        }
        let slice = 1.0 / Double(count)
        let sliceText = String(format: "%.2f", slice)
        scrollLog.debug("ease stepped hops=\(count) slice=\(sliceText, privacy: .public)")
        for (index, hop) in hops.enumerated() {
            let delay = slice * Double(index)
            let anchor: UnitPoint = index == count - 1 ? .bottom : .top
            let hopNumber = index + 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard generation == self.revealGeneration else { return }
                scrollLog.debug("ease hop \(hopNumber)/\(count) id=\(hop, privacy: .public)")
                withAnimation(.easeInOut(duration: slice)) {
                    self.positionAnchor = anchor
                    self.positionedID = hop
                }
            }
        }
        scheduleEaseFinish(generation: generation, separatorID: separatorID, after: 1.05)
    }

    /// One hop when the transcript is small enough to lay out eagerly. A long lazy
    /// list walks intermediate line ids so a single far scrollTo is not skipped.
    private func easeHops(from separatorID: String) -> [String] {
        if session.lines.count <= modestTranscriptCount {
            return [transcriptBottomID]
        }
        guard let start = session.lines.firstIndex(where: { $0.id == separatorID }) else {
            return [transcriptBottomID]
        }
        let distance = session.lines.count - start
        if distance <= 40 {
            return [transcriptBottomID]
        }
        let hopCount = min(8, max(2, distance / 40))
        var ids: [String] = []
        for step in 1...hopCount {
            let offset = min(distance - 1, distance * step / hopCount)
            ids.append(session.lines[start + offset].id)
        }
        if ids.last != transcriptBottomID {
            ids.append(transcriptBottomID)
        }
        return ids
    }

    private func scheduleEaseFinish(generation: Int, separatorID: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == self.revealGeneration else { return }
            self.finishEase(separatorID: separatorID)
        }
    }

    private func finishEase(separatorID: String) {
        scrollLog.debug("ease finished; restoring bottom anchor")
        revealStarted = nil
        easeStarted = false
        runningSeparatorID = nil
        let deferred = bottomScrollDeferred
        bottomScrollDeferred = false
        session.finishResumeReveal(separatorID: separatorID)
        if deferred {
            scrollLog.debug("deferred bottom snap after ease")
            scrollToBottomNow()
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if session.pendingResumeReveal {
            bottomScrollDeferred = true
            scrollLog.debug("suppress bottom snap")
            return
        }
        bottomScrollGeneration += 1
        let generation = bottomScrollGeneration
        let scroll = {
            guard generation == self.bottomScrollGeneration else { return }
            guard self.session.pendingResumeReveal == false else {
                self.scrollLogSuppress()
                return
            }
            self.scrollToBottomNow(proxy)
        }
        DispatchQueue.main.async(execute: scroll)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: scroll)
    }

    private func scrollLogSuppress() {
        scrollLog.debug("suppress delayed bottom snap")
    }

    private func scrollToBottomNow(_ proxy: ScrollViewProxy) {
        scrollLog.debug("bottom snap")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            positionAnchor = .bottom
            positionedID = transcriptBottomID
            proxy.scrollTo(transcriptBottomID, anchor: .bottom)
        }
    }

    /// Used when the ease ends and the proxy from the original call is not required.
    private func scrollToBottomNow() {
        scrollLog.debug("bottom snap without proxy")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            positionAnchor = .bottom
            positionedID = transcriptBottomID
        }
    }

    @ViewBuilder
    private func lineStack(fontSize: CGFloat) -> some View {
        if session.lines.count > modestTranscriptCount {
            LazyVStack(alignment: .leading, spacing: 0) {
                lineRows(fontSize: fontSize)
                bottomMarker
            }
            .scrollTargetLayout()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                lineRows(fontSize: fontSize)
                bottomMarker
            }
            .scrollTargetLayout()
        }
    }

    private var bottomMarker: some View {
        Color.clear
            .frame(height: 1)
            .allowsHitTesting(false)
            .id(transcriptBottomID)
    }

    @ViewBuilder
    private func lineRows(fontSize: CGFloat) -> some View {
        ForEach(session.lines) { line in
            transcriptLine(line, fontSize: fontSize)
                .id(line.id)
        }
    }

    @ViewBuilder
    private func transcriptLine(_ line: LineDTO, fontSize: CGFloat) -> some View {
        if line.isSeparator {
            separatorRow(line)
                .onAppear { separatorBecameVisible(line.id) }
        } else {
            Ansi.text(line.text, fontSize: fontSize, columns: terminalColumns)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
    }

    /// Full-width hairline with the disconnect time centered on it. The row has no
    /// horizontal padding, so the line meets both edges of the transcript.
    /// The stamp is formatted here, in the device's current zone, not from a server clock.
    private func separatorRow(_ line: LineDTO) -> some View {
        let stamp = line.disconnectAt.map { DisconnectSeparator.stamp(at: $0) } ?? line.text
        return HStack(spacing: 8) {
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

/// Both the initial placement and later content-size changes pin to the bottom.
/// Either one snaps a resume to the end before the ease can move, so both are off
/// for the whole pending reveal. On iOS 18 the modifiers stay in the tree and the
/// anchors become nil. On iOS 17 the single modifier is removed.
private struct TranscriptBottomAnchor: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            anchored(content)
        } else if enabled {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }

    @available(iOS 18.0, *)
    private func anchored(_ content: Content) -> some View {
        let anchor: UnitPoint? = enabled ? .bottom : nil
        return content
            .defaultScrollAnchor(anchor, for: .initialOffset)
            .defaultScrollAnchor(anchor, for: .sizeChanges)
    }
}
