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

/// How many monospaced columns of `fontSize` fit the transcript slot.
/// The base font is chosen so this is 80. A larger face fits fewer, and the
/// paragraph clips, so the wrap has to come from this count.
private func transcriptColumns(forFontSize fontSize: CGFloat, width: CGFloat) -> Int {
    let usable = width - 16
    guard fontSize > 0, usable > 0 else { return terminalColumns }
    let columns = Int((usable / (fontSize * 0.62)).rounded(.down))
    return max(1, min(terminalColumns, columns))
}

/// Portrait when the window is taller than it is wide. A phone size class
/// is the fallback before that window has a size. The text view's height is
/// left out of this, because the keyboard shortens the log without a rotation.
private func transcriptIsPortrait(_ view: UIView) -> Bool {
    if let window = view.window, window.bounds.width > 1, window.bounds.height > 1 {
        return window.bounds.height >= window.bounds.width
    }
    let traits = view.traitCollection
    if traits.verticalSizeClass == .compact {
        return false
    }
    if traits.horizontalSizeClass == .compact, traits.verticalSizeClass == .regular {
        return true
    }
    return UIScreen.main.bounds.height >= UIScreen.main.bounds.width
}

/// Channel speech. The client does not paint channels itself; it shows the
/// MUD's ANSI. A line is communication when its `kind` already names a
/// channel, or when the visible sentence is one of those channel lines.
/// The test reads a copy with ANSI removed. The stored line is not edited.
private enum CommunicationLine {
    static let portraitBoost: CGFloat = 4

    private static let kinds: Set<String> = [
        "say", "says",
        "ask", "asks",
        "exclaim", "exclaims",
        "question", "questions",
        "gossip", "gossips",
        "wizard", "wiz", "wiznet", "wizards", "wiznets",
        "shout", "shouts",
        "tell", "tells",
        "whisper", "whispers",
        "yell", "yells",
        "murmur", "murmurs",
        "pray", "prays"
    ]

    /// `You say, "hi"` / `You exclaim, 'Level!'` / `You tell Bob, "hi"`.
    /// `Sin gossips, "hi"` / `The bartender says, "hi"` / `Sin tells you, "hi"`.
    /// `Sin whispers to you, "hi"` / `You question, "hi"` / `You wizard, "hi"`.
    /// The quote closes the line, so a room sentence that only mentions speech
    /// stays at the normal size.
    private static let expression: NSRegularExpression = {
        let simple = "says?|asks?|exclaims?|questions?|gossips?|shouts?|yells?|whispers?|murmurs?|prays?|wiz(?:ards?|nets?)?"
        let speaker = "[A-Z][A-Za-z0-9'._-]{0,40}(?: [A-Za-z0-9'._-]{1,40}){0,5}"
        let directed = "whispers? to [^,'\"]+|tells? [^,'\"]+"
        let pattern = "^" + speaker + " (?:(?:" + directed + ")|(?:" + simple + ")), [\"'][\\s\\S]*[\"']\\s*$"
        return try! NSRegularExpression(pattern: pattern)
    }()

    static func isCommunication(_ line: LineDTO) -> Bool {
        if line.isSeparator { return false }
        let kind = line.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if kinds.contains(kind) { return true }
        return matches(line.text)
    }

    private static func matches(_ raw: String) -> Bool {
        let visible = strippingCSI(raw)
        guard visible.isEmpty == false else { return false }
        let range = NSRange(visible.startIndex..., in: visible)
        return expression.firstMatch(in: visible, options: [], range: range) != nil
    }

    private static func strippingCSI(_ raw: String) -> String {
        var out = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "\u{001B}" {
                let bracket = raw.index(after: index)
                if bracket < raw.endIndex, raw[bracket] == "[" {
                    var cursor = raw.index(after: bracket)
                    while cursor < raw.endIndex {
                        let character = raw[cursor]
                        cursor = raw.index(after: cursor)
                        if (character >= "A" && character <= "Z") || (character >= "a" && character <= "z") {
                            break
                        }
                    }
                    index = cursor
                    continue
                }
            }
            out.append(raw[index])
            index = raw.index(after: index)
        }
        return out
    }
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

/// One attributed transcript. A scroll frame that does not change the lines,
/// the font, or portrait-vs-landscape does not rebuild it. Appending lines
/// keeps the prefix. A portrait flip restyles the whole log once.
private final class TranscriptDocumentStore {
    private(set) var attributed = NSAttributedString()
    private(set) var markers: [DocMarker] = []

    private var fontSize: CGFloat = -1
    private var enlargeCommunication = false
    /// Columns used when a portrait communication line is drawn larger.
    /// Normal lines stay at 80. A scroll frame does not change this.
    private var communicationColumns = terminalColumns
    private var slotWidth: CGFloat = 0
    private var ids: [String] = []
    private var sigs: [Int] = []
    private var working = NSMutableAttributedString()
    private var held: [LineDTO] = []
    private var needsJoiner = false
    private var lastWasSeparator = false
    /// Font size of the mud line the next newline closes. A portrait
    /// communication line keeps that larger size on its break.
    private var lastMudFontSize: CGFloat = 0

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

