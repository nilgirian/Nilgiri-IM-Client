import SwiftUI
import UIKit

/// Frost shared by the in-game bars and the character-creation chrome.
enum Chrome {
    /// Half-strength ultra-thin material for the name bar and the command bar.
    static let barOpacity = 0.5

    static let barBackground = AnyShapeStyle(Material.ultraThin.opacity(barOpacity))

    /// White laid over that frost on a play-screen hot button (a compass
    /// letter and an action plate). 0.20 is a fifth lighter than the bare
    /// frost, short of a wash. Both buttons use this one resting fill.
    static let hotButtonPlateLighten = 0.20

    static let hotButtonPlate = Color.white.opacity(hotButtonPlateLighten)

    /// Press light. White at 0.42 still sits well above the 0.20 rest, so a
    /// tap reads as a flash rather than another shade of the plate.
    static let hotButtonFlashOpacity = 0.42

    static let hotButtonFlash = Color.white.opacity(hotButtonFlashOpacity)
}

/// Matrix Mode. The left-edge card writes it. Missing key stays off.
/// Display only: callers recolour what they paint and leave every string alone.
final class MatrixMode: ObservableObject {
    static let shared = MatrixMode()

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            storeEnabled()
        }
    }

    private enum Key {
        static let enabled = CharacterMenuSwitch.matrixMode
    }

    /// Character whose key is loaded. A switch reads that character's value.
    private var loadedFor = ""
    /// False while applying a load or a cloud value, so the default is not
    /// stored for a character who has never moved the switch.
    private var stores = false
    private var appliedObserver: NSObjectProtocol?

    private init() {
        enabled = Self.read()
        loadedFor = CharacterPreferenceScope.key
        stores = true
        appliedObserver = NotificationCenter.default.addObserver(
            forName: .imMenuSettingsApplied,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload(force: true)
        }
    }

    deinit {
        if let appliedObserver {
            NotificationCenter.default.removeObserver(appliedObserver)
        }
    }

    /// Loads Matrix Mode for the character currently in scope.
    /// A missing key stays off, which is the fresh-install default.
    /// `force` rereads after iCloud applied a newer value for this same character.
    func reload(force: Bool = false) {
        let key = CharacterPreferenceScope.key
        guard force || key != loadedFor else { return }
        loadedFor = key
        let next = Self.read()
        guard enabled != next else { return }
        stores = false
        enabled = next
        stores = true
    }

    /// A player edit. Loading another character must not create their key.
    private func storeEnabled() {
        guard stores else { return }
        UserDefaults.standard.set(enabled, forKey: Self.scopedKey)
        NotificationCenter.default.post(name: .imMenuSettingsEdited, object: nil)
    }

    private static var scopedKey: String {
        CharacterPreferenceScope.storageKey(Key.enabled)
    }

    private static func read() -> Bool {
        let key = scopedKey
        guard UserDefaults.standard.object(forKey: key) != nil else { return false }
        return UserDefaults.standard.bool(forKey: key)
    }
}

/// A green of similar brightness. Off returns the colour unchanged, so the
/// normal palette is the same object the caller already had.
enum MatrixShade {
    static func display(_ color: Color, enabled: Bool) -> Color {
        guard enabled else { return color }
        return Color(uiColor: display(UIColor(color), enabled: true))
    }

    static func display(_ color: UIColor, enabled: Bool) -> UIColor {
        guard enabled else { return color }
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return shade(red: red, green: green, blue: blue, alpha: alpha)
        }
        var white: CGFloat = 0
        if resolved.getWhite(&white, alpha: &alpha) {
            return shade(red: white, green: white, blue: white, alpha: alpha)
        }
        if let components = resolved.cgColor.components, components.isEmpty == false {
            let alpha = resolved.cgColor.alpha
            if components.count >= 3 {
                return shade(red: components[0], green: components[1], blue: components[2], alpha: alpha)
            }
            return shade(red: components[0], green: components[0], blue: components[0], alpha: alpha)
        }
        return color
    }

    /// Rec. 709 brightness of the gamma-encoded channels, then that value as
    /// the green channel. A smaller share of the same brightness goes to red
    /// and blue, so the hue stays green and a brighter source stays brighter.
    /// Output luminance tracks the input (about three quarters of it) across
    /// the whole range, including white, instead of clamping to one green.
    private static func shade(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> UIColor {
        let y = min(1, max(0, 0.2126 * red + 0.7152 * green + 0.0722 * blue))
        return UIColor(red: y * 0.18, green: y, blue: y * 0.08, alpha: alpha)
    }
}

extension Color {
    /// Green of similar brightness while Matrix Mode is on.
    var matrix: Color {
        MatrixShade.display(self, enabled: MatrixMode.shared.enabled)
    }
}

extension View {
    /// Prominent buttons paint their label white. Matrix Mode turns that white
    /// green and leaves the button untouched while the mode is off.
    @ViewBuilder
    func matrixProminentText() -> some View {
        if MatrixMode.shared.enabled {
            foregroundStyle(Color.white.matrix)
        } else {
            self
        }
    }

    /// Link-style and toolbar buttons take their colour from the tint.
    /// Matrix Mode turns that label green and leaves the control alone when off.
    @ViewBuilder
    func matrixAccentText() -> some View {
        if MatrixMode.shared.enabled {
            tint(Color.white.matrix)
        } else {
            self
        }
    }
}
