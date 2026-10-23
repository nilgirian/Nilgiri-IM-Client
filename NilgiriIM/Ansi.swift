import SwiftUI

enum Ansi {
    private static let ink = Color(white: 0.78)

    static func text(_ raw: String, fontSize: CGFloat, columns: Int) -> Text {
        let wrapped = wrapVisible(raw, columns: columns)
        var result = Text("")
        var color = ink
        var bold = false
        var i = wrapped.startIndex
        var chunk = ""

        func flush() {
            guard chunk.isEmpty == false else { return }
            var t = Text(chunk)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(color)
            if bold {
                t = t.bold()
            }
            result = result + t
            chunk = ""
        }

        while i < wrapped.endIndex {
            if wrapped[i] == "\u{001B}", wrapped.index(after: i) < wrapped.endIndex,
               wrapped[wrapped.index(after: i)] == "[" {
                flush()
                i = wrapped.index(after: i)
                i = wrapped.index(after: i)
                var params = ""
                while i < wrapped.endIndex {
                    let c = wrapped[i]
                    i = wrapped.index(after: i)
                    if c == "m" {
                        applySGR(params, color: &color, bold: &bold)
                        break
                    }
                    if (c >= "0" && c <= "9") || c == ";" {
                        params.append(c)
                    } else {
                        break
                    }
                }
                continue
            }
            chunk.append(wrapped[i])
            i = wrapped.index(after: i)
        }
        flush()
        return result
    }

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
        var out = ""
        var col = 0
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "\n" {
                out.append("\n")
                col = 0
                i = raw.index(after: i)
                continue
            }
            if raw[i] == "\u{001B}", raw.index(after: i) < raw.endIndex,
               raw[raw.index(after: i)] == "[" {
                out.append("\u{001B}[")
                i = raw.index(after: i)
                i = raw.index(after: i)
                while i < raw.endIndex {
                    let c = raw[i]
                    out.append(c)
                    i = raw.index(after: i)
                    if (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") {
                        break
                    }
                }
                continue
            }
            if col == columns {
                out.append("\n")
                col = 0
            }
            out.append(raw[i])
            col += 1
            i = raw.index(after: i)
        }
        return out
    }
}