    func update(
        lines: [LineDTO],
        fontSize: CGFloat,
        width: CGFloat,
        enlargeCommunication: Bool,
        carry: ColourCarryCache
    ) -> TranscriptEdit? {
        carry.prepare(lines)
        let columns = enlargeCommunication
            ? transcriptColumns(forFontSize: fontSize + CommunicationLine.portraitBoost, width: width)
            : terminalColumns
        if sameStorage(lines, held),
           abs(self.fontSize - fontSize) < 0.01,
           self.enlargeCommunication == enlargeCommunication,
           self.communicationColumns == columns {
            return nil
        }
        let styleChanged = abs(self.fontSize - fontSize) >= 0.01
            || self.enlargeCommunication != enlargeCommunication
            || self.communicationColumns != columns
        let signatures = lines.map(signature)
        let lineIDs = lines.map(\.id)
        var index = 0
        if styleChanged == false {
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
            width: width,
            communicationColumns: columns,
            enlargeCommunication: enlargeCommunication,
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
        width: CGFloat,
        communicationColumns: Int,
        enlargeCommunication: Bool,
        carry: ColourCarryCache,
        signatures: [Int],
        lineIDs: [String]
    ) {
        self.fontSize = fontSize
        self.slotWidth = width
        self.communicationColumns = communicationColumns
        self.enlargeCommunication = enlargeCommunication
        if index == 0 {
            working = NSMutableAttributedString()
            markers = []
            ids = []
            sigs = []
            needsJoiner = false
            lastWasSeparator = false
            lastMudFontSize = fontSize
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
            working.append(joiner(separator: lastWasSeparator, fontSize: lastMudFontSize))
        }
        let start = working.length
        if line.isSeparator {
            let stamp = line.disconnectAt.map { DisconnectSeparator.stamp(at: $0) } ?? line.text
            working.append(NSAttributedString(string: stamp, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .caption1),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: separatorParagraph
            ]))
            lastMudFontSize = fontSize
        } else {
            let size = displayFontSize(line, base: fontSize)
            lastMudFontSize = size
            // Portrait draws these larger, so the wrap is short of 80. Landscape
            // keeps this face and the 80-column measure. Channel lines use the
            // same rule in both: a word under 13 letters moves whole, and later
            // lines indent two spaces. Other lines keep the column break.
            let wrap: Ansi.Wrap = CommunicationLine.isCommunication(line)
                ? .communication
                : .columns
            let piece = NSMutableAttributedString(attributedString: Ansi.attributed(
                line.text,
                fontSize: size,
                columns: columns(forDisplaySize: size, base: fontSize),
                initial: carry.startState(for: line.id),
                wrap: wrap
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

    /// Portrait communication is four points above the normal transcript size.
    /// Landscape passes the normal size through. Characters, colours, and
    /// links come from `Ansi` unchanged.
    private func displayFontSize(_ line: LineDTO, base: CGFloat) -> CGFloat {
        guard enlargeCommunication, CommunicationLine.isCommunication(line) else { return base }
        return base + CommunicationLine.portraitBoost
    }

    /// Normal lines stay on the 80-column wrap. A larger portrait line wraps
    /// at the fewer columns that fit the same slot, still as display breaks
    /// only. The stored MUD text is not edited.
    private func columns(forDisplaySize size: CGFloat, base: CGFloat) -> Int {
        guard size > base + 0.01 else { return terminalColumns }
        if communicationColumns > 0 {
            return communicationColumns
        }
        return transcriptColumns(forFontSize: size, width: slotWidth)
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

/// A word in the display string. The stored line is not edited: these are
/// characters already drawn. Edge punctuation is not part of the word,
/// so "guard," and "2.guard" hilite `guard` and `2.guard`.
private enum TranscriptWord {
    struct Hit: Equatable {
        var range: NSRange
        var word: String
    }

    private static let trimSet = CharacterSet.punctuationCharacters.union(.symbols)
    private static let coreSet = CharacterSet.alphanumerics

    /// The word under `viewPoint`, or nil when the tap is on a gap or padding.
    static func hit(in textView: UITextView, at viewPoint: CGPoint) -> Hit? {
        guard let index = characterIndex(in: textView, at: viewPoint) else { return nil }
        return span(in: textView.textStorage.string as NSString, at: index)
    }

    /// Link under `viewPoint`, or nil on a gap or on text that is not a link.
    static func link(in textView: UITextView, at viewPoint: CGPoint) -> URL? {
        guard let index = characterIndex(in: textView, at: viewPoint) else { return nil }
        let value = textView.textStorage.attribute(.link, at: index, effectiveRange: nil)
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    /// Character under `viewPoint`, or nil when the tap misses the glyph.
    /// UITextView has no textContainerOrigin (that is AppKit). The container
    /// sits at the inset; line fragment padding on this view is zero.
    private static func characterIndex(in textView: UITextView, at viewPoint: CGPoint) -> Int? {
        let storage = textView.textStorage
        guard storage.length > 0 else { return nil }
        let layout = textView.layoutManager
        guard layout.numberOfGlyphs > 0 else { return nil }
        let origin = CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
        let point = CGPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
        let glyph = layout.glyphIndex(
            for: point,
            in: textView.textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyph < layout.numberOfGlyphs else { return nil }
        let charIndex = layout.characterIndexForGlyph(at: glyph)
        guard charIndex < storage.length else { return nil }
        layout.ensureLayout(forGlyphRange: NSRange(location: glyph, length: 1))
        var glyphRect = layout.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textView.textContainer
        )
        glyphRect.origin.x += origin.x
        glyphRect.origin.y += origin.y
        let slop = glyphRect.insetBy(dx: -2, dy: -3)
        guard slop.isNull == false, slop.contains(viewPoint) else { return nil }
        return charIndex
    }

    /// `word` inside `text`, preferring the occurrence nearest `offset`.
    /// A hit inside a longer token does not count.
    static func find(_ word: String, in text: NSString, near offset: Int) -> NSRange? {
        guard word.isEmpty == false, text.length > 0 else { return nil }
        var search = 0
        var best: NSRange?
        var bestDistance = Int.max
        while search < text.length {
            let found = text.range(
                of: word,
                options: [],
                range: NSRange(location: search, length: text.length - search)
            )
            if found.location == NSNotFound { break }
            if let hit = span(in: text, at: found.location),
               hit.word == word,
               NSEqualRanges(hit.range, found) {
                let distance = abs(found.location - offset)
                if distance < bestDistance {
                    bestDistance = distance
                    best = found
                }
            }
            let next = found.location + max(found.length, 1)
            if next <= search { break }
            search = next
        }
        return best
    }

    /// Whitespace-delimited token at `index`, with punctuation peeled off the ends.
    private static func span(in text: NSString, at index: Int) -> Hit? {
        guard index >= 0, index < text.length else { return nil }
        if isBreak(text.character(at: index)) { return nil }
        var start = index
        var end = index + 1
        while start > 0, isBreak(text.character(at: start - 1)) == false {
            start -= 1
        }
        while end < text.length, isBreak(text.character(at: end)) == false {
            end += 1
        }
        while start < end, isTrimmed(text.character(at: start)) {
            start += 1
        }
        while end > start, isTrimmed(text.character(at: end - 1)) {
            end -= 1
        }
        guard start < end else { return nil }
        let range = NSRange(location: start, length: end - start)
        let word = text.substring(with: range)
        guard word.unicodeScalars.contains(where: { coreSet.contains($0) }) else { return nil }
        return Hit(range: range, word: word)
    }

    private static func isBreak(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isTrimmed(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return trimSet.contains(scalar)
    }
}

/// One open per tap. The system link action and the hilite tap can both see
/// the same URL when the command field keeps first responder.
private enum TranscriptLinkOpener {
    private static var lastURL: URL?
    private static var lastTime: TimeInterval = -.greatestFiniteMagnitude

    static func open(_ url: URL) {
        let now = CACurrentMediaTime()
        if lastURL == url, now - lastTime < 0.8 { return }
        lastURL = url
        lastTime = now
        UIApplication.shared.open(url)
    }
}

/// Rules beside a disconnect stamp. Drawn with the glyphs, so they scroll with
/// the text and are not a second SwiftUI layout pass.
/// The word hilite is the same kind of overlay: paint behind the glyphs, and
/// leave the attributed line alone.
private final class TranscriptLayoutManager: NSLayoutManager {
    var separatorRanges: [NSRange] = []
    private(set) var hiliteRange: NSRange?
    private var drawingRules = false
    private static let hiliteFill = UIColor(red: 0.98, green: 0.80, blue: 0.22, alpha: 0.45)

    func setHilite(_ range: NSRange?) {
        let next = range.flatMap { $0.length > 0 ? $0 : nil }
        if let hiliteRange, let next, NSEqualRanges(hiliteRange, next) { return }
        if hiliteRange == nil, next == nil { return }
        let previous = hiliteRange
        hiliteRange = next
        if let previous, previous.length > 0 {
            invalidateDisplay(forCharacterRange: previous)
        }
        if let next {
            invalidateDisplay(forCharacterRange: next)
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let range = hiliteRange, range.length > 0,
              let storage = textStorage, NSMaxRange(range) <= storage.length,
              let container = textContainers.first else { return }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let overlap = NSIntersectionRange(glyphs, glyphsToShow)
        guard overlap.length > 0 else { return }
        Self.hiliteFill.setFill()
        enumerateEnclosingRects(
            forGlyphRange: overlap,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: container
        ) { rect, _ in
            let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: 0.5)
            guard box.isNull == false, box.width > 0.5, box.height > 0.5 else { return }
            UIBezierPath(roundedRect: box, cornerRadius: 2).fill()
        }
    }

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
    /// Height-only. Rotation, split view, and the keyboard change the slot.
    /// The menu does not: its clearance is the bottom content inset. A keyboard
    /// frame must not publish SwiftUI state from here.
    var onViewportHeightChange: (() -> Void)?
    /// Width is about to change. Rotation reports that as a scroll; the pin
    /// has to be held before `super` so the scroll does not drop it.
    var onWidthWillChange: (() -> Void)?
    /// Recompute bar insets after a real size change. Must not publish SwiftUI state.
    var onChromeLayout: (() -> Void)?
    /// The live bottom inset was cleared and written back. Pin if still stuck.
    var onChromeRepaired: (() -> Void)?
    /// A layout finished. Pin again when the reader is holding the bottom,
    /// after glyphs and insets are settled.
    var onPinnedLayout: (() -> Void)?
    /// Clearance for the name bar and the command bar or menu. Enforced after
    /// every layout so a scroll-view pass cannot leave the bottom at zero.
    var chromeInsets: UIEdgeInsets = .zero
    private var enforcingChrome = false
    private var settlingHeight = false
    private var laidWidth: CGFloat = -1
    private var laidContentHeight: CGFloat = -1
    private var laidBoundsHeight: CGFloat = -1
    /// The log on screen. The command field asks it whether a selection
    /// press is taking focus.
    private static weak var installed: TranscriptTextView?
    /// `CACurrentMediaTime` when the finger went down. Compared only with
    /// itself, never with `UITouch.timestamp`.
    private var fingerDownAt: TimeInterval?
    private var fingerIsDown = false

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
        isOpaque = false
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        dataDetectorTypes = []
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = false
        // The keyboard layout guide is not used here. Attaching it makes this
        // scroll view track keyboard insets and, with the keyboard hidden,
        // writes a bottom content inset of zero over the command-bar clearance.
        // Automatic adjustment would add the safe area on top of the inset the
        // coordinator already includes when this view extends into it.
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
        _ = registerForTraitChanges([
            UITraitHorizontalSizeClass.self,
            UITraitVerticalSizeClass.self
        ]) { (view: Self, _: UITraitCollection) in
            // One call when the size class flips, not once per animation frame.
            view.onStructuralLayout?()
        }
        // #74: the unwrapped line must not become this view's width.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            Self.installed = self
        } else if Self.installed === self {
            Self.installed = nil
        }
        guard window != nil else { return }
        onChromeLayout?()
    }

    /// A tap must not take first responder while the command field is up and
    /// this orientation leaves the keyboard up. Handing first responder to a
    /// non-editable text view removes the keyboard with no slide. A long
    /// press still falls through, and so does hide-on.
    override func becomeFirstResponder() -> Bool {
        if keepsCommandFieldForQuickTap() {
            return false
        }
        return super.becomeFirstResponder()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        noteFingerDown()
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        noteFingerUp()
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        noteFingerUp()
        super.touchesCancelled(touches, with: event)
    }

    /// Hide is off, and this touch is not a selection press. The command
    /// field should stay first responder. A plain tap does not have to be
    /// classified first: the previous guard missed the resign when that
    /// classification was false.
    static func logTapShouldKeepCommandField() -> Bool {
        guard KeyboardHidePreferences.hidesKeyboardForCurrentInterface() == false else { return false }
        if installed?.selectionPressIsTakingFocus() == true {
            return false
        }
        return true
    }

    /// The command field is still up, so a link under a tap is opened here.
    /// Refusing first responder can skip the system's link action.
    func keepsCommandFieldForQuickTap() -> Bool {
        guard Self.logTapShouldKeepCommandField() else { return false }
        guard let window else { return false }
        return Self.commandFieldIsFirstResponder(in: window)
    }

    func noteFingerDown() {
        if window != nil {
            Self.installed = self
        }
        if fingerIsDown == false {
            fingerDownAt = CACurrentMediaTime()
            fingerIsDown = true
        }
    }

    private func noteFingerUp() {
        fingerIsDown = false
        fingerDownAt = nil
    }

    /// The selection long press has begun, or the finger has been down long
    /// enough that it is about to. A short tap stays false.
    func selectionPressIsTakingFocus() -> Bool {
        let now = CACurrentMediaTime()
        var sawLongPress = false
        for case let press as UILongPressGestureRecognizer in gestureRecognizers ?? [] {
            sawLongPress = true
            switch press.state {
            case .began, .changed:
                return true
            case .possible:
                let threshold = max(0.2, press.minimumPressDuration - 0.02)
                if fingerIsDown, let down = fingerDownAt, now - down >= threshold {
                    return true
                }
            default:
                break
            }
        }
        if sawLongPress == false, fingerIsDown, let down = fingerDownAt, now - down >= 0.45 {
            return true
        }
        return false
    }

    private static func commandFieldIsFirstResponder(in root: UIView) -> Bool {
        var stack = [root]
        while let view = stack.popLast() {
            if let field = view as? CommandTextField, field.isFirstResponder {
                return true
            }
            stack.append(contentsOf: view.subviews)
        }
        return false
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

    /// TextKit 1 lays glyphs out on demand (`allowsNonContiguousLayout`).
    /// `contentSize` is then only the estimate, short of a wrapped +6pt line,
    /// and the next row (the disconnect stamp) is placed on top of that line.
    /// Returns the height after the whole storage has actually been laid out.
    func settledContentHeight() -> CGFloat {
        if settlingHeight {
            return contentSize.height
        }
        settlingHeight = true
        defer { settlingHeight = false }
        let length = textStorage.length
        if length > 0 {
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let laid = ceil(used.height + textContainerInset.top + textContainerInset.bottom)
        if laid > contentSize.height + 0.5 {
            contentSize = CGSize(width: max(contentSize.width, bounds.width), height: laid)
        }
        return max(contentSize.height, laid)
    }

    /// Put `chromeInsets` back if layout cleared them. Returns whether it wrote.
    @discardableResult
    func enforceChromeInsets() -> Bool {
        guard enforcingChrome == false else { return false }
        let desired = chromeInsets
        guard verticalInsetsDiffer(contentInset, desired)
            || verticalInsetsDiffer(verticalScrollIndicatorInsets, desired) else {
            return false
        }
        enforcingChrome = true
        contentInset = desired
        verticalScrollIndicatorInsets = desired
        enforcingChrome = false
        return verticalInsetsDiffer(contentInset, desired) == false
    }

    override func layoutSubviews() {
        if window != nil {
            Self.installed = self
        }
        let width = bounds.width
        if width > 1, laidWidth > 1, abs(width - laidWidth) >= 0.5 {
            onWidthWillChange?()
        }
        super.layoutSubviews()
        let repaired = enforceChromeInsets()
        // Keyboard animation changes the height every frame. That is not a
        // reason to measure or publish. Width and the text's own height are.
        // A settled height change still pins the bottom once. The menu does
        // not change this height; the bottom inset clears it.
        var structural = false
        var boundsChanged = false
        let contentHeight = contentSize.height
        if width > 1, abs(width - laidWidth) >= 0.5 {
            laidWidth = width
            // #74: the container is the slot, not the unwrapped line.
            textContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            structural = true
            boundsChanged = true
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
            boundsChanged = true
        }
        // Scroll frames keep the same bounds. Insets are not rewritten then,
        // except to put back a bottom clearance that layout just cleared.
        if boundsChanged {
            onChromeLayout?()
        } else if repaired {
            onChromeRepaired?()
        }
        if structural {
            onStructuralLayout?()
        } else if heightChanged, previousHeight > 1 {
            onViewportHeightChange?()
        }
        if boundsChanged || repaired || structural {
            onPinnedLayout?()
        }
    }

    private func verticalInsetsDiffer(_ lhs: UIEdgeInsets, _ rhs: UIEdgeInsets) -> Bool {
        abs(lhs.top - rhs.top) >= 0.5 || abs(lhs.bottom - rhs.bottom) >= 0.5
    }
}

/// SwiftUI sizes this host. The text view is pinned to its edges so a body
/// refresh does not rebuild the scroller or throw away `contentOffset`.
private final class TranscriptHost: UIView {
    let textView = TranscriptTextView(frame: .zero, textContainer: nil)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        // Fill the slot behind the bars. Reporting a previous, shorter column
        // would open a gap above the menu; the last lines clear it by inset.
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

    /// The slot behind the bars. A shorter ideal height would leave a gap
    /// above the menu; the bottom content inset clears the last lines.
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
    /// Name bar height. Fallback top inset until the bar's frame is known.
    var topBarHeight: CGFloat
    /// Command bar or encamp-menu height. Fallback bottom inset.
    var bottomBarHeight: CGFloat
    /// Distance from the column top to the bottom of the name bar.
    var topClearance: CGFloat
    /// Distance from the top of the command bar or menu to the column bottom.
    var bottomClearance: CGFloat
    /// Height of the column the bars are measured in.
    var columnHeight: CGFloat
    var revealPending: Bool
    var resumeSeparatorID: String?
    /// White launch cover. While it is up the log is not hit-testable, so a
    /// scroll under it is layout, and the bottom pin is put back when it ends.
    var launchSplashVisible: Bool
    var onNearBottom: (Bool) -> Void
    var onRevealFinished: (String) -> Void
    /// Hilited word, or nil when the hilite clears. The line text is not edited.
    var onHilitedWord: (String?) -> Void

    func makeUIView(context: Context) -> TranscriptHost {
        let host = TranscriptHost(frame: .zero)
        let view = host.textView
        view.delegate = context.coordinator
        context.coordinator.launchSplashVisible = launchSplashVisible
        context.coordinator.textView = view
        view.onStructuralLayout = { [weak coordinator = context.coordinator] in
            coordinator?.noteLayout()
        }
        view.onViewportHeightChange = { [weak coordinator = context.coordinator] in
            coordinator?.viewportResized()
        }
        view.onWidthWillChange = { [weak coordinator = context.coordinator] in
            coordinator?.holdBottomPin(for: 0.6)
        }
        view.onChromeLayout = { [weak coordinator = context.coordinator] in
            coordinator?.refreshChromeInsets(pinIfStuck: false)
        }
        view.onChromeRepaired = { [weak coordinator = context.coordinator] in
            coordinator?.chromeRepaired()
        }
        view.onPinnedLayout = { [weak coordinator = context.coordinator] in
            coordinator?.layoutWhilePinned()
        }
        // A quick tap hilites a word. Touches are not cancelled, so a drag still
        // scrolls and a link still opens. The text view refuses first responder
        // for that tap when this orientation leaves the keyboard up.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.wordTapped(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.wordTap = tap
        return host
    }

    /// Width and height are the slot SwiftUI offered, edge to edge behind the
    /// bars. Measuring the text here is what made a scroll frame lay out every
    /// glyph. An unspecified height is not a shorter column above the menu:
    /// the menu stays clear because of the bottom content inset.
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
        coordinator.holdHiliteClear = true
        defer { coordinator.holdHiliteClear = false }
        coordinator.onNearBottom = onNearBottom
        coordinator.onRevealFinished = onRevealFinished
        coordinator.onHilitedWord = onHilitedWord
        coordinator.revealPending = revealPending
        coordinator.resumeSeparatorID = resumeSeparatorID
        coordinator.lines = lines
        let splashEnded = coordinator.launchSplashVisible && launchSplashVisible == false
        coordinator.launchSplashVisible = launchSplashVisible
        if splashEnded {
            // Arm the hold before text or insets move the offset. Those
            // callbacks look like a reader scroll once the cover flag drops.
            coordinator.prepareForLaunchSplashEnd()
        }
        let heightsChanged = abs(coordinator.topBarHeight - topBarHeight) >= 0.5
            || abs(coordinator.bottomBarHeight - bottomBarHeight) >= 0.5
            || abs(coordinator.topClearance - topClearance) >= 0.5
            || abs(coordinator.bottomClearance - bottomClearance) >= 0.5
            || abs(coordinator.columnHeight - columnHeight) >= 0.5
        coordinator.topBarHeight = topBarHeight
        coordinator.bottomBarHeight = bottomBarHeight
        coordinator.topClearance = topClearance
        coordinator.bottomClearance = bottomClearance
        coordinator.columnHeight = columnHeight
        coordinator.refreshChromeInsets(pinIfStuck: heightsChanged)
        let requestedScroll = coordinator.scrollToken != scrollToken
        if requestedScroll {
            coordinator.scrollToken = scrollToken
            coordinator.nearBottom = true
            coordinator.stickToBottom = true
            coordinator.extendBottomHold(by: 0.25)
            coordinator.scrollToBottom(animated: false)
        }
        coordinator.applyIfPossible()
        if splashEnded {
            // Text that arrived under the cover is in the storage now.
            // Pin after that apply so the offset includes it.
            coordinator.pinAfterLaunchSplash()
        }
        coordinator.syncReveal()
        if requestedScroll == false, coordinator.stickToBottom == false, coordinator.revealing == false {
            let deltaY = abs(textView.contentOffset.y - offset.y)
            let deltaX = abs(textView.contentOffset.x - offset.x)
            if deltaY > 1 || deltaX > 1 {
                textView.setContentOffset(offset, animated: false)
            }
        }
        // Inset and text edits above can move the offset and then put it back.
        // Judge the hilite against the offset that sticks.
        coordinator.holdHiliteClear = false
        coordinator.clearHiliteIfOffscreen()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_: TranscriptHost, coordinator: Coordinator) {
        coordinator.cancelHilitePublish()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        weak var textView: TranscriptTextView?
        weak var wordTap: UITapGestureRecognizer?
        let store = TranscriptDocumentStore()
        let carry = ColourCarryCache()
        var lines: [LineDTO] = []
        var onNearBottom: (Bool) -> Void = { _ in }
        var onRevealFinished: (String) -> Void = { _ in }
        var onHilitedWord: (String?) -> Void = { _ in }
        var revealPending = false
        var resumeSeparatorID: String?
        /// Starts covered. `makeUIView` copies the real flag before the first
        /// layout, so a launch scroll is not treated as the reader leaving.
        var launchSplashVisible = true
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
        /// Last portrait decision. Nil until the text view has a real width,
        /// so the first layout is not treated as a rotation.
        private var portraitEnlarged: Bool?
        var topBarHeight: CGFloat = 0
        var bottomBarHeight: CGFloat = 0
        /// Top of the column to the bottom of the name bar, in column space.
        var topClearance: CGFloat = 0
        /// Column bottom minus the command bar or menu's top. The overlap.
        var bottomClearance: CGFloat = 0
        /// Height of the SwiftUI column the bars are laid out in.
        var columnHeight: CGFloat = 0
        /// While the keyboard frame is animating, height changes are not a
        /// second pin. The notification below scrolls once when it ends.
        private var keyboardAnimationUntil = Date.distantPast
        /// Overlap frozen at the start of a keyboard animation so layout
        /// does not rewrite the bottom inset on every frame.
        private var keyboardOverlapLatch: CGFloat?
        private var keyboardToken = 0
        private var inChrome = false
        private var pinning = false
        /// Keyboard frame from the last ended animation, in screen coordinates.
        /// Nil until a keyboard has been shown, and nil again once it hides.
        /// Not the layout guide: that guide clears this text view's bottom
        /// content inset. A portrait docked rect left in place after a
        /// landscape dismiss keeps the last line a keyboard-height above the bar.
        private var keyboardEndFrame: CGRect?
        /// Set when the keyboard is leaving. A later frame-change from the
        /// rotation must not put the docked rect back into the bottom inset.
        private var keyboardDismissed = false
        /// The reader was on the bottom at the start of a resize or keyboard
        /// animation. A finger drag clears it. The scroll view reports both
        /// as scrolls, so the pin is put back when the keyboard animation ends.
        private var bottomPinHeld = false
        /// Resume separator whose ease ran, or would have run, under the launch
        /// cover. `revealPending` stays true until SwiftUI applies the finish
        /// callback, and that gap must not block the pin when the cover ends.
        private var coveredRevealID: String?
        /// Bumped when the reader drags, so a follow-up pin after the cover
        /// does not pull them back down.
        private var launchPinToken = 0
        private var keyboardObservers: [NSObjectProtocol] = []
        /// One hilited word, tied to its line so a cap trim can keep it when
        /// that row is still on screen. The drawn range is overlay-only.
        private struct WordHilite: Equatable {
            var lineID: String
            var word: String
            var offsetInLine: Int
            var length: Int
        }
        private var hilite: WordHilite?
        /// Glyph box in the text view's coordinate space (`firstRect`).
        /// A scroll compares it with the visible window and does not measure
        /// TextKit on every frame.
        private var hiliteBounds: CGRect?
        private var publishedHilite: String?
        private var hilitePublishGeneration = 0
        private var checkingHilite = false
        /// Set while resolving a tap, so a layout pass from that tap cannot
        /// drop the hilite before its glyph box is known.
        private var tappingWord = false
        private var measuringHilite = false
        /// Set for the body of `updateUIView` until the offset is restored.
        var holdHiliteClear = false

        /// A resume reveal owns the offset until it eases to the bottom.
        /// The launch cover is not that reveal: the reader cannot see it, and
        /// the keyboard that appears when the cover ends would leave a stale
        /// ease target short of the latest line.
        private var revealBlocksBottomPin: Bool {
            if launchSplashVisible { return false }
            if revealing { return true }
            guard revealPending else { return false }
            if let coveredRevealID, coveredRevealID == resumeSeparatorID { return false }
            return true
        }

        override init() {
            super.init()
            let center = NotificationCenter.default
            let names = [
                UIResponder.keyboardWillChangeFrameNotification,
                UIResponder.keyboardWillShowNotification,
                UIResponder.keyboardWillHideNotification
            ]
            for name in names {
                keyboardObservers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                        self?.keyboardWillChange(note)
                    }
                )
            }
            keyboardObservers.append(
                center.addObserver(
                    forName: UIResponder.keyboardDidHideNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.keyboardDidHide()
                }
            )
        }

        deinit {
            let center = NotificationCenter.default
            for observer in keyboardObservers {
                center.removeObserver(observer)
            }
        }

        /// One follow-up after the keyboard animation, not one per frame.
        /// The bar moves with the keyboard safe area. The bottom inset gains
        /// the keyboard only when that ended frame still overlaps the log, and
        /// the overlap stays latched until the animation ends. Hiding clears
        /// the frame so a portrait keyboard does not stay in the landscape inset.
        private func keyboardWillChange(_ note: Notification) {
            if note.name == UIResponder.keyboardWillHideNotification {
                keyboardDismissed = true
            } else if note.name == UIResponder.keyboardWillShowNotification {
                keyboardDismissed = false
            } else if keyboardDismissed {
                return
            }
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            // Outlast the animation so a resize scroll cannot drop the pin
            // before the resting offset is known.
            holdBottomPin(for: duration + 0.75)
            if let textView {
                keyboardOverlapLatch = extraBelowBar(for: textView, latched: false)
            }
            keyboardAnimationUntil = Date().addingTimeInterval(duration)
            keyboardToken += 1
            let token = keyboardToken
            let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let coordinator = self, token == coordinator.keyboardToken else { return }
                coordinator.finishKeyboardAnimation(end: end)
            }
        }

        /// The keyboard is gone. End the suppression window now: the rotation
        /// notification's duration can still be running, and that was blocking
        /// the pin after the landscape insets settled.
        private func keyboardDidHide() {
            keyboardDismissed = true
            keyboardToken += 1
            finishKeyboardAnimation(end: nil)
        }

        private func finishKeyboardAnimation(end: CGRect?) {
            keyboardOverlapLatch = nil
            keyboardAnimationUntil = .distantPast
            if keyboardDismissed {
                keyboardEndFrame = nil
            } else {
                keyboardEndFrame = end
            }
            restoreHeldBottomPin()
            let pin = stickToBottom && revealBlocksBottomPin == false
            refreshChromeInsets(pinIfStuck: pin)
            pinRestingBottomAfterLayout()
        }

        /// Width change or keyboard animation. Does not pull a reader who has
        /// scrolled up, and does not fight a finger that is already down.
        func holdBottomPin(for duration: TimeInterval) {
            guard revealBlocksBottomPin == false else { return }
            guard let textView,
                  textView.isTracking == false,
                  textView.isDragging == false,
                  textView.isDecelerating == false else { return }
            guard stickToBottom || nearBottom else { return }
            bottomPinHeld = true
            extendBottomHold(by: duration)
        }

        func extendBottomHold(by duration: TimeInterval) {
            let until = Date().addingTimeInterval(duration)
            if holdUntil < until {
                holdUntil = until
            }
        }

        private func restoreHeldBottomPin() {
            let held = bottomPinHeld
            bottomPinHeld = false
            guard held, revealBlocksBottomPin == false else { return }
            guard let textView,
                  textView.isTracking == false,
                  textView.isDragging == false,
                  textView.isDecelerating == false else { return }
            // A resize scroll may already have published "not at the bottom".
            // Put that back so the new-lines chip does not appear on a pin.
            stickToBottom = true
            if nearBottom == false {
                emitNear(true)
            }
        }

        /// Scroll once with the insets just written, then once more after the
        /// next layout. Rotation often ends the keyboard animation before the
        /// landscape column and the reflowed text have both settled.
        private func pinRestingBottomAfterLayout() {
            guard stickToBottom, revealBlocksBottomPin == false else { return }
            guard let textView,
                  textView.isTracking == false,
                  textView.isDragging == false,
                  textView.isDecelerating == false else { return }
            scrollToBottom(animated: false)
            let token = keyboardToken
            DispatchQueue.main.async { [weak self] in
                guard let coordinator = self, token == coordinator.keyboardToken else { return }
                guard coordinator.stickToBottom, coordinator.revealBlocksBottomPin == false else { return }
                guard let textView = coordinator.textView,
                      textView.isTracking == false,
                      textView.isDragging == false,
                      textView.isDecelerating == false else { return }
                coordinator.refreshChromeInsets(pinIfStuck: true)
                coordinator.scrollToBottom(animated: false)
            }
        }

        /// Top inset is the name bar. Bottom inset is the command bar or the
        /// encamp menu, plus the home indicator when this view extends into it,
        /// plus the keyboard where that ended frame still covers the log.
        /// The frame stays the full column, so a taller menu does not shorten it.
        func refreshChromeInsets(pinIfStuck: Bool) {
            guard inChrome == false else { return }
            guard let textView, textView.bounds.width > 1, textView.bounds.height > 1 else { return }
            let insets = makeChromeInsets(for: textView)
            let changed = verticalInsetsDiffer(textView.chromeInsets, insets)
                || verticalInsetsDiffer(textView.contentInset, insets)
            guard changed || pinIfStuck else { return }
            inChrome = true
            defer {
                inChrome = false
                clearHiliteIfOffscreen()
            }
            textView.chromeInsets = insets
            textView.enforceChromeInsets()
            guard stickToBottom, revealBlocksBottomPin == false else { return }
            guard textView.isDragging == false, textView.isDecelerating == false else { return }
            guard Date() >= keyboardAnimationUntil || pinIfStuck else { return }
            scrollToBottom(animated: false)
        }

        /// Layout changed the column, the glyphs, or the inset. If the reader
        /// is holding the bottom, scroll again after TextKit has measured.
        func layoutWhilePinned() {
            guard pinning == false, inChrome == false else { return }
            guard Date() >= keyboardAnimationUntil else { return }
            guard stickToBottom, revealBlocksBottomPin == false else { return }
            guard let textView, textView.isDragging == false, textView.isDecelerating == false else { return }
            scrollToBottom(animated: false)
        }

        /// Layout put the bottom clearance back after clearing it. Pin once.
        func chromeRepaired() {
            guard Date() >= keyboardAnimationUntil else { return }
            guard stickToBottom, revealBlocksBottomPin == false else { return }
            guard let textView, textView.isDragging == false, textView.isDecelerating == false else { return }
            scrollToBottom(animated: false)
        }

        private func makeChromeInsets(for textView: UITextView) -> UIEdgeInsets {
            // The frame overlap is the bar's top measured in the column. The
            // background GeometryReader height can come back short. Either one
            // alone left the last line under the bar; the larger one is used.
            let topBase = max(topClearance, max(0, topBarHeight))
            let bottomBase = max(bottomClearance, max(0, bottomBarHeight))
            let top = topBase + unsafeTopOverlap(in: textView)
            let bottom = bottomBase + extraBelowBar(for: textView, latched: true)
            return UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }

        /// Space below the bar's top that is not the bar's own height: the
        /// home indicator when the log hangs below the column, or the keyboard
        /// when that ended frame still covers the log. Latched during the
        /// keyboard animation so the inset is not rewritten every frame.
        private func extraBelowBar(for textView: UITextView, latched: Bool) -> CGFloat {
            if latched, let keyboardOverlapLatch, Date() < keyboardAnimationUntil {
                return keyboardOverlapLatch
            }
            let belowColumn: CGFloat
            if columnHeight > 1 {
                belowColumn = max(0, textView.bounds.height - columnHeight)
            } else {
                belowColumn = unsafeBottomOverlap(in: textView)
            }
            return max(belowColumn, measuredKeyboardOverlap(in: textView))
        }

        /// How far this view extends below the safe area. Zero when the log
        /// already ends at the top of the home indicator.
        private func unsafeBottomOverlap(in textView: UITextView) -> CGFloat {
            guard let window = textView.window else { return 0 }
            let frame = textView.convert(textView.bounds, to: window)
            let safeMaxY = window.bounds.maxY - window.safeAreaInsets.bottom
            return max(0, frame.maxY - safeMaxY)
        }

        /// How far this view extends above the safe area, under the status bar.
        private func unsafeTopOverlap(in textView: UITextView) -> CGFloat {
            guard let window = textView.window else { return 0 }
            let frame = textView.convert(textView.bounds, to: window)
            let safeMinY = window.bounds.minY + window.safeAreaInsets.top
            return max(0, safeMinY - frame.minY)
        }

        /// Intersection of the last keyboard frame with this view. Zero when
        /// the safe area has already lifted the log clear of the keyboard, and
        /// zero for a floating keyboard that does not reach the bottom edge.
        private func measuredKeyboardOverlap(in textView: UITextView) -> CGFloat {
            guard let keyboardEndFrame, let window = textView.window else { return 0 }
            guard textView.bounds.height > 1 else { return 0 }
            let screen = window.windowScene?.screen
            let inWindow = screen.map { window.convert(keyboardEndFrame, from: $0.coordinateSpace) } ?? keyboardEndFrame
            guard inWindow.maxY >= window.bounds.maxY - 1 else { return 0 }
            let inView = textView.convert(inWindow, from: window)
            let overlap = textView.bounds.intersection(inView)
            guard overlap.isNull == false, overlap.height > 0.5 else { return 0 }
            guard overlap.maxY >= textView.bounds.maxY - 1 else { return 0 }
            return overlap.height
        }

        private func verticalInsetsDiffer(_ lhs: UIEdgeInsets, _ rhs: UIEdgeInsets) -> Bool {
            abs(lhs.top - rhs.top) >= 0.5 || abs(lhs.bottom - rhs.bottom) >= 0.5
        }

        func noteLayout() {
            guard inLayout == false, applying == false else { return }
            inLayout = true
            defer { inLayout = false }
            applyIfPossible()
            syncReveal()
            stickIfNeeded()
        }

        /// The slot's height changed (rotation, split view, or the keyboard
        /// settling). One pin, and not once per keyboard frame. The menu
        /// clears the last lines with the bottom inset, not this height.
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
            let portrait = transcriptIsPortrait(textView)
            let flipped = portraitEnlarged != nil && portraitEnlarged != portrait
            let wasAtBottom = stickToBottom || nearBottom
            if flipped, wasAtBottom {
                // Rotation keeps reporting scroll events while the text
                // restyles. Hold the bottom pin across that animation.
                // A longer hold from the keyboard dismiss must not be shortened.
                stickToBottom = true
                nearBottom = true
                extendBottomHold(by: 0.6)
            }
            portraitEnlarged = portrait
            guard let edit = store.update(
                lines: lines,
                fontSize: font,
                width: textView.bounds.width,
                enlargeCommunication: portrait,
                carry: carry
            ) else { return }
            apply(edit, to: textView)
            if revealing && launchSplashVisible == false {
                deferredBottom = true
            } else if nearBottom, revealBlocksBottomPin == false {
                stickToBottom = true
                let follow = self
                DispatchQueue.main.async {
                    // A drag in this gap is the reader leaving the bottom.
                    // The launch follow-up uses the same rule.
                    guard follow.stickToBottom, follow.revealBlocksBottomPin == false else { return }
                    guard let textView = follow.textView,
                          textView.isDragging == false,
                          textView.isDecelerating == false else { return }
                    follow.scrollToBottom(animated: false)
                }
            }
        }

        /// The cover is about to stop eating touches. Keep the pin through the
        /// fade, and do not play a resume ease that ran only under the cover.
        func prepareForLaunchSplashEnd() {
            if revealPending || revealing {
                skipCoveredReveal()
            }
            stickToBottom = true
            bottomPinHeld = true
            if nearBottom == false {
                emitNear(true)
            }
            extendBottomHold(by: 1.0)
        }

        /// Latest line, after the text that arrived under the cover is applied.
        /// A second pin follows the keyboard that the command field takes as
        /// the cover fades. A drag cancels that follow-up.
        func pinAfterLaunchSplash() {
            launchPinToken += 1
            let token = launchPinToken
            stickToBottom = true
            scrollToBottom(animated: false)
            DispatchQueue.main.async { [weak self] in
                self?.repeatLaunchPin(token)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.repeatLaunchPin(token)
            }
        }

        private func repeatLaunchPin(_ token: Int) {
            guard token == launchPinToken else { return }
            guard stickToBottom, revealBlocksBottomPin == false else { return }
            guard let textView,
                  textView.isTracking == false,
                  textView.isDragging == false,
                  textView.isDecelerating == false else { return }
            if Date() < keyboardAnimationUntil {
                let delay = keyboardAnimationUntil.timeIntervalSinceNow + 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.05)) { [weak self] in
                    self?.repeatLaunchPin(token)
                }
                return
            }
            scrollToBottom(animated: false)
        }

        /// The separator stays in the log. The ease does not: it would finish
        /// on an offset from before the cover's keyboard inset.
        private func skipCoveredReveal() {
            revealToken += 1
            let wasRevealing = revealing
            revealing = false
            deferredBottom = false
            if wasRevealing, let textView {
                textView.layer.removeAllAnimations()
                programmatic += 1
                textView.setContentOffset(textView.contentOffset, animated: false)
                programmatic = max(0, programmatic - 1)
            }
            let id = resumeSeparatorID ?? startedRevealID
            guard let id, id.isEmpty == false else {
                revealPending = false
                return
            }
            coveredRevealID = id
            startedRevealID = id
            revealPending = false
            guard finishedRevealID != id else { return }
            finishedRevealID = id
            let callback = onRevealFinished
            DispatchQueue.main.async {
                callback(id)
            }
        }

        func syncReveal() {
            // The ease would run under the cover and then refuse later pins.
            // It starts once the cover is gone, unless that gap was already skipped.
            guard launchSplashVisible == false else { return }
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
            // A full replace or a tail edit would leave the old character range
            // pointing at different glyphs. An append keeps the prefix.
            if let range = textView.rules?.hiliteRange, cut <= range.location {
                textView.rules?.setHilite(nil)
            }
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
            // Lay the new tail out before the next draw, so a timestamp stamp
            // is not placed on the enlarged line above it.
            _ = textView.settledContentHeight()
            remapHilite(in: textView)
            textView.setNeedsDisplay()
        }

        func scrollToBottom(animated: Bool) {
            guard let textView else { return }
            guard pinning == false else { return }
            pinning = true
            defer { pinning = false }
            textView.enforceChromeInsets()
            let y = maxOffset(of: textView)
            stickToBottom = true
            extendBottomHold(by: 0.25)
            setBottomOffset(y, on: textView, animated: animated)
            // ensureLayout can grow the used rect after the first assignment.
            let settled = maxOffset(of: textView)
            if abs(settled - y) > 0.5 {
                setBottomOffset(settled, on: textView, animated: false)
            }
        }

        private func setBottomOffset(_ y: CGFloat, on textView: TranscriptTextView, animated: Bool) {
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
                programmatic = max(0, programmatic - 1)
            }
        }

