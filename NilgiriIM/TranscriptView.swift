import SwiftUI
import UIKit

private let terminalColumns = 80
private let ink = Color(white: 0.78)
private let screen = Color.black
private let transcriptBottomID = "transcript-bottom"
/// Above this, the transcript stays lazy and the ease walks in short hops.
private let modestTranscriptCount = 600
/// Still at the bottom if the latest text is within this distance of the viewport.
private let nearBottomSlack: CGFloat = 80

/// One bottom snap per runloop turn. The flag lives on a class so arming it
/// does not publish another view update.
private final class BottomSnapGate {
    var queued = false
}

struct TranscriptView: View {
    @EnvironmentObject private var session: IMSession
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var commandFocused: Bool
    /// Programmatic scroll target. Nil leaves the scroll view alone.
    @State private var positionedID: String?
    /// Where `positionedID` sits in the visible region. Resume parks the separator
    /// on `.bottom`, just above the input bar; the ease to the latest line uses
    /// `.bottom` as well.
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
    /// Height of the name and HMV bar. Short logs stay below it, as they stay
    /// above the input bar.
    @State private var headerBarHeight: CGFloat = 0
    @State private var bottomSnapGate = BottomSnapGate()
    /// True when the latest text was at or near the bottom before the last size change.
    @State private var nearBottom = true
    /// Distance updates in this window are the layout catching up to a bottom snap,
    /// not the reader scrolling away.
    @State private var holdBottomUntil = Date.distantPast
    /// New lines arrived while the reader was up in the backlog.
    @State private var showNewLines = false
    /// Upward swipe on the input bar. One row of compass commands.
    @State private var actionPanelShown = false

