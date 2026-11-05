import Foundation
import SwiftUI
import UIKit

enum Ansi {
    /// Terminal ink. Also the colour after ESC[0m / ESC[m.
    private static let ink = Color(white: 0.78)
    /// Light blue so a link stays readable on the black transcript.
    private static let linkInk = Color(red: 0.55, green: 0.82, blue: 1)
    private static let linkUI = UIColor(red: 0.55, green: 0.82, blue: 1, alpha: 1)

    /// Colour and bold carried from one line to the next, the way a terminal
    /// keeps SGR state. The line text itself is never changed.
    struct State: Equatable {
        var color: Color
        var uiColor: UIColor
        var bold: Bool

        static let initial = State(
            color: Color(white: 0.78),
            uiColor: UIColor(white: 0.78, alpha: 1),
            bold: false
        )
    }

    /// Column breaks inserted for display. The MUD string is not rewritten.
    enum Wrap: Equatable {
        /// Break at the column, including inside a word.
        case columns
        /// Enlarged say, gossip, and the other communication lines. A word of
        /// fewer than 11 letters that would cross the column moves onto the
        /// next line whole, and every line after the first is indented two spaces.
        case communication
    }

    /// `initial` defaults to a reset terminal, so `text(_:fontSize:columns:)` is unchanged.
    static func text(_ raw: String, fontSize: CGFloat, columns: Int, initial: State = .initial) -> Text {
        swiftText(runs(raw, columns: columns, initial: initial), fontSize: fontSize)
    }