        func stickIfNeeded() {
            guard stickToBottom, revealBlocksBottomPin == false else { return }
            guard stickQueued == false else { return }
            guard let textView, textView.isDragging == false, textView.isDecelerating == false else { return }
            stickQueued = true
            DispatchQueue.main.async {
                self.stickQueued = false
                guard self.stickToBottom, self.revealBlocksBottomPin == false else { return }
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
            textView.enforceChromeInsets()
            let inset = restingInsets(of: textView)
            let visible = textView.bounds.height - inset.top - inset.bottom
            var y = rect.maxY - visible
            y = min(max(y, -inset.top), maxOffset(of: textView))
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
            extendBottomHold(by: 0.25)
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

        /// The clearance actually written onto the text view. `adjustedContentInset`
        /// is not used: with the keyboard guide detached it can still read as
        /// zero after layout clears `contentInset`, which parks the last line
        /// under the command bar.
        private func restingInsets(of textView: UITextView) -> UIEdgeInsets {
            if let transcript = textView as? TranscriptTextView {
                return transcript.chromeInsets
            }
            return textView.contentInset
        }

        private func maxOffset(of textView: UITextView) -> CGFloat {
            let inset = restingInsets(of: textView)
            let height: CGFloat
            if let transcript = textView as? TranscriptTextView {
                transcript.enforceChromeInsets()
                height = transcript.settledContentHeight()
            } else {
                height = textView.contentSize.height
            }
            return max(-inset.top, height - textView.bounds.height + inset.bottom)
        }

        private func distanceFromBottom(of textView: UITextView) -> CGFloat {
            let inset = restingInsets(of: textView)
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

        /// Quick tap. The same word again clears the hilite. Another word switches it.
        /// A drag does not land here: the recognizer waits for the pan to fail.
        @objc func wordTapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let textView else { return }
            guard launchSplashVisible == false, textView.isDragging == false else { return }
            let point = gesture.location(in: textView)
            // The field stayed first responder, so the system's link action may
            // not run. Open the same URL the delegate would have opened.
            if textView.keepsCommandFieldForQuickTap(),
               let url = TranscriptWord.link(in: textView, at: point) {
                TranscriptLinkOpener.open(url)
            }
            tappingWord = true
            defer { tappingWord = false }
            guard let hit = TranscriptWord.hit(in: textView, at: point) else { return }
            guard let anchor = hiliteAnchor(for: hit) else { return }
            if hilite == anchor {
                clearHilite()
                return
            }
            hilite = anchor
            textView.rules?.setHilite(hit.range)
            hiliteBounds = measureHiliteBounds(in: textView)
            publishHilite(anchor.word)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive _: UITouch) -> Bool {
            if gestureRecognizer === wordTap {
                textView?.noteFingerDown()
            }
            return true
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Link taps still fire. The scroll pan must not also count as a tap.
            other is UIPanGestureRecognizer == false
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRequireFailureOf other: UIGestureRecognizer
        ) -> Bool {
            guard let textView else { return false }
            return other === textView.panGestureRecognizer
        }

        private func hiliteAnchor(for hit: TranscriptWord.Hit) -> WordHilite? {
            guard let marker = store.markers.last(where: {
                hit.range.location >= $0.location
                    && hit.range.location + hit.range.length <= $0.location + $0.contentLength
            }) else { return nil }
            return WordHilite(
                lineID: marker.id,
                word: hit.word,
                offsetInLine: hit.range.location - marker.location,
                length: hit.range.length
            )
        }

        /// Put the hilite back on the same line after an append or a cap trim.
        /// The row's id is the anchor. A trim of other rows does not drop it.
        /// The row itself leaving the storage leaves nothing on screen to draw.
        private func remapHilite(in textView: TranscriptTextView) {
            guard let anchor = hilite else {
                textView.rules?.setHilite(nil)
                hiliteBounds = nil
                return
            }
            guard let located = locate(anchor, in: textView) else {
                clearHilite()
                return
            }
            if located.offset != anchor.offsetInLine || located.range.length != anchor.length {
                hilite = WordHilite(
                    lineID: anchor.lineID,
                    word: anchor.word,
                    offsetInLine: located.offset,
                    length: located.range.length
                )
            }
            textView.rules?.setHilite(located.range)
            hiliteBounds = measureHiliteBounds(in: textView)
        }

        private func locate(
            _ anchor: WordHilite,
            in textView: TranscriptTextView
        ) -> (range: NSRange, offset: Int)? {
            guard let marker = store.markers.first(where: { $0.id == anchor.lineID }) else { return nil }
            let storage = textView.textStorage.string as NSString
            guard marker.location >= 0, marker.location < storage.length else { return nil }
            let lineLength = min(marker.contentLength, storage.length - marker.location)
            guard lineLength > 0 else { return nil }
            let lineText = storage.substring(
                with: NSRange(location: marker.location, length: lineLength)
            ) as NSString
            if anchor.offsetInLine >= 0,
               anchor.offsetInLine + anchor.length <= lineText.length {
                let slice = NSRange(location: anchor.offsetInLine, length: anchor.length)
                if lineText.substring(with: slice) == anchor.word {
                    return (
                        NSRange(location: marker.location + anchor.offsetInLine, length: anchor.length),
                        anchor.offsetInLine
                    )
                }
            }
            guard let found = TranscriptWord.find(anchor.word, in: lineText, near: anchor.offsetInLine) else {
                return nil
            }
            return (
                NSRange(location: marker.location + found.location, length: found.length),
                found.location
            )
        }

        private func measureHiliteBounds(in textView: TranscriptTextView) -> CGRect? {
            guard measuringHilite == false else { return hiliteBounds }
            measuringHilite = true
            defer { measuringHilite = false }
            guard let range = textView.rules?.hiliteRange, range.length > 0 else { return nil }
            let storageLength = textView.textStorage.length
            guard range.location >= 0, NSMaxRange(range) <= storageLength else { return nil }
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { return nil }
            let rect = textView.firstRect(for: textRange)
            guard rect.isNull == false, rect.isInfinite == false,
                  rect.width > 0.5, rect.height > 0.5 else { return nil }
            return rect
        }

        /// The bars and the keyboard cover `chromeInsets`. The word stays hilited
        /// until its glyphs have left that window. Still being in the 4000-line
        /// buffer is not enough, and a trim of older rows is not a reason to drop
        /// a word that is still visible.
        func clearHiliteIfOffscreen() {
            guard holdHiliteClear == false else { return }
            guard tappingWord == false, measuringHilite == false else { return }
            guard checkingHilite == false, applying == false else { return }
            guard hilite != nil, let textView else { return }
            if hiliteBounds == nil {
                hiliteBounds = measureHiliteBounds(in: textView)
            }
            guard let wordRect = hiliteBounds, wordRect.width > 0.5, wordRect.height > 0.5 else { return }
            let visible = visibleWordRect(in: textView)
            guard visible.isNull == false, visible.width > 1, visible.height > 1 else { return }
            let overlap = wordRect.intersection(visible)
            guard overlap.isNull || overlap.width < 1 || overlap.height < 1 else { return }
            checkingHilite = true
            defer { checkingHilite = false }
            clearHilite()
        }

        private func visibleWordRect(in textView: TranscriptTextView) -> CGRect {
            let inset = textView.chromeInsets
            let bounds = textView.bounds
            let width = bounds.width - inset.left - inset.right
            let height = bounds.height - inset.top - inset.bottom
            guard width > 1, height > 1 else { return .null }
            return CGRect(
                x: bounds.minX + inset.left,
                y: bounds.minY + inset.top,
                width: width,
                height: height
            )
        }

        private func clearHilite() {
            guard hilite != nil || textView?.rules?.hiliteRange != nil else { return }
            hilite = nil
            hiliteBounds = nil
            textView?.rules?.setHilite(nil)
            publishHilite(nil)
        }

        func cancelHilitePublish() {
            hilitePublishGeneration += 1
        }

        private func publishHilite(_ word: String?) {
            guard publishedHilite != word else { return }
            publishedHilite = word
            hilitePublishGeneration += 1
            let generation = hilitePublishGeneration
            let callback = onHilitedWord
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.hilitePublishGeneration else { return }
                callback(word)
            }
        }

        func scrollViewWillBeginDragging(_: UIScrollView) {
            launchPinToken += 1
            bottomPinHeld = false
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
            if moved {
                clearHiliteIfOffscreen()
            }
            // Bounds and content-size changes call this too. Only a real offset
            // change is the reader moving; a keyboard frame must not flip the flag.
            // Rotation and the dismiss arm `holdUntil` before this runs.
            guard programmatic == 0, moved else { return }
            // The cover eats touches. Inset and content-size changes still
            // call this, and they were clearing the pin before the new lines
            // had a chance to follow the bottom.
            if launchSplashVisible {
                extendBottomHold(by: 0.25)
                emitNear(true)
                return
            }
            let near: Bool
            if Date() < holdUntil {
                near = true
            } else {
                near = distanceFromBottom(of: textView) <= nearBottomSlack
            }
            emitNear(near)
            if near == false {
                bottomPinHeld = false
            }
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
                TranscriptLinkOpener.open(url)
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

private struct TopBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct BottomBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TopBarBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct BottomBarBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct TopClearanceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BottomClearanceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ColumnHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Global frame of the log between the bars. The right-edge swipe strip is
/// only this tall, so it does not take taps from the name bar or Send.
private struct LogGlobalFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 1, next.height > 1 {
            value = next
        }
    }
}

/// The command line, as opposed to a password field. A log tap uses the
/// class to see which field is first responder, and refuses to resign while
/// this orientation leaves the keyboard up.
private final class CommandTextField: UITextField {
    /// True when a log tap must leave this field first responder.
    var shouldRemainFirstResponder: (() -> Bool)?

