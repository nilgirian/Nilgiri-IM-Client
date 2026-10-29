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

/// SGR colour carried across transcript rows. Keyed by line id so a 4000-line
/// buffer is not reparsed on scroll: only a changed suffix is scanned, and a
/// separator passes the previous colour through. Surviving ids keep the end
/// state they were shown with, so trimming the cap does not recolour them.
private final class ColourCarryCache {
    private struct Entry {
        var id: String
        var signature: Int
        var start: Ansi.State
        var end: Ansi.State
    }

    private var entries: [Entry] = []
    private var startByID: [String: Ansi.State] = [:]
    /// Retained so this buffer's storage address cannot be reused until `lines`
    /// is replaced. A scroll frame then matches and does no work.
    private var held: [LineDTO] = []

    func prepare(_ lines: [LineDTO]) {
        if sameStorage(lines, held) { return }
        rebuild(lines)
        held = lines
    }

    func startState(for id: String) -> Ansi.State {
        startByID[id] ?? .initial
    }

    private func sameStorage(_ lhs: [LineDTO], _ rhs: [LineDTO]) -> Bool {
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                left.count == right.count && left.baseAddress == right.baseAddress
            }
        }
    }

    private func signature(_ line: LineDTO) -> Int {
        line.isSeparator ? 0 : line.text.hashValue
    }

    private func rebuild(_ lines: [LineDTO]) {
        let old = entries
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(old.count)
        for (offset, entry) in old.enumerated() {
            indexByID[entry.id] = offset
        }

        var result: [Entry] = []
        result.reserveCapacity(lines.count)
        var index = 0
        let prefix = min(old.count, lines.count)
        while index < prefix,
              old[index].id == lines[index].id,
              old[index].signature == signature(lines[index]) {
            result.append(old[index])
            index += 1
        }

        // A deleted prefix (the 4000-line cap) leaves a suffix whose ids are
        // already cached. Keep those end states; they already include the
        // colour of the lines that fell off.
        if index < lines.count,
           let pos = indexByID[lines[index].id], pos >= index,
           old[pos].signature == signature(lines[index]) {
            var oldCursor = pos
            while index < lines.count, oldCursor < old.count,
                  lines[index].id == old[oldCursor].id,
                  old[oldCursor].signature == signature(lines[index]) {
                result.append(old[oldCursor])
                oldCursor += 1
                index += 1
            }
        }

        var state = result.last?.end ?? Ansi.State.initial
        while index < lines.count {
            if let pos = indexByID[lines[index].id],
               old[pos].signature == signature(lines[index]),
               old[pos].start == state {
                var oldCursor = pos
                while index < lines.count, oldCursor < old.count,
                      lines[index].id == old[oldCursor].id,
                      old[oldCursor].signature == signature(lines[index]),
                      old[oldCursor].start == state {
                    result.append(old[oldCursor])
                    state = old[oldCursor].end
                    oldCursor += 1
                    index += 1
                }
                continue
            }
            let entry = makeEntry(lines[index], start: state)
            result.append(entry)
            state = entry.end
            index += 1
        }

        entries = result
        var starts: [String: Ansi.State] = [:]
        starts.reserveCapacity(result.count)
        for entry in result {
            starts[entry.id] = entry.start
        }
        startByID = starts
    }

    private func makeEntry(_ line: LineDTO, start: Ansi.State) -> Entry {
        if line.isSeparator {
            return Entry(id: line.id, signature: 0, start: start, end: start)
        }
        let end = Ansi.endingState(parsing: line.text, starting: start)
        return Entry(id: line.id, signature: line.text.hashValue, start: start, end: end)
    }
}

private struct DocMarker: Equatable {
    var id: String
    var location: Int
    var contentLength: Int
    var separator: Bool
}

/// Scroll target for one transcript row, in the text view's coordinates.
private struct LineAnchor: Identifiable, Equatable {
    var id: String
    var y: CGFloat
    var height: CGFloat
    var separatorMinX: CGFloat?
    var separatorWidth: CGFloat?
    var separatorMidY: CGFloat?
}

/// One attributed transcript. A scroll frame that does not change the lines
/// or the font does not rebuild it. Appending lines keeps the prefix.
private final class TranscriptDocumentStore {
    private(set) var generation = 0
    private(set) var attributed = NSAttributedString()
    private(set) var markers: [DocMarker] = []

