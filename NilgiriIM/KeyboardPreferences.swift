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

    /// Hide switch for the window on screen. The drawer writes the same keys.
    static func hidesKeyboardForCurrentInterface() -> Bool {
        let defaults = UserDefaults.standard
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        if interfaceIsPortrait() {
            return stored(defaults, Key.portrait, fallback: false)
        }
        return stored(defaults, Key.landscape, fallback: phone)
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
/// Portrait and landscape keyboard switches and Matrix Mode stay at the top.
/// Report issues, the newbie guide, and About Nilgiri IM open in Safari.
/// Unlink, while the player is in the game, sits at the bottom of the card.
struct KeyboardSettingsDrawer: View {
    @ObservedObject var preferences: KeyboardHidePreferences
    @ObservedObject var matrixMode: MatrixMode
    /// Toggled by the accessibility action. Each change opens the card.
    @Binding var openRequest: Bool
    /// False on the welcome menu. Unlink is an in-game control.
    var showsUnlink: Bool
    /// Closes the MUD session. The caller owns the logout.
    var onUnlink: () -> Void
    /// The card settled open or closed. Not called during the drag, so a swipe
    /// that slides back shut does not dismiss the keyboard and bring it back.
    var onOpenChange: (Bool) -> Void

    /// Dark grey, see-through, so the log shows behind the card.
    private static let menuGrey = Color(white: 0.22).opacity(0.55)

    private static let reportIssuesURL = "https://github.com/nilgirian/Nilgiri-IM-Client/issues/new/choose"
    private static let newbieGuideURL = "https://nilgiri.net/nilgiri/newbie-strategy"
    private static let aboutNilgiriIMURL = "https://nilgiri.net/nilgiri/im_client"

    @State private var travel: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var ignoreDrag = false
    /// Last settled open bit already reported through `onOpenChange`.
    @State private var cardOpen = false

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
                                settleCard(open: false, width: width)
                            }
                            .simultaneousGesture(pan(width: width, edge: edge, fromEdgeOnly: false))
                    }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                    card(width: width, height: geo.size.height, insets: insets)
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
                settleCard(open: true, width: width)
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

    private func card(width: CGFloat, height: CGFloat, insets: UIEdgeInsets) -> some View {
        // The column is at least as tall as the window, so Unlink rests on the
        // bottom when the rows fit. A short landscape window scrolls instead
        // of clipping that button. Bounce stays off while nothing overflows.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Text("Keyboard")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.62).matrix)
                Toggle("Hide keyboard in portrait mode", isOn: $preferences.hideInPortrait)
                Toggle("Hide keyboard in landscape mode", isOn: $preferences.hideInLandscape)
                Toggle("Matrix Mode", isOn: $matrixMode.enabled)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To report issues, take a screenshot and you should have an option to \"Share Beta Feedback\" or use this link to")
                            .fixedSize(horizontal: false, vertical: true)
                        infoLink("Report issues", urlString: Self.reportIssuesURL)
                    }
                    infoLink("Newbie guide", urlString: Self.newbieGuideURL)
                    infoLink("About Nilgiri IM", urlString: Self.aboutNilgiriIMURL)
                }
                if showsUnlink {
                    Spacer(minLength: 22)
                    unlinkButton
                }
            }
            .font(.system(size: 17))
            .toggleStyle(.switch)
            .tint(Color(white: 0.78))
            .foregroundStyle(Color(white: 0.92).matrix)
            .padding(.leading, insets.left + 20)
            .padding(.trailing, 18)
            .padding(.top, insets.top + 24)
            .padding(.bottom, insets.bottom + 20)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The drawer already pads for the notch. A scroll view would add that
        // inset again and leave a gap above Keyboard.
        .ignoresSafeArea()
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

    /// Same open path as a link in the log: `UIApplication.shared.open`, which
    /// hands http to Safari.
    private func infoLink(_ title: String, urlString: String) -> some View {
        Button {
            guard let url = URL(string: urlString) else { return }
            UIApplication.shared.open(url)
        } label: {
            Text(title)
                .underline()
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
        .accessibilityHint("Opens in Safari")
    }

    /// Bottom of the card. The log no longer has a floating Unlink control.
    private var unlinkButton: some View {
        Button(action: onUnlink) {
            Text("Unlink")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Unlink")
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
                settleCard(open: predicted > width * 0.45, width: width)
            }
    }

    /// Snaps the card fully open or fully away, and reports that edge once.
    /// Mid-drag `travel` is not an open: the finger can still slide it shut.
    private func settleCard(open: Bool, width: CGFloat) {
        withAnimation(.easeOut(duration: 0.22)) {
            travel = open ? width : 0
        }
        guard open != cardOpen else { return }
        cardOpen = open
        onOpenChange(open)
    }
}