    override func resignFirstResponder() -> Bool {
        if shouldRemainFirstResponder?() == true {
            return false
        }
        return super.resignFirstResponder()
    }
}

/// Command line. A stock SwiftUI field resigns on Return and again when focus
/// is written `true` while it is already first responder, so the keyboard
/// drops and comes back. This field becomes first responder only on the
/// transition into focus. Return resigns only when this orientation hides
/// the keyboard. A long-press selection in the log, a swipe-down, and a
/// hide-on send still end editing. A tap on the log does not, when this
/// orientation leaves the keyboard up.
///
/// Traits are set once. `textInputMode` is not overridden, and
/// `becomeFirstResponder` is not called from `updateUIView`: doing either
/// restarts the input session, the caret blinks, and the keyboard never attaches.
private struct CommandLineField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    /// Hide switch for the orientation on screen. Return dismisses only then.
    var dismissOnSubmit: Bool
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = CommandTextField()
        field.delegate = context.coordinator
        field.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        field.textColor = UIColor(white: 0.78, alpha: 1)
        field.tintColor = field.textColor
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.keyboardType = .asciiCapable
        field.returnKeyType = .send
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.keyboardAppearance = .dark
        field.attributedPlaceholder = NSAttributedString(
            string: "command",
            attributes: [.foregroundColor: UIColor(white: 0.78, alpha: 0.45)]
        )
        field.accessibilityLabel = "command"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    /// One line, the same height as Say and Send. A proposed height is often
    /// the whole column; using it made the command bar as tall as the screen.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextField,
        context _: Context
    ) -> CGSize? {
        let width: CGFloat
        if let proposed = proposal.width, proposed > 0, proposed < .greatestFiniteMagnitude {
            width = proposed
        } else {
            width = uiView.bounds.width
        }
        return CGSize(width: width, height: 44)
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSubmit = onSubmit
        coordinator.dismissOnSubmit = dismissOnSubmit
        coordinator.isFocused = $isFocused
        coordinator.textChanged = { text = $0 }
        if let command = field as? CommandTextField {
            // Live hide switch, not `dismissOnSubmit`: that flag can be a
            // frame behind the drawer. A swipe clears `wantsFocus` first.
            command.shouldRemainFirstResponder = { [weak coordinator] in
                guard let coordinator, coordinator.wantsFocus else { return false }
                return TranscriptTextView.logTapShouldKeepCommandField()
            }
        }
        // A programmatic clear (send) must not restart the input session.
        // Marked text is an in-progress composition; replacing it drops characters.
        if field.markedTextRange == nil, field.text != text {
            coordinator.applyingText = true
            field.text = text
            coordinator.applyingText = false
        }
        if coordinator.wantsFocus != isFocused {
            coordinator.wantsFocus = isFocused
            if isFocused {
                coordinator.scheduleBecome(field)
            } else {
                coordinator.scheduleResign(field)
            }
        } else if isFocused, coordinator.wantsFocus, field.isFirstResponder == false {
            // The focus flag was set before the field was in a window.
            // A field that already resigned has wantsFocus clear, so this
            // does not put the keyboard back over a log selection.
            coordinator.scheduleBecome(field)
        }
    }

    static func dismantleUIView(_ uiView: UITextField, coordinator: Coordinator) {
        coordinator.wantsFocus = false
        if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onSubmit: () -> Void = {}
        var textChanged: (String) -> Void = { _ in }
        var isFocused: Binding<Bool> = .constant(false)
        var dismissOnSubmit = false
        var wantsFocus = false
        var applyingText = false
        var becoming = false

        @objc func editingChanged(_ field: UITextField) {
            guard applyingText == false else { return }
            textChanged(field.text ?? "")
        }

        /// Hide-off: any log tap must not resign. Returning false leaves this
        /// field first responder, so the keyboard never starts to hide. A
        /// long-press selection still resigns. A swipe-down clears
        /// `wantsFocus` before it resigns. Hide-on fails the keep check.
        func textFieldShouldEndEditing(_: UITextField) -> Bool {
            if wantsFocus, TranscriptTextView.logTapShouldKeepCommandField() {
                return false
            }
            return true
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            wantsFocus = true
            if isFocused.wrappedValue == false {
                isFocused.wrappedValue = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            wantsFocus = false
            if isFocused.wrappedValue {
                isFocused.wrappedValue = false
            }
        }

        /// Return sends. Hide-off leaves the field first responder so the
        /// keyboard does not animate out. Hide-on resigns on the keypress.
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            let dismiss = dismissOnSubmit
            onSubmit()
            if dismiss, textField.isFirstResponder {
                textField.resignFirstResponder()
            }
            return false
        }

        func scheduleBecome(_ field: UITextField, retries: Int = 10) {
            guard becoming == false else { return }
            becoming = true
            DispatchQueue.main.async { [weak field] in
                guard let field else {
                    self.becoming = false
                    return
                }
                guard self.wantsFocus else {
                    self.becoming = false
                    return
                }
                guard field.window != nil else {
                    self.becoming = false
                    guard retries > 0 else { return }
                    self.scheduleBecome(field, retries: retries - 1)
                    return
                }
                // Stay marked until become returns. A layout pass inside
                // become must not schedule a second one; that restarts the
                // input session and the keyboard never attaches.
                if field.isFirstResponder == false {
                    field.becomeFirstResponder()
                }
                self.becoming = false
            }
        }

        func scheduleResign(_ field: UITextField) {
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                guard self.wantsFocus == false else { return }
                if field.isFirstResponder {
                    field.resignFirstResponder()
                }
            }
        }
    }
}