    private var fontSize: CGFloat = -1
    private var ids: [String] = []
    private var sigs: [Int] = []
    private var working = NSMutableAttributedString()
    private var held: [LineDTO] = []
    private var needsJoiner = false
    private var lastWasSeparator = false

    private let mudParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 8
        style.headIndent = 8
        style.tailIndent = -8
        style.lineBreakMode = .byClipping
        style.alignment = .left
        return style
    }()

    private let separatorParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacingBefore = 8
        style.paragraphSpacing = 8
        style.lineBreakMode = .byClipping
        return style
    }()

    func update(lines: [LineDTO], fontSize: CGFloat, carry: ColourCarryCache) {
        carry.prepare(lines)
        if sameStorage(lines, held), abs(self.fontSize - fontSize) < 0.01 {
            return
        }
        let fontChanged = abs(self.fontSize - fontSize) >= 0.01
        let signatures = lines.map(signature)
        let lineIDs = lines.map(\.id)
        var index = 0
        if fontChanged == false {
            let prefix = min(ids.count, lines.count)
            while index < prefix, ids[index] == lineIDs[index], sigs[index] == signatures[index] {
                index += 1
            }
            if index == lines.count, index == ids.count {
                held = lines
                return
            }
        }
        rebuild(
            lines,
            from: index,
            fontSize: fontSize,
            carry: carry,
            signatures: signatures,
            lineIDs: lineIDs
        )
        held = lines
    }

    private func signature(_ line: LineDTO) -> Int {
        var hasher = Hasher()
        hasher.combine(line.isSeparator)
        hasher.combine(line.text)
        return hasher.finalize()
    }

    private func sameStorage(_ lhs: [LineDTO], _ rhs: [LineDTO]) -> Bool {
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                left.count == right.count && left.baseAddress == right.baseAddress
            }
        }
    }

    private func rebuild(
        _ lines: [LineDTO],
        from index: Int,
        fontSize: CGFloat,
        carry: ColourCarryCache,
        signatures: [Int],
        lineIDs: [String]
    ) {
        self.fontSize = fontSize
        if index == 0 {
            working = NSMutableAttributedString()
            markers = []
            ids = []
            sigs = []
            needsJoiner = false
            lastWasSeparator = false
        } else if index < markers.count {
            let cut = markers[index].location
            if cut < working.length {
                working.deleteCharacters(in: NSRange(location: cut, length: working.length - cut))
            }
            markers.removeSubrange(index...)
            ids.removeSubrange(index...)
            sigs.removeSubrange(index...)
            // The newline that ended the previous row is still in the buffer.
            needsJoiner = false
            lastWasSeparator = index > 0 && markers[index - 1].separator
        }
        if index < lines.count {
            for cursor in index..<lines.count {
                append(lines[cursor], fontSize: fontSize, carry: carry)
                ids.append(lineIDs[cursor])
                sigs.append(signatures[cursor])
            }
        }
        attributed = NSAttributedString(attributedString: working)
        generation &+= 1
    }

    private func append(_ line: LineDTO, fontSize: CGFloat, carry: ColourCarryCache) {
        if needsJoiner {
            working.append(joiner(separator: lastWasSeparator, fontSize: fontSize))
        }
        let start = working.length
        if line.isSeparator {
            let stamp = line.disconnectAt.map { DisconnectSeparator.stamp(at: $0) } ?? line.text
            working.append(NSAttributedString(string: stamp, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .caption1),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: separatorParagraph
            ]))
        } else {
            let piece = NSMutableAttributedString(attributedString: Ansi.attributed(
                line.text,
                fontSize: fontSize,
                columns: terminalColumns,
                initial: carry.startState(for: line.id)
            ))
            if piece.length > 0 {
                piece.addAttribute(
                    .paragraphStyle,
                    value: mudParagraph,
                    range: NSRange(location: 0, length: piece.length)
                )
            }
            working.append(piece)
        }
        markers.append(DocMarker(
            id: line.id,
            location: start,
            contentLength: working.length - start,
            separator: line.isSeparator
        ))
        lastWasSeparator = line.isSeparator
        needsJoiner = true
    }

    private func joiner(separator: Bool, fontSize: CGFloat) -> NSAttributedString {
        let font: UIFont = separator
            ? .preferredFont(forTextStyle: .caption1)
            : .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let color: UIColor = separator ? .secondaryLabel : UIColor(white: 0.78, alpha: 1)
        return NSAttributedString(string: "\n", attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: separator ? separatorParagraph : mudParagraph
        ])
    }
}

