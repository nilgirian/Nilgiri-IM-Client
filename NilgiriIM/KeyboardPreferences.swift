import SwiftUI
import UIKit

/// Whether sending a command, or turning the window, dismisses the keyboard.
/// Missing keys keep the device default. iPhone hides in landscape only.
/// iPad keeps the keyboard up in both orientations. Moving a switch writes the key.
final class KeyboardHidePreferences: ObservableObject {
    @Published var hideInPortrait: Bool {
        didSet { UserDefaults.standard.set(hideInPortrait, forKey: Key.portrait) }
    }

    @Published var hideInLandscape: Bool {
        didSet { UserDefaults.standard.set(hideInLandscape, forKey: Key.landscape) }
    }

    private enum Key {
        static let portrait = "im.hideKeyboardPortrait"
        static let landscape = "im.hideKeyboardLandscape"
    }

    init() {
        let defaults = UserDefaults.standard
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        hideInPortrait = Self.stored(defaults, Key.portrait, fallback: false)
        hideInLandscape = Self.stored(defaults, Key.landscape, fallback: phone)
    }

    func hidesKeyboard(isPortrait: Bool) -> Bool {
        isPortrait ? hideInPortrait : hideInLandscape
    }

    /// The window, not the log. The keyboard shortens the log without a rotation.
    static func interfaceIsPortrait() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.keyWindow ?? scene?.windows.first
        if let window, window.bounds.width > 1, window.bounds.height > 1 {
            return window.bounds.height >= window.bounds.width
        }
        return UIScreen.main.bounds.height >= UIScreen.main.bounds.width
    }

    private static func stored(_ defaults: UserDefaults, _ key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}

/// Reports when the window flips between portrait and landscape. The keyboard
/// does not, because this reads the window bounds rather than the log's height.
struct WindowPortraitProbe: UIViewRepresentable {
    var onChange: (Bool) -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: Probe, context: Context) {
        uiView.onChange = onChange
    }

    final class Probe: UIView {
        var onChange: ((Bool) -> Void)?
        private var portrait: Bool?

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publishIfNeeded()
        }

        private func publishIfNeeded() {
            guard let window, window.bounds.width > 1, window.bounds.height > 1 else { return }
            let next = window.bounds.height >= window.bounds.width
            guard next != portrait else { return }
            let first = portrait == nil
            portrait = next
            guard first == false else { return }
            let callback = onChange
            DispatchQueue.main.async {
                callback?(next)
            }
        }
    }
}

/// Dark grey card on the left edge. A rightward swipe from that edge opens it.
/// The two switches are the portrait and landscape keyboard prefs.
struct KeyboardSettingsDrawer: View {
    @ObservedObject var preferences: KeyboardHidePreferences
    /// Toggled by the accessibility action. Each change opens the card.
    @Binding var openRequest: Bool

    /// Dark grey, see-through, so the log shows behind the card.
    private static let menuGrey = Color(white: 0.22).opacity(0.55)

    @State private var travel: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var ignoreDrag = false

    var body: some View {
        GeometryReader { geo in
            let width = min(300, geo.size.width * 0.84)
            let insets = Self.windowInsets
            let edge = max(24, insets.left + 20)
            let progress = width > 0 ? min(1, max(0, travel / width)) : 0
            ZStack(alignment: .leading) {
                // Absent while closed, so the full-screen reader does not eat
                // taps meant for the log or the command field.
                if travel > 0 {
                    // Dim only the screen beside the card. The grey itself is
                    // translucent, so the log under the card stays visible.
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: travel)
                            .allowsHitTesting(false)
                        Color.black.opacity(0.4 * progress)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.22)) {
                                    travel = 0
                                }
                            }
                            .simultaneousGesture(pan(width: width, edge: edge, fromEdgeOnly: false))
                    }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                    card(width: width, insets: insets)
                        .offset(x: travel - width)
                        .accessibilityHidden(travel < width * 0.8)
                        .simultaneousGesture(pan(width: width, edge: edge, fromEdgeOnly: false))
                }

                // The clear row is full width. Only the left strip takes the swipe,
                // so the rest of the screen still scrolls and accepts commands.
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: edge)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(pan(width: width, edge: edge, fromEdgeOnly: true))
                        .allowsHitTesting(travel < 8 || dragOrigin != nil)
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
                .accessibilityHidden(true)
            }
            .coordinateSpace(name: Self.space)
            .onChange(of: openRequest) { _, _ in
                withAnimation(.easeOut(duration: 0.22)) {
                    travel = width
                }
            }
        }
        .ignoresSafeArea()
    }

    private static let space = "keyboardDrawer"

    /// The drawer's geometry reader is pushed under the safe area, so its own
    /// insets are not the notch. The window still has them.
    private static var windowInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow?.safeAreaInsets ?? scene?.windows.first?.safeAreaInsets ?? .zero
    }

    private func card(width: CGFloat, insets: UIEdgeInsets) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Keyboard")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(white: 0.62))
            Toggle("Hide keyboard in portrait mode", isOn: $preferences.hideInPortrait)
            Toggle("Hide keyboard in landscape mode", isOn: $preferences.hideInLandscape)
        }
        .font(.system(size: 17))
        .toggleStyle(.switch)
        .tint(Color(white: 0.78))
        .foregroundStyle(Color(white: 0.92))
        .padding(.leading, insets.left + 20)
        .padding(.trailing, 18)
        .padding(.top, insets.top + 24)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Self.menuGrey)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 18,
                topTrailingRadius: 18,
                style: .continuous
            )
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 14, x: 8, y: 0)
    }

    /// Opens from the left edge, or follows a finger that is already dragging the card.
    /// A vertical move that starts while the card is closed is left alone.
    private func pan(width: CGFloat, edge: CGFloat, fromEdgeOnly: Bool) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if ignoreDrag { return }
                if dragOrigin == nil {
                    let translation = value.translation
                    guard hypot(translation.width, translation.height) >= 10 else { return }
                    if fromEdgeOnly && travel < 1 {
                        let fromEdge = value.startLocation.x <= edge
                        let opening = translation.width > 0 && abs(translation.width) > abs(translation.height)
                        if fromEdge == false || opening == false {
                            ignoreDrag = true
                            return
                        }
                    }
                    dragOrigin = travel
                }
                guard let dragOrigin else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                let next = min(width, max(0, dragOrigin + value.translation.width))
                withTransaction(transaction) {
                    travel = next
                }
            }
            .onEnded { value in
                let origin = dragOrigin
                dragOrigin = nil
                ignoreDrag = false
                guard let origin else { return }
                let predicted = origin + value.predictedEndTranslation.width
                withAnimation(.easeOut(duration: 0.22)) {
                    travel = predicted > width * 0.45 ? width : 0
                }
            }
    }
}