/// Death sentence, horizontally centered in the middle of the top two-thirds.
/// The red is translucent so the log shows through, and the flash does not take taps.
private struct DeathFlash: View {
    var opacity: Double

    var body: some View {
        GeometryReader { proxy in
            let size = max(72, min(proxy.size.width, proxy.size.height) * 0.28) * 0.75
            Text("YOU ARE DEAD!")
                .font(.system(size: size, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.red.opacity(0.7))
                .lineLimit(3)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 12)
                .frame(width: proxy.size.width)
                .position(
                    x: proxy.size.width / 2,
                    y: proxy.size.height * (1.0 / 3.0)
                )
                .opacity(opacity)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("You are dead")
        .accessibilityHidden(opacity < 0.05)
    }
}

/// `+87 XP!` or `LEVEL!`. Matches `DeathFlash` except the color is yellow.
/// The flash does not take taps.
private struct AwardFlash: View {
    var message: String
    var opacity: Double

    var body: some View {
        GeometryReader { proxy in
            let size = max(72, min(proxy.size.width, proxy.size.height) * 0.28) * 0.75
            Text(message)
                .font(.system(size: size, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.yellow.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 12)
                .frame(width: proxy.size.width)
                .position(
                    x: proxy.size.width / 2,
                    y: proxy.size.height * (1.0 / 3.0)
                )
                .opacity(opacity)
        }
        .allowsHitTesting(false)
        .accessibilityLabel(message)
        .accessibilityHidden(opacity < 0.05)
    }
}

/// Holds award lines until each has been on screen. A class so the playback
/// task and a later line share one queue.
private final class AwardQueue {
    var messages: [String] = []
    var playing = false
    var generation = 0
}

struct TranscriptView: View {
    @EnvironmentObject private var session: IMSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.launchSplashVisible) private var launchSplashVisible
    /// Owned here, not by SwiftUI's focus engine. Nothing uses `.focused` on
    /// this flag; the command field reads it and resigns only when it drops.
    @State private var commandFocused = false
    @StateObject private var keyboardPrefs = KeyboardHidePreferences()
    /// The command field should be first responder. Set when this orientation
    /// keeps the keyboard, cleared when the player swipes it away or a switch hides it.
    @State private var keyboardHeld = false
    @State private var keyboardOrientationToken = 0
    /// One restore is in flight. Stops a focus drop from scheduling another.
    @State private var restoringKeyboard = false
    /// Bumped by the accessibility action. Each change opens the left card.
    @State private var settingsOpenRequest = false
    /// The left card has settled open. The command keyboard stays down until it closes.
    @State private var keyboardSettingsOpen = false
    @StateObject private var actionSlots = ActionSlotStore()
    /// Bumped by the accessibility action. Each change opens the right card.
    @State private var actionSlotsOpenRequest = false
    /// The right card has settled open. The command keyboard stays down until it closes.
    @State private var actionSlotsOpen = false
    /// Global frame of the log between the bars. The right-edge strip reads it.
    @State private var logGlobalFrame: CGRect = .zero
    /// Launch cover. Starts up so the first frame cannot focus the command
    /// field; `adoptLaunchSplash` copies the parent flag in on appear.
    @State private var launchSplashUp = true
    /// True when the latest text is within `nearBottomSlack` of the viewport.
    /// Written only when that flips.
    @State private var nearBottom = true
    /// New lines arrived while the reader was up in the backlog.
    @State private var showNewLines = false
    /// Upward swipe on the input bar. One row of compass commands.
    @State private var actionPanelShown = false
    /// Bumps when "New lines" asks the text view to jump to the bottom.
    @State private var scrollToken = 0
    /// Name bar height. Top content inset of the log.
    @State private var topBarHeight: CGFloat = 0
    /// Command bar or encamp-menu height. Bottom content inset of the log.
    @State private var bottomBarHeight: CGFloat = 0
    /// Column top to the bottom edge of the name bar.
    @State private var topClearance: CGFloat = 0
    /// Top edge of the command bar or menu to the column bottom.
    @State private var bottomClearance: CGFloat = 0
    /// Laid-out height of the column behind the bars.
    @State private var columnHeight: CGFloat = 0
    /// The death flash is on screen. Cleared after it fades.
    @State private var deathShown = false
    /// 1 while the sentence is held, then animated to 0.
    @State private var deathOpacity = 0.0
    @State private var deathTask: Task<Void, Never>?
    /// The experience or level flash is on screen. Cleared after it fades.
    @State private var awardShown = false
    /// 1 while `+87 XP!` or `LEVEL!` is held, then animated to 0.
    @State private var awardOpacity = 0.0
    @State private var awardText = ""
    @State private var awardTask: Task<Void, Never>?
    @State private var awardQueue = AwardQueue()

