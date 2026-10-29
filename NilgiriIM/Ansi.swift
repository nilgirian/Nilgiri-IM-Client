import Foundation
import SwiftUI

enum Ansi {
    /// Terminal ink. Also the colour after ESC[0m / ESC[m.
    private static let ink = Color(white: 0.78)
    /// Light blue so a link stays readable on the black transcript.
    private static let linkInk = Color(red: 0.55, green: 0.82, blue: 1)

    /// Colour and bold carried from one line to the next, the way a terminal
    /// keeps SGR state. The line text itself is never changed.
    struct State: Equatable {
        var color: Color
        var bold: Bool

        static let initial = State(color: Color(white: 0.78), bold: false)
    }

    /// `initial` defaults to a reset terminal, so `text(_:fontSize:columns:)` is unchanged.
    static func text(_ raw: String, fontSize: CGFloat, columns: Int, initial: State = .initial) -> Text {
        let laid = layout(raw, columns: columns)
        let spans = linkSpans(in: raw)
        return render(
            laid.text,
            fontSize: fontSize,
            initial: initial,
            wrapBreaks: laid.wrapBreaks,
            spans: spans
        )
    }

    /// End state after parsing one raw line. Wrap newlines are not part of the parse.
    static func endingState(parsing raw: String, starting: State = .initial) -> State {
        var color = starting.color
        var bold = starting.bold
        var index = raw.startIndex
        while index < raw.endIndex {
            switch readCSI(raw, index: &index) {
            case .notCSI:
                index = raw.index(after: index)
            case .sequence(let sgr):
                if let sgr {
                    applySGR(sgr, color: &color, bold: &bold)
                }
            }
        }
        return State(color: color, bold: bold)
    }

    private static func render(
        _ wrapped: String,
        fontSize: CGFloat,
        initial: State,
        wrapBreaks: Set<Int>,
        spans: [LinkSpan]
    ) -> Text {
        var result = Text("")
        var color = initial.color
        var bold = initial.bold
        var index = wrapped.startIndex
        var offset = 0
        var visibleIndex = 0
        var spanCursor = 0
        var chunk = ""
        var chunkColor = color
        var chunkBold = bold
        var chunkLink: URL?

        func flush() {
            guard chunk.isEmpty == false else { return }
            if let chunkLink {
                var attr = AttributedString(chunk)
                attr.font = .system(
                    size: fontSize,
                    weight: chunkBold ? .bold : .regular,
                    design: .monospaced
                )
                attr.foregroundColor = linkInk
                attr.underlineStyle = .single
                attr.link = chunkLink
                result = result + Text(attr)
            } else {
                var piece = Text(chunk)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(chunkColor)
                if chunkBold {
                    piece = piece.bold()
                }
                result = result + piece
            }
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
                    applySGR(sgr, color: &color, bold: &bold)
                }
                continue
            }
            let character = wrapped[index]
            if character == "\n" {
                let inserted = wrapBreaks.contains(offset)
                // Never part of the link target. A column-cap break is not a
                // character of the unwrapped line, so it does not advance the
                // visible index the detector used.
                appendPiece("\n", link: nil)
                if inserted == false {
                    visibleIndex += 1
                }
            } else {
                let link = linkURL(at: visibleIndex, spans: spans, cursor: &spanCursor)
                appendPiece(character, link: link)
                visibleIndex += 1
            }
            offset += 1
            index = wrapped.index(after: index)
        }
        flush()
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

    private static func applySGR(_ params: String, color: inout Color, bold: inout Bool) {
        if params.isEmpty || params == "0" {
            color = ink
            bold = false
            return
        }
        var bright = bold
        for part in params.split(separator: ";") {
            switch String(part) {
            case "0":
                color = ink
                bold = false
                bright = false
            case "1":
                bold = true
                bright = true
            case "22":
                bold = false
                bright = false
            case "30": color = Color(white: bright ? 0.45 : 0.35)
            case "31": color = bright ? Color(red: 1, green: 0.35, blue: 0.35) : Color(red: 0.85, green: 0.22, blue: 0.18)
            case "32": color = bright ? Color(red: 0.45, green: 1, blue: 0.4) : Color(red: 0.25, green: 0.75, blue: 0.28)
            case "33": color = bright ? Color(red: 1, green: 1, blue: 0.4) : Color(red: 0.85, green: 0.7, blue: 0.15)
            case "34": color = bright ? Color(red: 0.5, green: 0.7, blue: 1) : Color(red: 0.3, green: 0.45, blue: 0.95)
            case "35": color = bright ? Color(red: 1, green: 0.5, blue: 1) : Color(red: 0.8, green: 0.3, blue: 0.8)
            case "36": color = bright ? Color(red: 0.4, green: 1, blue: 1) : Color(red: 0.25, green: 0.75, blue: 0.8)
            case "37": color = bright ? Color.white : ink
            case "39": color = ink
            default: break
            }
        }
    }

    static func wrapVisible(_ raw: String, columns: Int) -> String {
        layout(raw, columns: columns).text
    }

    /// Same wrap as before. `wrapBreaks` are character offsets of newlines this
    /// inserts at the column cap. Newlines that were already in `raw` are not listed,
    /// so a URL can be found on the unwrapped line and those breaks stay out of it.
    private static func layout(_ raw: String, columns: Int) -> (text: String, wrapBreaks: Set<Int>) {
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
}