/// Read-only transcript. Scrolling belongs to the SwiftUI scroll view; a long
/// press selects across lines. The pan is off so a drag still scrolls.
private final class TranscriptTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byClipping
        manager.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        dataDetectorTypes = []
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        automaticallyAdjustsScrollIndicatorInsets = false
        insetsLayoutMarginsFromSafeArea = false
        clipsToBounds = false
        tintColor = UIColor(white: 0.78, alpha: 1)
        overrideUserInterfaceStyle = .dark
        let link = UIColor(red: 0.55, green: 0.82, blue: 1, alpha: 1)
        linkTextAttributes = [
            .foregroundColor: link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: link
        ]
        layoutManager.allowsNonContiguousLayout = false
        textDragInteraction?.isEnabled = false
        panGestureRecognizer.isEnabled = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if panGestureRecognizer.isEnabled {
            panGestureRecognizer.isEnabled = false
        }
    }
}

private struct TranscriptText: UIViewRepresentable {
    var attributed: NSAttributedString
    var generation: Int
    var width: CGFloat
    var markers: [DocMarker]
    var onMetrics: (CGFloat, [LineAnchor]) -> Void

    func makeUIView(context: Context) -> TranscriptTextView {
        let view = TranscriptTextView(frame: .zero, textContainer: nil)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ textView: TranscriptTextView, context: Context) {
        guard width > 1 else { return }
        let coordinator = context.coordinator
        let same = coordinator.generation == generation && abs(coordinator.width - width) < 0.5
        guard same == false else { return }
        textView.delegate = coordinator
        if coordinator.generation != generation {
            let previous = textView.attributedText?.string ?? ""
            let next = attributed.string
            let shared = previous.commonPrefix(with: next).utf16.count
            let range = textView.selectedRange
            textView.attributedText = attributed
            if range.length > 0, range.location + range.length <= shared {
                textView.selectedRange = range
            }
            coordinator.generation = generation
        }
        textView.isScrollEnabled = false
        textView.panGestureRecognizer.isEnabled = false
        coordinator.width = width
        let metrics = Self.measure(textView, markers: markers, width: width)
        let report = onMetrics
        DispatchQueue.main.async {
            report(metrics.height, metrics.anchors)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var generation = -1
        var width: CGFloat = -1

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            if interaction == .invokeDefaultAction {
                UIApplication.shared.open(URL)
                return false
            }
            return true
        }
    }

    private static func measure(
        _ textView: UITextView,
        markers: [DocMarker],
        width: CGFloat
    ) -> (height: CGFloat, anchors: [LineAnchor]) {
        let container = textView.textContainer
        container.widthTracksTextView = false
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let manager = textView.layoutManager
        manager.ensureLayout(for: container)
        let fit = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let height = max(fit.height, 1)
        let total = textView.attributedText?.length ?? 0
        var rects: [CGRect] = []
        rects.reserveCapacity(markers.count)
        for marker in markers {
            rects.append(rect(marker, total: total, manager: manager, container: container))
        }
        var anchors: [LineAnchor] = []
        anchors.reserveCapacity(markers.count)
        for index in markers.indices {
            let rect = rects[index]
            let nextY = index + 1 < rects.count ? rects[index + 1].minY : height
            let rowHeight = max(1, nextY - rect.minY)
            var anchor = LineAnchor(id: markers[index].id, y: rect.minY, height: rowHeight)
            if markers[index].separator, rect.width > 0, rect.height > 0 {
                anchor.separatorMinX = rect.minX
                anchor.separatorWidth = rect.width
                anchor.separatorMidY = rect.midY
            }
            anchors.append(anchor)
        }
        return (height, anchors)
    }

    private static func rect(
        _ marker: DocMarker,
        total: Int,
        manager: NSLayoutManager,
        container: NSTextContainer
    ) -> CGRect {
        guard marker.location < total else {
            return .zero
        }
        let length = min(max(marker.contentLength, 0), total - marker.location)
        guard length > 0 else {
            let glyphs = manager.glyphRange(
                forCharacterRange: NSRange(location: marker.location, length: 0),
                actualCharacterRange: nil
            )
            return manager.boundingRect(forGlyphRange: glyphs, in: container)
        }
        let glyphs = manager.glyphRange(
            forCharacterRange: NSRange(location: marker.location, length: length),
            actualCharacterRange: nil
        )
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
    }
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
    /// Colour entering each line. A class so scrolling does not copy it.
    @State private var colourCarry = ColourCarryCache()
    /// Attributed transcript shared by the selectable text view.
    @State private var documentStore = TranscriptDocumentStore()
    /// Laid-out height of that text, before the scroll view's minimum.
    @State private var transcriptContentHeight: CGFloat = 1
    /// One scroll target per row, measured from the text layout.
    @State private var lineAnchors: [LineAnchor] = []