    /// Count and the newest line, so a capped buffer and an insert both register
    /// without observing the whole transcript array.
    private var linesScrollSignal: String {
        "\(session.lines.count)#\(session.lines.last?.id ?? "")"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TranscriptLog(
                    lines: session.lines,
                    scrollToken: scrollToken,
                    topBarHeight: topBarHeight,
                    bottomBarHeight: bottomBarHeight,
                    topClearance: topClearance,
                    bottomClearance: bottomClearance,
                    columnHeight: columnHeight,
                    revealPending: session.pendingResumeReveal,
                    resumeSeparatorID: session.resumeSeparatorID,
                    launchSplashVisible: launchSplashVisible,
                    onNearBottom: { near in
                        if nearBottom != near {
                            nearBottom = near
                        }
                    },
                    onRevealFinished: { id in
                        session.finishResumeReveal(separatorID: id)
                    },
                    onHilitedWord: { word in
                        session.setHilitedWord(word)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // The log stays edge to edge under the bars. The flexible middle,
                // not the text view, absorbs the menu's extra height. The bottom
                // inset keeps the last lines above the menu or the command bar.
                VStack(spacing: 0) {
                    topBar
                    ZStack(alignment: .bottom) {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                        if showNewLines, nearBottom == false, session.pendingResumeReveal == false {
                            newLinesButton
                                .padding(.bottom, 8)
                        }
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: LogGlobalFrameKey.self,
                                value: proxy.frame(in: .global)
                            )
                        }
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        skillActionButtons
                    }
                    .clipped()
                    Group {
                        if session.atMenu {
                            GameMenuPanel()
                        } else {
                            inputBar
                        }
                    }
                    .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(screen.ignoresSafeArea())
            .backgroundPreferenceValue(TopBarBoundsKey.self) { topAnchor in
                GeometryReader { proxy in
                    let top = topAnchor.map { proxy[$0].maxY } ?? 0
                    Color.clear.preference(key: TopClearanceKey.self, value: top)
                }
                .allowsHitTesting(false)
            }
            .backgroundPreferenceValue(BottomBarBoundsKey.self) { bottomAnchor in
                GeometryReader { proxy in
                    let overlap = bottomAnchor.map { max(0, proxy.size.height - proxy[$0].minY) } ?? 0
                    Color.clear
                        .preference(key: BottomClearanceKey.self, value: overlap)
                        .preference(key: ColumnHeightKey.self, value: proxy.size.height)
                }
                .allowsHitTesting(false)
            }
            .onPreferenceChange(TopBarHeightKey.self) { height in
                guard height > 1, abs(height - topBarHeight) > 0.5 else { return }
                topBarHeight = height
            }
            .onPreferenceChange(BottomBarHeightKey.self) { height in
                guard height > 1, abs(height - bottomBarHeight) > 0.5 else { return }
                bottomBarHeight = height
            }
            .onPreferenceChange(TopClearanceKey.self) { value in
                guard value > 1, abs(value - topClearance) > 0.5 else { return }
                topClearance = value
            }
            .onPreferenceChange(BottomClearanceKey.self) { value in
                guard value > 1, abs(value - bottomClearance) > 0.5 else { return }
                bottomClearance = value
            }
            .onPreferenceChange(ColumnHeightKey.self) { value in
                guard value > 1, abs(value - columnHeight) > 0.5 else { return }
                columnHeight = value
            }
            .onPreferenceChange(LogGlobalFrameKey.self) { frame in
                guard frame.width > 1, frame.height > 1 else { return }
                guard abs(frame.minX - logGlobalFrame.minX) > 0.5
                    || abs(frame.minY - logGlobalFrame.minY) > 0.5
                    || abs(frame.width - logGlobalFrame.width) > 0.5
                    || abs(frame.height - logGlobalFrame.height) > 0.5 else { return }
                logGlobalFrame = frame
            }
            .preferredColorScheme(.dark)
            .toolbar(.hidden, for: .navigationBar)
            .overlay {
                KeyboardSettingsDrawer(
                    preferences: keyboardPrefs,
                    openRequest: $settingsOpenRequest,
                    showsUnlink: session.atMenu == false,
                    onUnlink: {
                        Task { await session.logout(closeMud: true) }
                    },
                    onOpenChange: { open in
                        keyboardSettingsCardChanged(open: open)
                    }
                )
            }
            .overlay {
                ActionSlotsDrawer(
                    store: actionSlots,
                    openRequest: $actionSlotsOpenRequest,
                    logFrame: logGlobalFrame,
                    onOpenChange: { open in
                        actionSlotsCardChanged(open: open)
                    }
                )
            }
            .overlay {
                if deathShown {
                    DeathFlash(opacity: deathOpacity)
                        .ignoresSafeArea()
                }
            }
            .overlay {
                if awardShown {
                    AwardFlash(message: awardText, opacity: awardOpacity)
                        .ignoresSafeArea()
                }
            }
            .background {
                WindowPortraitProbe { portrait in
                    orientationChanged(toPortrait: portrait)
                }
            }
            .accessibilityAction(named: Text("Keyboard settings")) {
                settingsOpenRequest.toggle()
            }
            .accessibilityAction(named: Text("Action buttons")) {
                actionSlotsOpenRequest.toggle()
            }
            .onChange(of: keyboardPrefs.hideInPortrait) { _, _ in
                guard KeyboardHidePreferences.interfaceIsPortrait() else { return }
                applyKeyboardPreference()
            }
            .onChange(of: keyboardPrefs.hideInLandscape) { _, _ in
                guard KeyboardHidePreferences.interfaceIsPortrait() == false else { return }
                applyKeyboardPreference()
            }
            .onAppear {
                adoptLaunchSplash(launchSplashVisible)
            }
            .onChange(of: launchSplashVisible) { _, visible in
                adoptLaunchSplash(visible)
            }
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
                Task { @MainActor in
                    if phase == .background {
                        await session.sceneWentBackground()
                    } else if phase == .active {
                        await session.sceneBecameActive()
                        showCommandKeyboardIfPreferred()
                    }
                }
            }
            .onChange(of: session.atMenu) { _, atMenu in
                if atMenu {
                    releaseCommandKeyboard()
                    actionPanelShown = false
                } else {
                    showCommandKeyboardIfPreferred()
                }
            }
            .onChange(of: session.deathBannerID) { _, id in
                guard id > 0 else { return }
                playDeathFlash()
            }
            .onChange(of: session.progressPulse) { _, pulse in
                guard let pulse else { return }
                enqueueAwards(pulse.messages)
            }
            .onDisappear {
                deathTask?.cancel()
                deathShown = false
                deathOpacity = 0
                stopAwardFlash()
                session.setHilitedWord(nil)
            }
            .task {
                await PushRegistration.request(session: session)
            }
        }
    }

