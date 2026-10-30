import SwiftUI
import UIKit

private let terminalColumns = 80
private let ink = Color(white: 0.78)
private let screen = Color.black
/// Still at the bottom if the latest text is within this distance of the viewport.
private let nearBottomSlack: CGFloat = 80

private func transcriptFontSize(for width: CGFloat) -> CGFloat {
    max(8, (width - 16) / CGFloat(terminalColumns) / 0.62)
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

/// How to update the text view's storage. `replaceFrom` is the first character
/// that changed; everything before it is kept so an append does not replace
/// the whole log.
private struct TranscriptEdit {
    var replaceFrom: Int
    var text: NSAttributedString
}

/// One attributed transcript. A scroll frame that does not change the lines
/// or the font does not rebuild it. Appending lines keeps the prefix.
private final class TranscriptDocumentStore {
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

    func update(lines: [LineDTO], fontSize: CGFloat, carry: ColourCarryCache) -> TranscriptEdit? {
        carry.prepare(lines)
        if sameStorage(lines, held), abs(self.fontSize - fontSize) < 0.01 {
            return nil
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
                return nil
            }
        }
        let cut: Int
        if index == 0 || markers.isEmpty {
            cut = 0
        } else if index < markers.count {
            cut = markers[index].location
        } else {
            cut = working.length
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
        let text: NSAttributedString
        if cut <= 0 || cut >= working.length {
            text = cut <= 0 ? attributed : NSAttributedString()
        } else {
            text = working.attributedSubstring(from: NSRange(location: cut, length: working.length - cut))
        }
        return TranscriptEdit(replaceFrom: max(0, cut), text: text)
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

/// Rules beside a disconnect stamp. Drawn with the glyphs, so they scroll with
/// the text and are not a second SwiftUI layout pass.
private final class TranscriptLayoutManager: NSLayoutManager {
    var separatorRanges: [NSRange] = []
    private var drawingRules = false

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard drawingRules == false, separatorRanges.isEmpty == false else { return }
        guard let container = textContainers.first, container.size.width > 1 else { return }
        drawingRules = true
        defer { drawingRules = false }
        let width = container.size.width
        let path = UIBezierPath()
        for range in separatorRanges where range.length > 0 {
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }
            let rect = boundingRect(forGlyphRange: glyphs, in: container)
            guard rect.width > 0, rect.height > 0 else { continue }
            let y = origin.y + rect.midY
            let minX = origin.x + rect.minX
            let maxX = origin.x + rect.maxX
            let leftEnd = minX - 8
            if leftEnd > origin.x {
                path.move(to: CGPoint(x: origin.x, y: y))
                path.addLine(to: CGPoint(x: leftEnd, y: y))
            }
            let rightStart = maxX + 8
            let rightEnd = origin.x + width
            if rightEnd > rightStart {
                path.move(to: CGPoint(x: rightStart, y: y))
                path.addLine(to: CGPoint(x: rightEnd, y: y))
            }
        }
        guard path.isEmpty == false else { return }
        UIColor.secondaryLabel.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The transcript is this text view. It scrolls itself. A SwiftUI scroll view
/// around it was rewriting state on every frame.
private final class TranscriptTextView: UITextView {
    var onStructuralLayout: (() -> Void)?
    /// Height-only. The menu and the input bar change the slot; a keyboard
    /// frame must not publish SwiftUI state from here.
    var onViewportHeightChange: (() -> Void)?
    private var laidWidth: CGFloat = -1
    private var laidContentHeight: CGFloat = -1
    private var laidBoundsHeight: CGFloat = -1

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        let storage = NSTextStorage()
        let manager = TranscriptLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byClipping
        manager.addTextContainer(container)
        manager.allowsNonContiguousLayout = true
        super.init(frame: frame, textContainer: container)
        isEditable = false
        isSelectable = true
        isScrollEnabled = true
        alwaysBounceVertical = true
        isDirectionalLockEnabled = true
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        dataDetectorTypes = []
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = false
        // The column above the input bar already shortens when the keyboard
        // shows. Tracking the keyboard inset as well changes it every frame.
        contentInsetAdjustmentBehavior = .never
        automaticallyAdjustsScrollIndicatorInsets = false
        insetsLayoutMarginsFromSafeArea = false
        clipsToBounds = true
        tintColor = UIColor(white: 0.78, alpha: 1)
        overrideUserInterfaceStyle = .dark
        let link = UIColor(red: 0.55, green: 0.82, blue: 1, alpha: 1)
        linkTextAttributes = [
            .foregroundColor: link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: link
        ]
        textDragInteraction?.isEnabled = false
        // #74: the unwrapped line must not become this view's width.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    /// The slot that was offered. The text's own size is the unwrapped line.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        if size.width > 1, size.height > 1,
           size.width < .greatestFiniteMagnitude, size.height < .greatestFiniteMagnitude {
            return size
        }
        return bounds.size
    }

    var rules: TranscriptLayoutManager? {
        layoutManager as? TranscriptLayoutManager
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keyboard animation changes the height every frame. That is not a
        // reason to measure or publish. Width and the text's own height are.
        // A single settled height change (the menu taking the input bar's
        // place, or giving it back) is forwarded so the bottom can pin once.
        var structural = false
        let width = bounds.width
        let contentHeight = contentSize.height
        if width > 1, abs(width - laidWidth) >= 0.5 {
            laidWidth = width
            // #74: the container is the slot, not the unwrapped line.
            textContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            structural = true
        }
        if abs(contentHeight - laidContentHeight) >= 0.5 {
            laidContentHeight = contentHeight
            structural = true
        }
        let height = bounds.height
        let previousHeight = laidBoundsHeight
        let heightChanged = height > 1 && abs(height - previousHeight) >= 0.5
        if heightChanged {
            laidBoundsHeight = height
        }
        if structural {
            onStructuralLayout?()
        } else if heightChanged, previousHeight > 1 {
            onViewportHeightChange?()
        }
    }
}

/// SwiftUI sizes this host. The text view is pinned to its edges so a body
/// refresh does not rebuild the scroller or throw away `contentOffset`.
private final class TranscriptHost: UIView {
    let textView = TranscriptTextView(frame: .zero, textContainer: nil)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        // Yield to the menu and the input bar. Default resistance keeps
        // the fitting size, which was the slot above the shorter bar, so
        // the taller menu was drawn across the last lines.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    /// The slot that was offered. The previous column height is not an
    /// ideal size; reporting it keeps the menu from shortening the log.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width: CGFloat
        if size.width > 1, size.width < .greatestFiniteMagnitude {
            width = size.width
        } else {
            width = 0
        }
        if size.height > 1, size.height < .greatestFiniteMagnitude {
            return CGSize(width: width, height: size.height)
        }
        return CGSize(width: width, height: 0)
    }
}

private struct TranscriptLog: UIViewRepresentable {
    var lines: [LineDTO]
    var scrollToken: Int
    var revealPending: Bool
    var resumeSeparatorID: String?
    var onNearBottom: (Bool) -> Void
    var onRevealFinished: (String) -> Void

    func makeUIView(context: Context) -> TranscriptHost {
        let host = TranscriptHost(frame: .zero)
        let view = host.textView
        view.delegate = context.coordinator
        context.coordinator.textView = view
        view.onStructuralLayout = { [weak coordinator = context.coordinator] in
            coordinator?.noteLayout()
        }
        view.onViewportHeightChange = { [weak coordinator = context.coordinator] in
            coordinator?.viewportResized()
        }
        return host
    }

    /// Width and height are the slot SwiftUI offered. Measuring the text here
    /// is what made a scroll frame lay out every glyph. An unspecified height
    /// is not the current column: that size is the slot above the input bar,
    /// and reporting it lays the taller menu across the last lines.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: TranscriptHost,
        context: Context
    ) -> CGSize? {
        let width: CGFloat
        if let proposed = proposal.width, proposed > 1, proposed < .greatestFiniteMagnitude {
            width = proposed
        } else {
            width = 0
        }
        if let height = proposal.height, height > 1, height < .greatestFiniteMagnitude {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: width, height: 0)
    }

    func updateUIView(_ host: TranscriptHost, context: Context) {
        let textView = host.textView
        let coordinator = context.coordinator
        let offset = textView.contentOffset
        coordinator.textView = textView
        coordinator.onNearBottom = onNearBottom
        coordinator.onRevealFinished = onRevealFinished
        coordinator.revealPending = revealPending
        coordinator.resumeSeparatorID = resumeSeparatorID
        coordinator.lines = lines
        let requestedScroll = coordinator.scrollToken != scrollToken
        if requestedScroll {
            coordinator.scrollToken = scrollToken
            coordinator.nearBottom = true
            coordinator.stickToBottom = true
            coordinator.holdUntil = Date().addingTimeInterval(0.25)
            coordinator.scrollToBottom(animated: false)
        }
        coordinator.applyIfPossible()
        coordinator.syncReveal()
        if requestedScroll == false, coordinator.stickToBottom == false, coordinator.revealing == false {
            let deltaY = abs(textView.contentOffset.y - offset.y)
            let deltaX = abs(textView.contentOffset.x - offset.x)
            if deltaY > 1 || deltaX > 1 {
                textView.setContentOffset(offset, animated: false)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        weak var textView: TranscriptTextView?
        let store = TranscriptDocumentStore()
        let carry = ColourCarryCache()
        var lines: [LineDTO] = []
        var onNearBottom: (Bool) -> Void = { _ in }
        var onRevealFinished: (String) -> Void = { _ in }
        var revealPending = false
        var resumeSeparatorID: String?
        var nearBottom = true
        var stickToBottom = true
        var holdUntil = Date.distantPast
        var scrollToken = 0
        var programmatic = 0
        var applying = false
        var inLayout = false
        var revealing = false
        var startedRevealID: String?
        var finishedRevealID: String?
        var revealToken = 0
        var deferredBottom = false
        var publishGeneration = 0
        var stickQueued = false
        var lastOffsetY: CGFloat = 0
        /// While the keyboard frame is animating, height changes are not a
        /// second pin. The notification below scrolls once when it ends.
        private var keyboardAnimationUntil = Date.distantPast
        private var keyboardObserver: NSObjectProtocol?

        override init() {
            super.init()
            keyboardObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                self?.keyboardWillChange(note)
            }
        }

        deinit {
            if let keyboardObserver {
                NotificationCenter.default.removeObserver(keyboardObserver)
            }
        }

        /// One follow-up after the keyboard animation, not one per frame.
        /// The text view's height is the space above the input bar; the bar
        /// moves with the keyboard safe area, so the text view does not also
        /// track `contentInset` during the animation.
        private func keyboardWillChange(_ note: Notification) {
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            keyboardAnimationUntil = Date().addingTimeInterval(duration)
            guard stickToBottom, revealing == false, revealPending == false else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let coordinator = self else { return }
                guard coordinator.stickToBottom, coordinator.revealing == false,
                      coordinator.revealPending == false else { return }
                coordinator.scrollToBottom(animated: false)
            }
        }

        func noteLayout() {
            guard inLayout == false, applying == false else { return }
            inLayout = true
            defer { inLayout = false }
            applyIfPossible()
            syncReveal()
            stickIfNeeded()
        }

        /// The log's height changed because the menu or the input bar did.
        /// One pin, after this layout, and not once per keyboard frame.
        func viewportResized() {
            guard Date() >= keyboardAnimationUntil else { return }
            stickIfNeeded()
        }

        func applyIfPossible() {
            guard let textView, textView.bounds.width > 1 else { return }
            guard applying == false else { return }
            applying = true
            defer { applying = false }
            let font = transcriptFontSize(for: textView.bounds.width)
            guard let edit = store.update(lines: lines, fontSize: font, carry: carry) else { return }
            apply(edit, to: textView)
            if revealing {
                deferredBottom = true
            } else if revealPending == false, nearBottom {
                stickToBottom = true
                let follow = self
                DispatchQueue.main.async {
                    follow.scrollToBottom(animated: false)
                }
            }
        }

        func syncReveal() {
            guard revealPending, let id = resumeSeparatorID, id.isEmpty == false else { return }
            guard startedRevealID != id else { return }
            guard textView?.bounds.width ?? 0 > 1 else { return }
            startedRevealID = id
            beginReveal(id)
        }

        private func apply(_ edit: TranscriptEdit, to textView: TranscriptTextView) {
            let storage = textView.textStorage
            let previous = storage.string
            let selected = textView.selectedRange
            let cut = edit.replaceFrom
            storage.beginEditing()
            if cut <= 0 {
                storage.setAttributedString(edit.text)
            } else if cut > storage.length {
                storage.setAttributedString(store.attributed)
            } else {
                let tail = NSRange(location: cut, length: storage.length - cut)
                storage.replaceCharacters(in: tail, with: edit.text)
            }
            storage.endEditing()
            let keep: Int
            if cut > 0, cut <= (previous as NSString).length {
                keep = cut
            } else {
                keep = previous.commonPrefix(with: storage.string).utf16.count
            }
            if selected.length > 0,
               selected.location + selected.length <= keep,
               selected.location + selected.length <= storage.length {
                textView.selectedRange = selected
            }
            textView.rules?.separatorRanges = store.markers.compactMap { marker in
                guard marker.separator, marker.contentLength > 0 else { return nil }
                return NSRange(location: marker.location, length: marker.contentLength)
            }
            textView.setNeedsDisplay()
        }

        func scrollToBottom(animated: Bool) {
            guard let textView else { return }
            let y = maxOffset(of: textView)
            stickToBottom = true
            holdUntil = Date().addingTimeInterval(0.25)
            guard abs(textView.contentOffset.y - y) > 0.5 else { return }
            programmatic += 1
            if animated {
                UIView.animate(withDuration: 0.2, animations: {
                    textView.contentOffset = CGPoint(x: 0, y: y)
                }, completion: { _ in
                    self.programmatic = max(0, self.programmatic - 1)
                })
            } else {
                textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                programmatic = max(0, self.programmatic - 1)
            }
        }

        func stickIfNeeded() {
            guard stickToBottom, revealing == false, revealPending == false else { return }
            guard stickQueued == false else { return }
            guard let textView, textView.isDragging == false, textView.isDecelerating == false else { return }
            stickQueued = true
            DispatchQueue.main.async {
                self.stickQueued = false
                guard self.stickToBottom, self.revealing == false, self.revealPending == false else { return }
                guard let textView = self.textView,
                      textView.isDragging == false, textView.isDecelerating == false else { return }
                self.scrollToBottom(animated: false)
            }
        }

        private func beginReveal(_ id: String) {
            revealToken += 1
            let token = revealToken
            revealing = true
            deferredBottom = false
            finishedRevealID = nil
            DispatchQueue.main.async {
                guard token == self.revealToken else { return }
                self.jumpToSeparator(id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard token == self.revealToken, self.revealing else { return }
                self.jumpToSeparator(id)
                self.easeToBottom(token: token, id: id)
            }
        }

        private func jumpToSeparator(_ id: String) {
            guard let textView, let marker = store.markers.first(where: { $0.id == id && $0.separator }) else {
                return
            }
            guard let rect = rect(of: marker, in: textView), rect.height > 0 else { return }
            let visible = textView.bounds.height
                - textView.adjustedContentInset.top
                - textView.adjustedContentInset.bottom
            var y = rect.maxY - visible
            y = min(max(y, -textView.adjustedContentInset.top), maxOffset(of: textView))
            programmatic += 1
            textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            programmatic = max(0, self.programmatic - 1)
        }

        private func easeToBottom(token: Int, id: String) {
            guard let textView else {
                completeReveal(id)
                return
            }
            let y = maxOffset(of: textView)
            programmatic += 1
            UIView.animate(
                withDuration: 1.0,
                delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
            ) {
                textView.contentOffset = CGPoint(x: 0, y: y)
            } completion: { _ in
                self.programmatic = max(0, self.programmatic - 1)
                guard token == self.revealToken else { return }
                self.completeReveal(id)
            }
        }

        private func completeReveal(_ id: String?, pinBottom: Bool = true) {
            guard let id, finishedRevealID != id else {
                revealing = false
                return
            }
            finishedRevealID = id
            revealing = false
            let deferred = deferredBottom
            deferredBottom = false
            let callback = onRevealFinished
            DispatchQueue.main.async {
                callback(id)
            }
            guard pinBottom else { return }
            stickToBottom = true
            holdUntil = Date().addingTimeInterval(0.25)
            emitNear(true)
            if deferred {
                scrollToBottom(animated: false)
            }
        }

        private func rect(of marker: DocMarker, in textView: TranscriptTextView) -> CGRect? {
            let total = textView.textStorage.length
            guard marker.location < total else { return nil }
            let length = min(max(marker.contentLength, 1), total - marker.location)
            let characters = NSRange(location: marker.location, length: length)
            textView.layoutManager.ensureLayout(forCharacterRange: characters)
            let glyphs = textView.layoutManager.glyphRange(
                forCharacterRange: characters,
                actualCharacterRange: nil
            )
            guard glyphs.length > 0 else { return nil }
            var rect = textView.layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
            rect.origin.x += textView.textContainerInset.left
            rect.origin.y += textView.textContainerInset.top
            return rect
        }

        private func maxOffset(of textView: UITextView) -> CGFloat {
            let inset = textView.adjustedContentInset
            return max(-inset.top, textView.contentSize.height + inset.bottom - textView.bounds.height)
        }

        private func distanceFromBottom(of textView: UITextView) -> CGFloat {
            let inset = textView.adjustedContentInset
            let visibleMax = textView.contentOffset.y + textView.bounds.height - inset.bottom
            return textView.contentSize.height - visibleMax
        }

        private func emitNear(_ near: Bool) {
            guard near != nearBottom else { return }
            nearBottom = near
            stickToBottom = near
            publishGeneration += 1
            let generation = publishGeneration
            let callback = onNearBottom
            DispatchQueue.main.async {
                guard generation == self.publishGeneration else { return }
                callback(near)
            }
        }

        func scrollViewWillBeginDragging(_: UIScrollView) {
            holdUntil = .distantPast
            if revealing {
                revealToken += 1
                deferredBottom = false
                completeReveal(startedRevealID, pinBottom: false)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            let offsetY = textView.contentOffset.y
            let moved = abs(offsetY - lastOffsetY) > 0.5
            lastOffsetY = offsetY
            // Bounds and content-size changes call this too. Only a real offset
            // change is the reader moving; a keyboard frame must not flip the flag.
            guard programmatic == 0, moved else { return }
            let near: Bool
            if Date() < holdUntil {
                near = true
            } else {
                near = distanceFromBottom(of: textView) <= nearBottomSlack
            }
            emitNear(near)
        }

        func textView(
            _: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content else {
                return defaultAction
            }
            return UIAction(title: defaultAction.title) { _ in
                UIApplication.shared.open(url)
            }
        }

        func textView(
            _: UITextView,
            menuConfigurationFor _: UITextItem,
            defaultMenu: UIMenu
        ) -> UITextItem.MenuConfiguration? {
            UITextItem.MenuConfiguration(
                preview: UITextItem.MenuConfiguration.Preview.`default`,
                menu: defaultMenu
            )
        }
    }
}

struct TranscriptView: View {
    @EnvironmentObject private var session: IMSession
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var commandFocused: Bool
    /// True when the latest text is within `nearBottomSlack` of the viewport.
    /// Written only when that flips.
    @State private var nearBottom = true
    /// New lines arrived while the reader was up in the backlog.
    @State private var showNewLines = false
    /// Upward swipe on the input bar. One row of compass commands.
    @State private var actionPanelShown = false
    /// Bumps when "New lines" asks the text view to jump to the bottom.
    @State private var scrollToken = 0

    /// Count and the newest line, so a capped buffer and an insert both register
    /// without observing the whole transcript array.
    private var linesScrollSignal: String {
        "\(session.lines.count)#\(session.lines.last?.id ?? "")"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar
                ZStack(alignment: .bottom) {
                    TranscriptLog(
                        lines: session.lines,
                        scrollToken: scrollToken,
                        revealPending: session.pendingResumeReveal,
                        resumeSeparatorID: session.resumeSeparatorID,
                        onNearBottom: { near in
                            if nearBottom != near {
                                nearBottom = near
                            }
                        },
                        onRevealFinished: { id in
                            session.finishResumeReveal(separatorID: id)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showNewLines, nearBottom == false, session.pendingResumeReveal == false {
                        newLinesButton
                            .padding(.bottom, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if session.atMenu == false {
                        unlinkButton
                            .padding(.top, 8)
                            .padding(.trailing, 12)
                    }
                }
                // The menu is taller than the input bar. It stays under the
                // log in this column and keeps its own height, so the log
                // shortens instead of leaving the last lines under the buttons.
                Group {
                    if session.atMenu {
                        GameMenuPanel()
                    } else {
                        inputBar
                    }
                }
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(screen)
            .preferredColorScheme(.dark)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: linesScrollSignal) { _, _ in
                guard session.pendingResumeReveal == false, nearBottom == false else { return }
                showNewLines = true
            }
            .onChange(of: nearBottom) { _, atBottom in
                if atBottom {
                    showNewLines = false
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

    private var newLinesButton: some View {
        Button {
            showNewLines = false
            nearBottom = true
            scrollToken += 1
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

    /// Sits under the log, so lines stay above the blur and the keyboard lifts
    /// this bar with the safe area instead of resizing the text on every frame.
    /// Half-strength frost lets the log show through; the prompt stays the light
    /// terminal ink on dark. An upward swipe opens one row of direction commands.
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
                // Stock field. The UIKit subclass overrode textInputMode and
                // called becomeFirstResponder from updateUIView; the caret
                // blinked, but the keyboard session never attached. One line
                // tall, same as the Say/Send targets, so the bar does not
                // take the height proposed to this safe-area inset.
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
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.trailing, 16)
                commandIcon("bubble.left.fill", label: "Say") {
                    Task { await sendSay() }
                }
                commandIcon("paperplane.fill", label: "Send") {
                    Task { await sendCommand() }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
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
    @FocusState private var currentPasswordFocused: Bool
    @FocusState private var newPasswordFocused: Bool
    @FocusState private var confirmPasswordFocused: Bool

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
        .background(Chrome.barBackground, ignoresSafeAreaEdges: .bottom)
        .toolbar {
            if changingPassword {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        resignPasswordFocus()
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

    /// Current, new, and confirm. Each row reuses `RevealableSecureField`
    /// (eye / eye.slash). The server sentence is shown unchanged.
    /// 400, 409, 502, and 504 are short messages from the session.
    private var passwordDialog: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change password")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            secureLine(
                "Current password",
                text: $currentPassword,
                contentType: .password,
                submitLabel: .next,
                focus: $currentPasswordFocused
            ) {
                newPasswordFocused = true
            }
            secureLine(
                "New password",
                text: $newPassword,
                contentType: .newPassword,
                submitLabel: .next,
                focus: $newPasswordFocused
            ) {
                confirmPasswordFocused = true
            }
            secureLine(
                "Confirm new password",
                text: $confirmPassword,
                contentType: .newPassword,
                submitLabel: .done,
                focus: $confirmPasswordFocused
            ) {
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
        contentType: UITextContentType,
        submitLabel: SubmitLabel,
        focus: FocusState<Bool>.Binding,
        onSubmit: @escaping () -> Void
    ) -> some View {
        RevealableSecureField(
            title,
            text: text,
            textContentType: contentType,
            submitLabel: submitLabel,
            submitAction: onSubmit,
            focus: focus
        )
        .textFieldStyle(.plain)
        .padding(10)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func resignPasswordFocus() {
        currentPasswordFocused = false
        newPasswordFocused = false
        confirmPasswordFocused = false
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
        resignPasswordFocus()
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