    /// Count and the newest line, so a capped buffer and an insert both register
    /// without observing the whole transcript array.
    private var linesScrollSignal: String {
        "\(session.lines.count)#\(session.lines.last?.id ?? "")"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fontSize = max(8, (geo.size.width - 16) / CGFloat(terminalColumns) / 0.62)
                let transcriptHeight = max(0, geo.size.height - headerBarHeight - inputBarHeight)
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
                    .onChange(of: linesScrollSignal) { _, _ in
                        considerReveal(proxy, reason: "lines")
                    }
                    .onChange(of: session.pendingResumeReveal) { _, _ in
                        considerReveal(proxy, reason: "pending")
                    }
                    .onChange(of: scenePhase) { _, _ in
                        considerReveal(proxy, reason: "phase")
                    }
                    .onChange(of: geo.size) { _, newSize in
                        guard newSize.width > 1, newSize.height > 1 else { return }
                        reanchorAfterGeometryChange(proxy, wasNearBottom: nearBottom)
                    }
                    .onChange(of: geo.safeAreaInsets.bottom) { _, _ in
                        reanchorAfterGeometryChange(proxy, wasNearBottom: nearBottom)
                    }
                    .onChange(of: inputBarHeight) { _, newHeight in
                        guard newHeight > 1 else { return }
                        reanchorAfterGeometryChange(proxy, wasNearBottom: nearBottom)
                    }
                    .onChange(of: headerBarHeight) { _, newHeight in
                        guard newHeight > 1 else { return }
                        reanchorAfterGeometryChange(proxy, wasNearBottom: nearBottom)
                    }
                    .modifier(TranscriptResizeStick(
                        nearBottom: $nearBottom,
                        revealPending: session.pendingResumeReveal,
                        holdBottomUntil: holdBottomUntil,
                        reanchor: { reanchorAfterGeometryChange(proxy, wasNearBottom: true) }
                    ))
                    .onChange(of: nearBottom) { _, atBottom in
                        if atBottom {
                            showNewLines = false
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if showNewLines, nearBottom == false, session.pendingResumeReveal == false {
                            newLinesButton(proxy)
                                .padding(.bottom, 8)
                        }
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        topBar
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if session.atMenu {
                            GameMenuPanel()
                        } else {
                            inputBar
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if headerBarHeight > 1, session.atMenu == false {
                        unlinkButton
                            .padding(.top, headerBarHeight + 8)
                            .padding(.trailing, 12)
                    }
                }
            }
            .background(screen)
            .onPreferenceChange(InputBarHeightKey.self) { inputBarHeight = $0 }
            .onPreferenceChange(HeaderBarHeightKey.self) { headerBarHeight = $0 }
            .preferredColorScheme(.dark)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: scenePhase) { _, phase in
                Task {
                    if phase == .background {
                        await session.sceneWentBackground()
                    } else if phase == .active {
                        await session.sceneBecameActive()
                    }
                }
            }
            .onChange(of: session.atMenu) { _, atMenu in
                if atMenu {
                    commandFocused = false
                    actionPanelShown = false
                }
            }
            .task {
                await PushRegistration.request(session: session)
            }
        }
    }

    /// Character name with the latest prompt beside it: "Sin  30h 100m 97v".
    private var sessionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(session.character ?? "IM")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            if let label = session.vitals?.label {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Same frost as the input bar (`Chrome.barBackground`), extended
    /// into the top safe area the way the input bar extends into the bottom.
    private var topBar: some View {
        sessionHeader
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: HeaderBarHeightKey.self, value: proxy.size.height)
                }
            }
            .background(Chrome.barBackground, ignoresSafeAreaEdges: .top)
    }

    /// Floats just under the name bar, on the trailing side. Lighter than the
    /// bar so it does not read as part of that chrome.
    private var unlinkButton: some View {
        Button("Unlink") {
            Task { await session.logout(closeMud: true) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial.opacity(0.25), in: Capsule())
        .accessibilityLabel("Unlink")
    }

    private func sendCommand() async {
        await session.send()
        commandFocused = false
    }

    /// Same path as a typed command: `session.send()` posts `session.command`.
    /// A direction tap must not wipe text the reader is still composing.
    private func sendDirection(_ text: String) async {
        let draft = session.command
        session.command = text
        await session.send()
        if session.command.isEmpty {
            session.command = draft
        }
    }

    private func newLinesButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            showNewLines = false
            scrollToBottom(proxy)
        } label: {
            Text("↓ New lines")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Chrome.barBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New lines")
    }

    /// Sits in the scroll view's bottom safe area, so lines travel under the blur
    /// and the bottom anchor still rests above the bar. Half-strength frost lets
    /// the log show through; the prompt stays the light terminal ink on dark.
    /// An upward swipe opens one row of direction commands on that same frost.
    private var inputBar: some View {
        VStack(spacing: 0) {
            if actionPanelShown {
                ActionPanel { command in
                    Task { await sendDirection(command) }
                }
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
            }
            HStack {
                Text(">")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(ink)
                TextField("command", text: $session.command)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(ink)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($commandFocused)
                    .onSubmit { Task { await sendCommand() } }
                Button("Send") { Task { await sendCommand() } }
                    .foregroundStyle(ink)
            }
            .padding(12)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: InputBarHeightKey.self, value: proxy.size.height)
            }
        }
        .background(Chrome.barBackground, ignoresSafeAreaEdges: .bottom)
        .simultaneousGesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    let translation = value.translation
                    if translation.height < -30, abs(translation.height) > abs(translation.width) {
                        actionPanelShown.toggle()
                    } else if translation.height > abs(translation.width), translation.height > 0 {
                        commandFocused = false
                        actionPanelShown = false
                    }
                }
        )
    }

    /// Bottom snaps stay off for the whole time a resume reveal is pending, including
    /// before the scene is active. Appear still opens at the bottom. Later lines
    /// follow only while the reader is already there; a backlog stays put.
    private func considerReveal(_ proxy: ScrollViewProxy, reason: String) {
        guard session.pendingResumeReveal, let separatorID = session.resumeSeparatorID else {
            guard reason == "appear" || reason == "lines" else { return }
            if reason == "lines", nearBottom == false {
                showNewLines = true
                return
            }
            scrollToBottom(proxy)
            return
        }
        guard scenePhase == .active else { return }
        if runningSeparatorID == separatorID, revealStarted != nil {
            if reason == "lines" {
                bottomScrollDeferred = true
            }
            return
        }
        startReveal(proxy, separatorID: separatorID)
    }

    /// Jump to the separator only after the scene is active, then ease once a real
    /// layout pass has produced the row.
    private func startReveal(_ proxy: ScrollViewProxy, separatorID: String) {
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
        DispatchQueue.main.async {
            guard generation == self.revealGeneration else { return }
            self.jumpToSeparator(proxy, id: separatorID)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard generation == self.revealGeneration, self.easeStarted == false else { return }
            guard self.separatorVisibleID != separatorID else { return }
            self.jumpToSeparator(proxy, id: separatorID)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.maybeEase(generation: generation, separatorID: separatorID, reason: "0.4s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.maybeEase(generation: generation, separatorID: separatorID, reason: "fallback")
        }
    }

    /// Park the separator on the visible bottom, just above the input bar, then
    /// the ease walks to the latest line. The bar is a bottom safe-area inset of
    /// `inputBarHeight` (the viewport is `geo.size.height - inputBarHeight`), so
    /// `anchor: .bottom` is that edge rather than the top of the transcript.
    private func jumpToSeparator(_ proxy: ScrollViewProxy, id: String) {
        guard easeStarted == false else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            positionAnchor = .bottom
            positionedID = id
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    private func separatorBecameVisible(_ id: String) {
        guard session.pendingResumeReveal, id == session.resumeSeparatorID else { return }
        guard separatorVisibleID != id else { return }
        separatorVisibleID = id
        guard let separatorID = runningSeparatorID, revealStarted != nil else { return }
        maybeEase(generation: revealGeneration, separatorID: separatorID, reason: "separator onAppear")
    }

    /// Ease only after the separator row has appeared and at least 0.4s has passed
    /// since the reveal started. The 0.8s fallback eases even if the row never appeared.
    private func maybeEase(generation: Int, separatorID: String, reason: String) {
        guard generation == revealGeneration, easeStarted == false else { return }
        let elapsed = revealStarted.map { Date().timeIntervalSince($0) } ?? 0
        let visible = separatorVisibleID == separatorID
        let ready = elapsed >= 0.4 && (visible || reason == "fallback")
        guard ready else { return }
        easeToBottom(generation: generation, separatorID: separatorID)
    }

    private func easeToBottom(generation: Int, separatorID: String) {
        easeStarted = true
        let hops = easeHops(from: separatorID)
        let count = hops.count
        if count <= 1 {
            withAnimation(.easeInOut(duration: 1.0)) {
                positionAnchor = .bottom
                positionedID = transcriptBottomID
            }
            scheduleEaseFinish(generation: generation, separatorID: separatorID, after: 1.05)
            return
        }
        let slice = 1.0 / Double(count)
        for (index, hop) in hops.enumerated() {
            let delay = slice * Double(index)
            let anchor: UnitPoint = index == count - 1 ? .bottom : .top
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard generation == self.revealGeneration else { return }
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
        revealStarted = nil
        easeStarted = false
        runningSeparatorID = nil
        let deferred = bottomScrollDeferred
        bottomScrollDeferred = false
        // The ease ends on the latest line, so the next size change may stick.
        holdBottom()
        session.finishResumeReveal(separatorID: separatorID)
        if deferred {
            scrollToBottomNow()
        }
    }

    /// Orientation, keyboard, split view, and Stage Manager all change the
    /// container or the bottom inset before the text has reflowed. The scroll
    /// view would otherwise pin with the old insets and land mid-transcript
    /// or leave a gap under the last line. Wait until the next layout, then
    /// once more after a short delay, and let a newer change cancel the older
    /// one. A reconnect reveal owns the scroll until it finishes.
    private func reanchorAfterGeometryChange(_ proxy: ScrollViewProxy, wasNearBottom: Bool) {
        guard wasNearBottom else { return }
        guard session.pendingResumeReveal == false else { return }
        holdBottom()
        bottomScrollGeneration += 1
        let generation = bottomScrollGeneration
        let scroll = {
            guard generation == self.bottomScrollGeneration else { return }
            guard self.session.pendingResumeReveal == false else { return }
            self.scrollToBottomNow(proxy)
        }
        DispatchQueue.main.async(execute: scroll)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: scroll)
    }

    private func holdBottom() {
        nearBottom = true
        showNewLines = false
        holdBottomUntil = Date().addingTimeInterval(0.25)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if session.pendingResumeReveal {
            bottomScrollDeferred = true
            return
        }
        // Several line updates can land in one turn. One snap still lands on the bottom.
        guard bottomSnapGate.queued == false else { return }
        bottomSnapGate.queued = true
        bottomScrollGeneration += 1
        let generation = bottomScrollGeneration
        let scroll = {
            guard generation == self.bottomScrollGeneration else { return }
            guard self.session.pendingResumeReveal == false else { return }
            self.scrollToBottomNow(proxy)
        }
        DispatchQueue.main.async {
            self.bottomSnapGate.queued = false
            scroll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: scroll)
    }

    private func scrollToBottomNow(_ proxy: ScrollViewProxy) {
        holdBottom()
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
        holdBottom()
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

    @ViewBuilder
    private var bottomMarker: some View {
        let marker = Color.clear
            .frame(height: 1)
            .allowsHitTesting(false)
            .id(transcriptBottomID)
        if #available(iOS 18.0, *) {
            marker
        } else {
            marker
                .onAppear { holdBottom() }
                .onDisappear { noteLeftBottom() }
        }
    }

    /// iOS 17 has no scroll geometry. The bottom marker leaving the screen is
    /// the reader moving up, unless a size change already replaced that scroll.
    private func noteLeftBottom() {
        let generation = bottomScrollGeneration
        DispatchQueue.main.async {
            guard generation == self.bottomScrollGeneration else { return }
            guard self.session.pendingResumeReveal == false else { return }
            guard Date() >= self.holdBottomUntil else { return }
            self.nearBottom = false
        }
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

/// Welcome menu, in the input bar's place. Enter sends `1`. Quit sends `0`
/// and unlinks. Change password is a dialog, not menu choice `2`.
/// The frost is the same `Chrome.barBackground` as the bars and creation chrome.
private struct GameMenuPanel: View {
    @EnvironmentObject private var session: IMSession
    @State private var changingPassword = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordError: String?
    @State private var passwordBusy = false
    @FocusState private var passwordField: PasswordField?

    private enum PasswordField: Hashable {
        case current, new, confirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if changingPassword {
                passwordDialog
            } else {
                choices
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(ink)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: InputBarHeightKey.self, value: proxy.size.height)
            }
        }
        .background(Chrome.barBackground, ignoresSafeAreaEdges: .bottom)
        .toolbar {
            if changingPassword {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        passwordField = nil
                    }
                }
            }
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await session.chooseMenu("1") }
            } label: {
                HStack(spacing: 8) {
                    Text("Enter the game")
                    if session.menuBusy {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(white: 0.28))
            Button("Change password") {
                passwordError = nil
                changingPassword = true
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Quit") {
                Task { await session.chooseMenu("0") }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Quit")
        }
        .disabled(session.menuBusy)
    }

    /// Current, new, and confirm. The server sentence is shown unchanged.
    /// 400, 409, 502, and 504 are short messages from the session.
    private var passwordDialog: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change password")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            secureLine("Current password", text: $currentPassword, field: .current, contentType: .password) {
                passwordField = .new
            }
            secureLine("New password", text: $newPassword, field: .new, contentType: .newPassword) {
                passwordField = .confirm
            }
            secureLine("Confirm new password", text: $confirmPassword, field: .confirm, contentType: .newPassword) {
                Task { await submitPassword() }
            }
            if let passwordError, passwordError.isEmpty == false {
                Text(verbatim: passwordError)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Button("Cancel") {
                    closePasswordDialog()
                }
                .buttonStyle(.plain)
                Button {
                    Task { await submitPassword() }
                } label: {
                    HStack(spacing: 8) {
                        Text("Change")
                        if passwordBusy {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(white: 0.28))
                .disabled(passwordBusy || currentPassword.isEmpty || newPassword.isEmpty || confirmPassword.isEmpty)
            }
        }
    }

    private func secureLine(
        _ title: String,
        text: Binding<String>,
        field: PasswordField,
        contentType: UITextContentType,
        onSubmit: @escaping () -> Void
    ) -> some View {
        SecureField(title, text: text)
            .focused($passwordField, equals: field)
            .textContentType(contentType)
            .textFieldStyle(.plain)
            .privacySensitive()
            .padding(10)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .submitLabel(field == .confirm ? .done : .next)
            .onSubmit(onSubmit)
    }

    private func submitPassword() async {
        guard passwordBusy == false else { return }
        if currentPassword.isEmpty || newPassword.isEmpty {
            passwordError = "Enter the current and new password."
            return
        }
        if newPassword != confirmPassword {
            passwordError = "New passwords do not match."
            return
        }
        passwordBusy = true
        defer { passwordBusy = false }
        let current = currentPassword
        let proposed = newPassword
        if let message = await session.changePassword(current: current, new: proposed) {
            passwordError = message
            return
        }
        closePasswordDialog()
    }

    private func closePasswordDialog() {
        changingPassword = false
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
        passwordError = nil
        passwordField = nil
    }
}