    /// Character name with the latest prompt beside it: "Sin  30h 100m 97v".
    /// A downed condition is bold red: "STUNNED", "DEAD", "INCAPACITATED".
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
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
            if let alarm = session.vitals?.alarm {
                Text(alarm)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Holds `YOU ARE DEAD!` for two seconds, then fades it out.
    private func playDeathFlash() {
        deathTask?.cancel()
        deathShown = true
        withAnimation(.none) {
            deathOpacity = 1
        }
        deathTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard Task.isCancelled == false else { return }
            withAnimation(.easeOut(duration: 0.8)) {
                deathOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(800))
            guard Task.isCancelled == false else { return }
            deathShown = false
        }
    }

    /// Queues `+87 XP!` and `LEVEL!`. Each is held for two seconds, then faded,
    /// the same timing as the death flash. A later award waits its turn.
    private func enqueueAwards(_ messages: [String]) {
        awardQueue.messages.append(contentsOf: messages)
        startAwardPlayback()
    }

    private func startAwardPlayback() {
        guard awardQueue.playing == false else { return }
        guard awardQueue.messages.isEmpty == false else { return }
        awardQueue.playing = true
        awardQueue.generation += 1
        let generation = awardQueue.generation
        awardTask = Task { @MainActor in
            while Task.isCancelled == false, generation == awardQueue.generation {
                guard awardQueue.messages.isEmpty == false else { break }
                let message = awardQueue.messages.removeFirst()
                awardText = message
                awardShown = true
                withAnimation(.none) {
                    awardOpacity = 1
                }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled || generation != awardQueue.generation { return }
                withAnimation(.easeOut(duration: 0.8)) {
                    awardOpacity = 0
                }
                try? await Task.sleep(for: .milliseconds(800))
                if Task.isCancelled || generation != awardQueue.generation { return }
            }
            guard generation == awardQueue.generation else { return }
            // Nothing awaits between the empty check and this assignment, so a
            // line that arrives afterwards finds playing false and starts again.
            awardQueue.playing = false
            awardShown = false
            awardOpacity = 0
        }
    }

    private func stopAwardFlash() {
        awardQueue.generation += 1
        awardQueue.messages.removeAll()
        awardQueue.playing = false
        awardTask?.cancel()
        awardShown = false
        awardOpacity = 0
    }