    /// The same characters, colours, and links as `text`, for the selectable transcript.
    /// Wrap newlines are in the string because they are on screen; they are not part of a URL.
    static func attributed(
        _ raw: String,
        fontSize: CGFloat,
        columns: Int,
        initial: State = .initial,
        wrap: Wrap = .columns
    ) -> NSAttributedString {
        let pieces = runs(raw, columns: columns, initial: initial, wrap: wrap)
        let result = NSMutableAttributedString()
        for piece in pieces {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(
                    ofSize: fontSize,
                    weight: piece.bold ? .bold : .regular
                ),
                .foregroundColor: piece.link == nil ? piece.uiColor : linkUI
            ]
            if let link = piece.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = linkUI
            }
            result.append(NSAttributedString(string: piece.text, attributes: attributes))
        }
        return result
    }

    /// End state after parsing one raw line. Wrap newlines are not part of the parse.
    static func endingState(parsing raw: String, starting: State = .initial) -> State {
        var color = starting.color
        var uiColor = starting.uiColor
        var bold = starting.bold
        var index = raw.startIndex
        while index < raw.endIndex {
            switch readCSI(raw, index: &index) {
            case .notCSI:
                index = raw.index(after: index)
            case .sequence(let sgr):
                if let sgr {
                    applySGR(sgr, color: &color, uiColor: &uiColor, bold: &bold)
                }
            }
        }
        return State(color: color, uiColor: uiColor, bold: bold)
    }

    private struct Run {
        var text: String
        var color: Color
        var uiColor: UIColor
        var bold: Bool
        var link: URL?
    }

    /// Display runs for one raw line. Characters match `layout`: ANSI is not shown,
    /// and a column-cap newline is in the run but not in the link.
    private static func runs(_ raw: String, columns: Int, initial: State, wrap: Wrap = .columns) -> [Run] {
        let laid = layout(raw, columns: columns, wrap: wrap)
        let spans = linkSpans(in: raw)
        let wrapped = laid.text
        var produced: [Run] = []
        var color = initial.color
        var uiColor = initial.uiColor
        var bold = initial.bold
        var index = wrapped.startIndex
        var offset = 0
        var visibleIndex = 0
        var spanCursor = 0
        var chunk = ""
        var chunkColor = color
        var chunkUI = uiColor
        var chunkBold = bold
        var chunkLink: URL?

        func flush() {
            guard chunk.isEmpty == false else { return }
            produced.append(Run(
                text: chunk,
                color: chunkColor,
                uiColor: chunkUI,
                bold: chunkBold,
                link: chunkLink
            ))
            chunk = ""
        }

        func appendPiece(_ character: Character, link: URL?) {
            let breakChunk = chunk.isEmpty == false && (
                link != chunkLink
                    || bold != chunkBold
                    || (link == nil && color != chunkColor)
            )
            if breakChunk {
                flush()
            }
            if chunk.isEmpty {
                chunkColor = color
                chunkUI = uiColor
                chunkBold = bold
                chunkLink = link
            }
            chunk.append(character)
        }

        while index < wrapped.endIndex {
            let start = index
            if case .sequence(let sgr) = readCSI(wrapped, index: &index) {
                offset += wrapped.distance(from: start, to: index)
                if let sgr {
                    flush()
                    applySGR(sgr, color: &color, uiColor: &uiColor, bold: &bold)
                }
                continue
            }
            let character = wrapped[index]
            if laid.wrapBreaks.contains(offset) {
                // A column-cap break, or the two-space continuation indent, is
                // not a character of the unwrapped line, and it stays out of the URL.
                appendPiece(character, link: nil)
            } else if character == "\n" {
                appendPiece("\n", link: nil)
                visibleIndex += 1
            } else {
                let link = linkURL(at: visibleIndex, spans: spans, cursor: &spanCursor)
                appendPiece(character, link: link)
                visibleIndex += 1
            }
            offset += 1
            index = wrapped.index(after: index)
        }
        flush()
        return produced
    }

    private static func swiftText(_ pieces: [Run], fontSize: CGFloat) -> Text {
        var result = Text("")
        for piece in pieces {
            if let link = piece.link {
                var attr = AttributedString(piece.text)
                attr.font = .system(
                    size: fontSize,
                    weight: piece.bold ? .bold : .regular,
                    design: .monospaced
                )
                attr.foregroundColor = linkInk
                attr.underlineStyle = .single
                attr.link = link
                result = result + Text(attr)
            } else {
                var text = Text(piece.text)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(piece.color)
                if piece.bold {
                    text = text.bold()
                }
                result = result + text
            }
        }
        return result
    }

    private struct LinkSpan {
        var lower: Int
        var upper: Int
        var url: URL
    }

    /// Links on the ANSI-stripped line, before `layout` inserts 80-column breaks.
    private static func linkSpans(in raw: String) -> [LinkSpan] {
        guard let linkDetector else { return [] }
        // A colour code can sit inside the scheme, so a line with no ESC and no
        // scheme has nothing to detect. The detector still runs on the stripped text.
        if raw.contains("\u{001B}") == false,
           raw.range(of: "http", options: .caseInsensitive) == nil,
           raw.range(of: "www.", options: .caseInsensitive) == nil {
            return []
        }
        let visible = strippingCSI(raw)
        guard visible.isEmpty == false else { return [] }
        if visible.range(of: "http", options: .caseInsensitive) == nil,
           visible.range(of: "www.", options: .caseInsensitive) == nil {
            return []
        }
        let full = NSRange(visible.startIndex..., in: visible)
        var spans: [LinkSpan] = []
        for match in linkDetector.matches(in: visible, options: [], range: full) {
            guard let range = Range(match.range, in: visible) else { continue }
            let matched = String(visible[range])
            guard matched.isEmpty == false else { continue }
            guard matched.contains(where: { $0.isNewline || $0.isWhitespace }) == false else { continue }
            let folded = matched.lowercased()
            let target: String
            if folded.hasPrefix("https://") || folded.hasPrefix("http://") {
                target = matched
            } else if folded.hasPrefix("www.") {
                target = "https://" + matched
            } else {
                continue
            }
            guard let url = URL(string: target) else { continue }
            let lower = visible.distance(from: visible.startIndex, to: range.lowerBound)
            let upper = visible.distance(from: visible.startIndex, to: range.upperBound)
            guard lower < upper else { continue }
            spans.append(LinkSpan(lower: lower, upper: upper, url: url))
        }
        spans.sort { $0.lower < $1.lower }
        return spans
    }

    private static func linkURL(at index: Int, spans: [LinkSpan], cursor: inout Int) -> URL? {
        while cursor < spans.count, spans[cursor].upper <= index {
            cursor += 1
        }
        guard cursor < spans.count else { return nil }
        let span = spans[cursor]
        guard index >= span.lower, index < span.upper else { return nil }
        return span.url
    }

    private static func strippingCSI(_ raw: String) -> String {
        var out = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if case .sequence = readCSI(raw, index: &index) {
                continue
            }
            out.append(raw[index])
            index = raw.index(after: index)
        }
        return out
    }

    private enum CSIRead {
        case notCSI
        /// `sgr` is set when the sequence ends in `m` (including empty ESC[m).
        case sequence(sgr: String?)
    }

    /// The index just after a CSI starting at `index`, matching the bytes
    /// `layout` copies without giving them a column. Nil when `index` is not a CSI.
    private static func indexAfterCSI(_ raw: String, from index: String.Index) -> String.Index? {
        guard raw[index] == "\u{001B}" else { return nil }
        let bracket = raw.index(after: index)
        guard bracket < raw.endIndex, raw[bracket] == "[" else { return nil }
        var cursor = raw.index(after: bracket)
        while cursor < raw.endIndex {
            let character = raw[cursor]
            cursor = raw.index(after: cursor)
            if (character >= "A" && character <= "Z") || (character >= "a" && character <= "z") {
                break
            }
        }
        return cursor
    }

    /// Consumes a CSI at `index`, or reports that `index` is not one.
    /// The cursor only moves when a sequence was consumed.
    private static func readCSI(_ raw: String, index: inout String.Index) -> CSIRead {
        guard raw[index] == "\u{001B}" else { return .notCSI }
        let bracket = raw.index(after: index)
        guard bracket < raw.endIndex, raw[bracket] == "[" else { return .notCSI }
        var cursor = raw.index(after: bracket)
        var params = ""
        var isSGR = false
        while cursor < raw.endIndex {
            let character = raw[cursor]
            cursor = raw.index(after: cursor)
            if character == "m" {
                isSGR = true
                break
            }
            if (character >= "0" && character <= "9") || character == ";" {
                params.append(character)
            } else {
                break
            }
        }
        index = cursor
        return .sequence(sgr: isSGR ? params : nil)
    }

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static func applySGR(
        _ params: String,
        color: inout Color,
        uiColor: inout UIColor,
        bold: inout Bool
    ) {
        func take(_ next: Color, _ ui: UIColor) {
            color = next
            uiColor = ui
        }
        if params.isEmpty || params == "0" {
            take(ink, UIColor(white: 0.78, alpha: 1))
            bold = false
            return
        }
        var bright = bold
        for part in params.split(separator: ";") {
            switch String(part) {
            case "0":
                take(ink, UIColor(white: 0.78, alpha: 1))
                bold = false
                bright = false
            case "1":
                bold = true
                bright = true
            case "22":
                bold = false
                bright = false
            case "30":
                take(
                    Color(white: bright ? 0.45 : 0.35),
                    UIColor(white: bright ? 0.45 : 0.35, alpha: 1)
                )
            case "31":
                if bright {
                    take(Color(red: 1, green: 0.35, blue: 0.35), UIColor(red: 1, green: 0.35, blue: 0.35, alpha: 1))
                } else {
                    take(Color(red: 0.85, green: 0.22, blue: 0.18), UIColor(red: 0.85, green: 0.22, blue: 0.18, alpha: 1))
                }
            case "32":
                if bright {
                    take(Color(red: 0.45, green: 1, blue: 0.4), UIColor(red: 0.45, green: 1, blue: 0.4, alpha: 1))
                } else {
                    take(Color(red: 0.25, green: 0.75, blue: 0.28), UIColor(red: 0.25, green: 0.75, blue: 0.28, alpha: 1))
                }
            case "33":
                if bright {
                    take(Color(red: 1, green: 1, blue: 0.4), UIColor(red: 1, green: 1, blue: 0.4, alpha: 1))
                } else {
                    take(Color(red: 0.85, green: 0.7, blue: 0.15), UIColor(red: 0.85, green: 0.7, blue: 0.15, alpha: 1))
                }
            case "34":
                if bright {
                    take(Color(red: 0.5, green: 0.7, blue: 1), UIColor(red: 0.5, green: 0.7, blue: 1, alpha: 1))
                } else {
                    take(Color(red: 0.3, green: 0.45, blue: 0.95), UIColor(red: 0.3, green: 0.45, blue: 0.95, alpha: 1))
                }
            case "35":
                if bright {
                    take(Color(red: 1, green: 0.5, blue: 1), UIColor(red: 1, green: 0.5, blue: 1, alpha: 1))
                } else {
                    take(Color(red: 0.8, green: 0.3, blue: 0.8), UIColor(red: 0.8, green: 0.3, blue: 0.8, alpha: 1))
                }
            case "36":
                if bright {
                    take(Color(red: 0.4, green: 1, blue: 1), UIColor(red: 0.4, green: 1, blue: 1, alpha: 1))
                } else {
                    take(Color(red: 0.25, green: 0.75, blue: 0.8), UIColor(red: 0.25, green: 0.75, blue: 0.8, alpha: 1))
                }
            case "37":
                if bright {
                    take(Color.white, UIColor.white)
                } else {
                    take(ink, UIColor(white: 0.78, alpha: 1))
                }
            case "39":
                take(ink, UIColor(white: 0.78, alpha: 1))
            default:
                break
            }
        }
    }

    static func wrapVisible(_ raw: String, columns: Int) -> String {
        layout(raw, columns: columns).text
    }

    /// `wrapBreaks` are offsets of characters this inserts. Newlines that were
    /// already in `raw` are not listed, so a URL can be found on the unwrapped
    /// line and those breaks stay out of it.
    private static func layout(
        _ raw: String,
        columns: Int,
        wrap: Wrap = .columns
    ) -> (text: String, wrapBreaks: Set<Int>) {
        switch wrap {
        case .columns:
            return layoutColumns(raw, columns: columns)
        case .communication:
            return layoutCommunication(raw, columns: columns)
        }
    }

    /// Break at the column, including inside a word.
    private static func layoutColumns(_ raw: String, columns: Int) -> (text: String, wrapBreaks: Set<Int>) {
        var out = ""
        var wrapBreaks = Set<Int>()
        var outCount = 0
        var col = 0
        var index = raw.startIndex

        func push(_ character: Character, wrapBreak: Bool = false) {
            if wrapBreak {
                wrapBreaks.insert(outCount)
            }
            out.append(character)
            outCount += 1
        }

        while index < raw.endIndex {
            if raw[index] == "\n" {
                push("\n")
                col = 0
                index = raw.index(after: index)
                continue
            }
            if raw[index] == "\u{001B}", raw.index(after: index) < raw.endIndex,
               raw[raw.index(after: index)] == "[" {
                push("\u{001B}")
                push("[")
                index = raw.index(after: index)
                index = raw.index(after: index)
                while index < raw.endIndex {
                    let character = raw[index]
                    push(character)
                    index = raw.index(after: index)
                    if (character >= "A" && character <= "Z") || (character >= "a" && character <= "z") {
                        break
                    }
                }
                continue
            }
            if col == columns {
                push("\n", wrapBreak: true)
                col = 0
            }
            push(raw[index])
            col += 1
            index = raw.index(after: index)
        }
        return (out, wrapBreaks)
    }

    /// Enlarged communication. A word is the visible columns up to the next
    /// space, tab, or newline; ANSI is copied and takes no column. Fewer than
    /// 11 letters means that run is shorter than 11 columns. Such a word is
    /// moved whole when it would cross the column and still fits on a
    /// continuation line (the line is two spaces shorter). A longer word
    /// still breaks at the column, so a long token does not leave a hole.
    /// Lines after the first start with two spaces. Inserted newlines and
    /// those spaces are the only characters added; every MUD character is kept.
    private static func layoutCommunication(
        _ raw: String,
        columns: Int
    ) -> (text: String, wrapBreaks: Set<Int>) {
        let width = max(columns, 1)
        let indent = min(2, width - 1)
        let shortWord = 11
        var out = ""
        var wrapBreaks = Set<Int>()
        var outCount = 0
        var col = 0
        var indentPending = false
        var lineHasContent = false
        var atWordBoundary = true
        var index = raw.startIndex

        func push(_ character: Character, synthetic: Bool = false) {
            if synthetic {
                wrapBreaks.insert(outCount)
            }
            out.append(character)
            outCount += 1
        }

        func breakForWrap() {
            push("\n", synthetic: true)
            col = 0
            indentPending = indent > 0
            lineHasContent = false
        }

        func flushIndent() {
            guard indentPending else { return }
            indentPending = false
            var remaining = indent
            while remaining > 0 {
                push(" ", synthetic: true)
                remaining -= 1
                col += 1
            }
        }

        /// The next visible character, skipping CSI. Nil at the end of the line.
        func nextVisible(from start: String.Index) -> Character? {
            var cursor = start
            while cursor < raw.endIndex {
                if let next = indexAfterCSI(raw, from: cursor) {
                    cursor = next
                    continue
                }
                return raw[cursor]
            }
            return nil
        }

        func visibleWordLength(from start: String.Index) -> Int {
            var cursor = start
            var count = 0
            while cursor < raw.endIndex {
                if let next = indexAfterCSI(raw, from: cursor) {
                    cursor = next
                    continue
                }
                let character = raw[cursor]
                if character == "\n" || character == " " || character == "\t" {
                    break
                }
                count += 1
                cursor = raw.index(after: cursor)
            }
            return count
        }

        while index < raw.endIndex {
            if raw[index] == "\n" {
                push("\n")
                col = 0
                indentPending = indent > 0
                lineHasContent = false
                atWordBoundary = true
                index = raw.index(after: index)
                continue
            }
            if let next = indexAfterCSI(raw, from: index) {
                while index < next {
                    push(raw[index])
                    index = raw.index(after: index)
                }
                continue
            }

            let character = raw[index]
            let whitespace = character == " " || character == "\t"
            if whitespace == false, atWordBoundary, lineHasContent {
                let length = visibleWordLength(from: index)
                let remaining = width - col
                if length > 0, length < shortWord, length > remaining, length <= width - indent {
                    breakForWrap()
                }
            }

            // A separator that falls on the column stays at the end of this
            // line. Putting it after the indent would show as a third space.
            // It is only moved aside when more visible text follows; a trailing
            // run does not grow an extra blank line.
            if col == width, whitespace {
                var cursor = index
                while cursor < raw.endIndex, raw[cursor] == " " || raw[cursor] == "\t" {
                    cursor = raw.index(after: cursor)
                }
                let more: Bool
                if let next = nextVisible(from: cursor) {
                    more = next != "\n"
                } else {
                    more = false
                }
                while index < cursor {
                    push(raw[index])
                    index = raw.index(after: index)
                }
                atWordBoundary = true
                lineHasContent = true
                if more {
                    breakForWrap()
                }
                continue
            }

            if col == width {
                breakForWrap()
            }
            flushIndent()
            push(character)
            col += 1
            lineHasContent = true
            atWordBoundary = whitespace
            index = raw.index(after: index)
        }
        return (out, wrapBreaks)
    }
}