/// One row of compass commands on the input bar's frost. Each tap posts the
/// full direction through `session.send()`, the same as typing it.
private struct ActionPanel: View {
    var send: (String) -> Void

    private struct Direction: Identifiable {
        let label: String
        let command: String
        var id: String { command }
    }

    private static let directions = [
        Direction(label: "N", command: "north"),
        Direction(label: "S", command: "south"),
        Direction(label: "E", command: "east"),
        Direction(label: "W", command: "west"),
        Direction(label: "U", command: "up"),
        Direction(label: "D", command: "down"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.directions) { direction in
                Button(direction.label) {
                    send(direction.command)
                }
                .buttonStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .accessibilityLabel(direction.command)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

private struct HeaderBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct InputBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Initial placement pins to the bottom. It is off for the whole pending reveal
/// so a resume does not snap to the end before the ease can move. On iOS 18 the
/// modifier stays in the tree and the anchor becomes nil. On iOS 17 it is removed.
/// Size changes are not pinned here: that anchor runs before the reflow and the
/// new insets exist, and it would also pull a reader who had scrolled up.
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
            .defaultScrollAnchor(nil, for: .sizeChanges)
    }
}

/// Container size and the bottom content inset, plus how far the viewport sits
/// above the end of the text. The inset is only a change signal. The correction
/// scroll runs later, against the settled layout, and never reuses this inset.
private struct TranscriptScrollSample: Equatable {
    var width: CGFloat
    var height: CGFloat
    var bottomInset: CGFloat
    var distanceFromBottom: CGFloat
    var contentHeight: CGFloat
    var visibleMinY: CGFloat
}

/// iOS 18: remember whether the reader was near the bottom, and re-anchor when
/// the scroll container or its bottom inset changes. iOS 17 uses the container
/// size and the bottom marker instead.
private struct TranscriptResizeStick: ViewModifier {
    @Binding var nearBottom: Bool
    var revealPending: Bool
    var holdBottomUntil: Date
    var reanchor: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: TranscriptScrollSample.self) { geo in
                TranscriptScrollSample(
                    width: geo.containerSize.width,
                    height: geo.containerSize.height,
                    bottomInset: geo.contentInsets.bottom,
                    distanceFromBottom: geo.contentSize.height - geo.visibleRect.maxY,
                    contentHeight: geo.contentSize.height,
                    visibleMinY: geo.visibleRect.minY
                )
            } action: { old, new in
                guard revealPending == false else { return }
                let containerChanged = abs(old.width - new.width) > 0.5
                    || abs(old.height - new.height) > 0.5
                    || abs(old.bottomInset - new.bottomInset) > 0.5
                if containerChanged {
                    let wasNear = old.distanceFromBottom <= nearBottomSlack || nearBottom
                    guard wasNear else { return }
                    nearBottom = true
                    reanchor()
                } else if Date() >= holdBottomUntil {
                    // A burst of lines grows the content under a reader who has
                    // not moved. That is still the bottom, so the next line can
                    // follow. A real scroll changes the visible origin.
                    let contentGrew = new.contentHeight > old.contentHeight + 0.5
                    let stayedPut = abs(new.visibleMinY - old.visibleMinY) < 1
                    let wasAtBottom = nearBottom || old.distanceFromBottom <= nearBottomSlack
                    if contentGrew, stayedPut, wasAtBottom {
                        nearBottom = true
                    } else {
                        nearBottom = new.distanceFromBottom <= nearBottomSlack
                    }
                }
            }
        } else {
            content
        }
    }
}