    /// Same frost as the input bar (`Chrome.barBackground`), extended
    /// into the top safe area the way the input bar extends into the bottom.
    private var topBar: some View {
        sessionHeader
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Chrome.barBackground, ignoresSafeAreaEdges: .top)
            .anchorPreference(key: TopBarBoundsKey.self, value: .bounds) { $0 }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TopBarHeightKey.self, value: proxy.size.height)
                }
            }
    }

    private func sendCommand() async {
        // Hide-on drops the keyboard on the keypress, not after the round trip.
        // Hide-off leaves an already-focused field alone so it does not resign
        // and become again.
        hideCommandKeyboardIfPreferred()
        await session.send()
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
        if keyboardPrefs.hidesKeyboard(isPortrait: KeyboardHidePreferences.interfaceIsPortrait()) == false {
            keepCommandKeyboard()
        }
        let statusBefore = session.status
        await session.send()
        guard session.command.isEmpty else { return }
        if session.status != statusBefore {
            session.command = draft
            return
        }
        hideCommandKeyboardIfPreferred()
    }

    /// Send and Say drop the keyboard only when this orientation's switch is on.
    /// iPhone defaults to landscape on, portrait off. iPad defaults to both off.
    /// Off does not request focus again: the field is already first responder,
    /// and writing that again resigns and becomes, which flickers the keyboard.
    private func hideCommandKeyboardIfPreferred() {
        guard keyboardPrefs.hidesKeyboard(isPortrait: KeyboardHidePreferences.interfaceIsPortrait()) else {
            keepCommandKeyboard()
            return
        }
        releaseCommandKeyboard()
    }

    /// Hide is off and the player has not swiped the keyboard away.
    /// An already-focused field is left focused. A field that has actually
    /// resigned is made first responder once, in this turn, with no second
    /// write after a delay.
    private func keepCommandKeyboard() {
        guard commandKeyboardPaused == false else { return }
        guard session.atMenu == false else { return }
        guard keyboardPrefs.hidesKeyboard(isPortrait: KeyboardHidePreferences.interfaceIsPortrait()) == false else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard keyboardHeld else { return }
        guard commandFocused == false else { return }
        guard restoringKeyboard == false else { return }
        restoringKeyboard = true
        commandFocused = true
        Task { @MainActor in
            restoringKeyboard = false
        }
    }

    /// The player swiped the keyboard away, left the command field for the menu,
    /// or opened a side card.
    private func releaseCommandKeyboard() {
        keyboardOrientationToken += 1
        restoringKeyboard = false
        keyboardHeld = false
        commandFocused = false
    }

    /// The current orientation's switch just moved. Off makes the command
    /// field first responder. On dismisses the keyboard.
    private func applyKeyboardPreference() {
        if keyboardPrefs.hidesKeyboard(isPortrait: KeyboardHidePreferences.interfaceIsPortrait()) {
            releaseCommandKeyboard()
        } else {
            showCommandKeyboardIfPreferred()
        }
    }

    /// The window's portrait bit flipped. The switch for the new orientation
    /// either dismisses the keyboard or makes the command field first responder.
    private func orientationChanged(toPortrait portrait: Bool) {
        guard portrait == KeyboardHidePreferences.interfaceIsPortrait() else { return }
        if keyboardPrefs.hidesKeyboard(isPortrait: portrait) {
            releaseCommandKeyboard()
        } else {
            showCommandKeyboardIfPreferred()
        }
    }

    /// Launch cover is up, or a side card is open. The command
    /// field must not take first responder until those are clear.
    private var commandKeyboardPaused: Bool {
        launchSplashUp || keyboardSettingsOpen || actionSlotsOpen
    }

    /// Copies the launch cover into `launchSplashUp`. While it is up the
    /// command field resigns; when it drops, the orientation's hide switch
    /// decides whether the field becomes first responder.
    private func adoptLaunchSplash(_ visible: Bool) {
        launchSplashUp = visible
        if visible {
            commandFocused = false
        } else {
            showCommandKeyboardIfPreferred()
        }
    }

    /// The left card settled open or closed. Open dismisses the keyboard.
    /// Closed makes the command field first responder only when this
    /// orientation's hide switch is off.
    private func keyboardSettingsCardChanged(open: Bool) {
        keyboardSettingsOpen = open
        if open {
            releaseCommandKeyboard()
        } else {
            showCommandKeyboardIfPreferred()
        }
    }

    /// The right card settled open or closed. Same keyboard rule as the left card.
    private func actionSlotsCardChanged(open: Bool) {
        actionSlotsOpen = open
        if open {
            releaseCommandKeyboard()
        } else {
            showCommandKeyboardIfPreferred()
        }
    }

    /// The switch for whichever orientation is on screen: portrait or landscape.
    /// Off makes the command field first responder and keeps it there.
    /// A swipe-away clears `keyboardHeld`, and that sticks until the next show.
    /// The launch splash and an open side card are not a show.
    private func showCommandKeyboardIfPreferred() {
        guard commandKeyboardPaused == false else { return }
        guard session.atMenu == false else { return }
        guard keyboardPrefs.hidesKeyboard(isPortrait: KeyboardHidePreferences.interfaceIsPortrait()) == false else { return }
        keyboardHeld = true
        // Already up. Requesting focus again restarts the keyboard. Rotation
        // can still clear it after this returns, so the later check runs only
        // if the field actually resigned.
        let token: Int
        if commandFocused {
            token = keyboardOrientationToken
        } else {
            keyboardOrientationToken += 1
            token = keyboardOrientationToken
            commandFocused = true
        }
        Task { @MainActor in
            await Task.yield()
            reassertCommandKeyboard(token: token)
            try? await Task.sleep(for: .milliseconds(350))
            reassertCommandKeyboard(token: token)
        }
    }

    private func reassertCommandKeyboard(token: Int) {
        guard token == keyboardOrientationToken else { return }
        guard commandKeyboardPaused == false else { return }
        guard keyboardHeld, session.atMenu == false else { return }
        guard keyboardPrefs.hidesKeyboard(isPortrait: KeyboardHidePreferences.interfaceIsPortrait()) == false else { return }
        guard commandFocused == false else { return }
        commandFocused = true
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

    /// The slot's verb, plus the hilited word when there is one.
    /// A blank slot does not send. The welcome menu is not a target.
    private func sendSkill(_ action: SkillAction) async {
        guard session.atMenu == false else { return }
        guard let text = action.command(target: session.hilitedWord) else { return }
        await sendDirection(text)
    }

    /// Assigned skills, packed to the bottom of the log, just above the command
    /// bar. The trailing gap stays clear of the right-edge swipe strip: that
    /// strip overlaps the safe area by at most 24 points.
    @ViewBuilder
    private var skillActionButtons: some View {
        if session.atMenu == false {
            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .bottom, spacing: 0) {
                    SkillActionStack(slots: actionSlots.slots, target: session.hilitedWord) { action in
                        Task { await sendSkill(action) }
                    }
                    Color.clear
                        .frame(width: 28, height: 1)
                        .allowsHitTesting(false)
                }
                Color.clear
                    .frame(width: 1, height: 8)
                    .allowsHitTesting(false)
            }
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

    /// Floats on the log. `Chrome.barBackground` is translucent, so lines scroll
    /// under it; the text view's bottom inset keeps the resting line just above
    /// this bar. The keyboard lifts the bar with the safe area. An upward swipe
    /// opens one row of direction commands.
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
                // One line tall, same as the Say/Send targets, so the bar does not
                // take the height proposed to this safe-area inset. Focus is not
                // written again while the field is already first responder.
                CommandLineField(
                    text: $session.command,
                    isFocused: $commandFocused,
                    dismissOnSubmit: keyboardPrefs.hidesKeyboard(
                        isPortrait: KeyboardHidePreferences.interfaceIsPortrait()
                    ),
                    onSubmit: { Task { await sendCommand() } }
                )
                    .onAppear {
                        showCommandKeyboardIfPreferred()
                    }
                    .onChange(of: commandFocused) { _, focused in
                        if commandKeyboardPaused {
                            if focused {
                                commandFocused = false
                            }
                            return
                        }
                        // Becoming first responder holds the keyboard. Losing it
                        // (a long-press selection in the log, or a swipe that
                        // already cleared the hold) stays dismissed. A quick tap
                        // does not clear focus while this orientation keeps the
                        // keyboard. Send calls `keepCommandKeyboard` only when
                        // hide is off.
                        if focused {
                            keyboardHeld = true
                            restoringKeyboard = false
                        }
                    }
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
        .anchorPreference(key: BottomBarBoundsKey.self, value: .bounds) { $0 }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: BottomBarHeightKey.self, value: proxy.size.height)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    let translation = value.translation
                    if translation.height < -30, abs(translation.height) > abs(translation.width) {
                        actionPanelShown.toggle()
                    } else if translation.height > abs(translation.width), translation.height > 0 {
                        releaseCommandKeyboard()
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
/// The log draws under it; the bottom content inset matches this panel's height
/// so the last lines stay above the buttons.
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
        .anchorPreference(key: BottomBarBoundsKey.self, value: .bounds) { $0 }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: BottomBarHeightKey.self, value: proxy.size.height)
            }
        }
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
/// full direction through `session.send()`, the same as typing it. The pressed
/// letter stays lit for a quarter second, then returns to ink.
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

    /// Commands whose letters are lit. A second tap of the same letter restarts a quarter second.
    @State private var litCommands: Set<String> = []
    /// Per-command generation so an earlier timer cannot put the light out early.
    @State private var lightTokens: [String: Int] = [:]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.directions) { direction in
                let lit = litCommands.contains(direction.command)
                Button(direction.label) {
                    light(direction.command)
                    send(direction.command)
                }
                .buttonStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(lit ? Color.white : ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(lit ? 0.42 : 0))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 3)
                }
                .contentShape(Rectangle())
                .accessibilityLabel(direction.command)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    /// Brighten this letter for a quarter second. The button still sends the command.
    private func light(_ command: String) {
        let token = (lightTokens[command] ?? 0) + 1
        lightTokens[command] = token
        withAnimation(.easeOut(duration: 0.08)) {
            // `insert` returns whether the command was new. The closure must
            // stay Void so `withAnimation` does not return that tuple.
            litCommands.insert(command)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard lightTokens[command] == token else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                litCommands.remove(command)
                return
            }
        }
    }
}

/// Assigned skills, stacked above the command bar. Blank slots are absent.
/// The letter is a bold system face. The plate is the bar frost, and a tap
/// lights it the same way a compass letter does: white for a quarter second.
private struct SkillActionStack: View {
    var slots: [SkillAction]
    /// Hilited word, spoken with the verb. The tap reads `hilitedWord` itself.
    var target: String?
    var send: (SkillAction) -> Void

    /// Slots whose letters are lit. A second tap of the same slot restarts a quarter second.
    @State private var litSlots: Set<Int> = []
    /// Per-slot generation so an earlier timer cannot put the light out early.
    @State private var lightTokens: [Int: Int] = [:]

    private struct Row: Identifiable {
        let index: Int
        let action: SkillAction
        let letter: String
        var id: Int { index }
    }

    private var rows: [Row] {
        var packed: [Row] = []
        for (index, action) in slots.enumerated() {
            guard let letter = action.letter else { continue }
            packed.append(Row(index: index, action: action, letter: letter))
        }
        return packed
    }

    var body: some View {
        let packed = rows
        if packed.isEmpty == false {
            ViewThatFits(in: .vertical) {
                column(packed, side: 44, spacing: 4, fontSize: 17)
                column(packed, side: 36, spacing: 2, fontSize: 15)
                column(packed, side: 32, spacing: 2, fontSize: 14)
            }
        }
    }

    private func column(
        _ packed: [Row],
        side: CGFloat,
        spacing: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        VStack(spacing: spacing) {
            ForEach(packed) { row in
                let lit = litSlots.contains(row.index)
                Button {
                    light(row.index)
                    send(row.action)
                } label: {
                    Text(verbatim: row.letter)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(lit ? Color.white : ink)
                        .frame(width: side, height: side)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(lit ? 0.42 : 0))
                                .padding(3)
                        }
                        .background(Chrome.barBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.action.command(target: target) ?? row.action.rawValue)
            }
        }
    }

    /// Brighten this letter for a quarter second. The button still sends the action.
    private func light(_ index: Int) {
        let token = (lightTokens[index] ?? 0) + 1
        lightTokens[index] = token
        withAnimation(.easeOut(duration: 0.08)) {
            litSlots.insert(index)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard lightTokens[index] == token else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                litSlots.remove(index)
            }
        }
    }
}
