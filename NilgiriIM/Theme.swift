import SwiftUI

/// Frost shared by the in-game bars and the character-creation chrome.
enum Chrome {
    /// Half-strength ultra-thin material for the name bar and the command bar.
    static let barOpacity = 0.5

    static let barBackground = AnyShapeStyle(Material.ultraThin.opacity(barOpacity))
}
