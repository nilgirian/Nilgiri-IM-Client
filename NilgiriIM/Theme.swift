import SwiftUI

/// Frost shared by the in-game bars and the character-creation chrome.
enum Chrome {
    /// Half-strength ultra-thin material. The Unlink control stays lighter
    /// than this and does not use it.
    static let barOpacity = 0.5

    static let barBackground = AnyShapeStyle(Material.ultraThin.opacity(barOpacity))
}