    /// Count and the newest line, so a capped buffer and an insert both register
    /// without observing the whole transcript array.
    private var linesScrollSignal: String {
        "\(session.lines.count)#\(session.lines.last?.id ?? "")"
    }

    var body: some View {
        let _ = colourCarry.prepare(session.lines)
        NavigationStack {
            GeometryReader { geo in
                let fontSize = max(8, (geo.size.width - 16) / CGFloat(terminalColumns) / 0.62)
                let transcriptHeight = max(0, geo.size.height - headerBarHeight - inputBarHeight)
                ScrollViewReader { proxy in
                    ScrollView {
                        lineStack(fontSize: fontSize, width: geo.size.width)
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
                    .onChange(of: transcriptContentHeight) { _, _ in
                        guard nearBottom, session.pendingResumeReveal == false else { return }
                        scrollToBottom(proxy)
                    }
                    .onChange(of: lineAnchors.count) { _, _ in
                        guard session.pendingResumeReveal, easeStarted == false,
                              let separatorID = session.resumeSeparatorID else { return }
                        guard lineAnchors.contains(where: { $0.id == separatorID }) else { return }
                        separatorBecameVisible(separatorID)
                        jumpToSeparator(proxy, id: separatorID)
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

    /// Posts `say` plus the field. Text that already starts with `say` is sent
    /// as typed. `send()` clears the field before the request returns, and it
    /// reports failure only by changing `status`, so the draft comes back only then.
    private func sendSay() async {
        let draft = session.command
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        if alreadySay(trimmed) == false {
            session.command = "say " + trimmed
        }
        let statusBefore = session.status
        await session.send()
        guard session.command.isEmpty else { return }
        if session.status != statusBefore {
            session.command = draft
            return
        }
        commandFocused = false
    }

    private func alreadySay(_ text: String) -> Bool {
        let folded = text.lowercased()
        return folded == "say" || folded.hasPrefix("say ")
    }

    private var commandIsBlank: Bool {
        session.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            HStack(spacing: 0) {
                Text(">")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(ink)
                    .padding(.trailing, 8)
                TextField("command", text: $session.command)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(ink)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.send)
                    .focused($commandFocused)
                    .onSubmit { Task { await sendCommand() } }
                    .padding(.trailing, 16)
                commandIcon("bubble.left.fill", label: "Say") {
                    Task { await sendSay() }
                }
                commandIcon("arrow.up.circle.fill", label: "Send") {
                    Task { await sendCommand() }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
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

    private struct PlacedAnchor: Identifiable {
        var id: String
        var gap: CGFloat
        var height: CGFloat
        var separator: Bool
    }

    /// One text view so a selection can cross lines. Invisible rows keep the
    /// existing scroll-to-id reveal; they do not take touches.
    private func lineStack(fontSize: CGFloat, width: CGFloat) -> some View {
        documentStore.update(lines: session.lines, fontSize: fontSize, carry: colourCarry)
        let placed = placedAnchors
        let trailing = max(0, transcriptContentHeight - anchorCursor)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(placed) { anchor in
                    Color.clear
                        .frame(height: anchor.gap)
                    Color.clear
                        .frame(height: anchor.height)
                        .id(anchor.id)
                        .onAppear {
                            if anchor.separator {
                                separatorBecameVisible(anchor.id)
                            }
                        }
                }
                Color.clear.frame(height: trailing)
                bottomMarker
            }
            .scrollTargetLayout()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            TranscriptText(
                attributed: documentStore.attributed,
                generation: documentStore.generation,
                width: width,
                markers: documentStore.markers,
                onMetrics: { height, anchors in
                    if abs(transcriptContentHeight - height) > 0.5 {
                        transcriptContentHeight = height
                    }
                    if anchors != lineAnchors {
                        lineAnchors = anchors
                    }
                }
            )
            .frame(width: width, height: max(transcriptContentHeight, 1), alignment: .top)

            hairlines(width: width)
                .allowsHitTesting(false)

            if #available(iOS 18.0, *) {
                Color.clear.frame(width: 0, height: 0)
            } else {
                TranscriptOffsetSpy(
                    holdBottomUntil: holdBottomUntil,
                    revealPending: session.pendingResumeReveal,
                    onNearBottom: { near in
                        if nearBottom != near {
                            nearBottom = near
                        }
                    }
                )
                .frame(width: 0, height: 0)
            }
        }
    }

    private var placedAnchors: [PlacedAnchor] {
        var placed: [PlacedAnchor] = []
        var cursor: CGFloat = 0
        for anchor in lineAnchors {
            let gap = max(0, anchor.y - cursor)
            let height = max(anchor.height, 1)
            placed.append(PlacedAnchor(
                id: anchor.id,
                gap: gap,
                height: height,
                separator: anchor.separatorMinX != nil
            ))
            cursor = anchor.y + height
        }
        return placed
    }

    private var anchorCursor: CGFloat {
        guard let last = lineAnchors.last else { return 0 }
        return last.y + max(last.height, 1)
    }

    /// Hairlines beside the disconnect stamp. The stamp itself is in the text
    /// view, so a selection can pass through it and the copy includes it.
    private func hairlines(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(lineAnchors.filter { $0.separatorMinX != nil }) { anchor in
                if let minX = anchor.separatorMinX,
                   let stampWidth = anchor.separatorWidth,
                   let midY = anchor.separatorMidY {
                    let left = max(0, minX - 8)
                    let rightStart = minX + stampWidth + 8
                    let right = max(0, width - rightStart)
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.secondary)
                            .frame(width: left, height: 1)
                            .offset(y: midY)
                        Rectangle()
                            .fill(Color.secondary)
                            .frame(width: right, height: 1)
                            .offset(x: rightStart, y: midY)
                    }
                }
            }
        }
        .frame(width: width, height: max(transcriptContentHeight, 1), alignment: .topLeading)
        .accessibilityHidden(true)
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

    /// 44×44 hit target. The label is the accessibility name (Say or Send).
    private func commandIcon(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink)
        .disabled(commandIsBlank)
        .accessibilityLabel(label)
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
        Direction(label: "W", command: "west"),
        Direction(label: "E", command: "east"),
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

/// iOS 17 has no scroll geometry. Watches the enclosing scroll view so new
/// output still follows the bottom only while the reader is already there.
private struct TranscriptOffsetSpy: UIViewRepresentable {
    var holdBottomUntil: Date
    var revealPending: Bool
    var onNearBottom: (Bool) -> Void

    func makeUIView(context: Context) -> SpyView {
        let view = SpyView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: SpyView, context: Context) {
        view.holdBottomUntil = holdBottomUntil
        view.revealPending = revealPending
        view.onNearBottom = onNearBottom
    }

    final class SpyView: UIView {
        var holdBottomUntil = Date.distantPast
        var revealPending = false
        var onNearBottom: ((Bool) -> Void)?
        private var offsetObservation: NSKeyValueObservation?
        private var sizeObservation: NSKeyValueObservation?
        private var wasNear = true
        private var lastReported: Bool?
        private var lastOffset: CGFloat = 0
        private var lastContent: CGFloat = -1

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attach()
        }

        private func attach() {
            guard offsetObservation == nil, let scroll = enclosingScroll() else { return }
            offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                self?.report(scroll)
            }
            sizeObservation = scroll.observe(\.contentSize, options: [.new]) { [weak self] scroll, _ in
                self?.report(scroll)
            }
        }

        private func enclosingScroll() -> UIScrollView? {
            var view = superview
            while let current = view {
                if let scroll = current as? UIScrollView, (scroll is TranscriptTextView) == false {
                    return scroll
                }
                view = current.superview
            }
            return nil
        }

        private func report(_ scroll: UIScrollView) {
            guard revealPending == false else { return }
            let inset = scroll.adjustedContentInset
            let visibleMax = scroll.contentOffset.y + scroll.bounds.height - inset.bottom
            let distance = scroll.contentSize.height - visibleMax
            let grew = scroll.contentSize.height > lastContent + 0.5
            let stayed = abs(scroll.contentOffset.y - lastOffset) < 1
            lastOffset = scroll.contentOffset.y
            lastContent = scroll.contentSize.height
            let near: Bool
            if Date() < holdBottomUntil {
                near = true
            } else if grew, stayed, wasNear {
                near = true
            } else {
                near = distance <= nearBottomSlack
            }
            wasNear = near
            guard near != lastReported else { return }
            lastReported = near
            let callback = onNearBottom
            DispatchQueue.main.async {
                callback?(near)
            }
        }
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
