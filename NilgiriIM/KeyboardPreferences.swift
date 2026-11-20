import SwiftUI
import UIKit

/// Which character the on-screen settings belong to. Keys are the existing
/// names plus `.<lowercased character>`. An empty scope does not read the
/// old client-wide keys, so a character this install has never seen cannot
/// pick up someone else's values.
enum CharacterPreferenceScope {
    private static let migratedFlag = "im.perCharacterSettingsMigrated"

    /// Lowercased character name currently being read and written. Empty until
    /// a character is on screen or restored.
    private(set) static var key: String = ""

    static func storageKey(_ base: String) -> String {
        let slug = key
        if slug.isEmpty { return base + ".unset" }
        return base + "." + slug
    }

    /// Points later reads and writes at `name`. An empty name leaves the
    /// previous character in place so a picker with nobody selected does not
    /// wipe their settings with the fresh defaults.
    static func adopt(_ name: String?) {
        let next = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard next.isEmpty == false else { return }
        key = next
    }

    /// One-time copy for the character who was logged in when this build first
    /// launched. Passing nil marks the copy done and copies nothing, so the
    /// next character starts from the fresh-install defaults.
    static func migrateLoggedInCharacter(_ name: String?) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: migratedFlag) == false else { return }
        defer { defaults.set(true, forKey: migratedFlag) }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false else { return }
        let slug = trimmed.lowercased()
        for base in userDefaultsBases {
            copyDefault(base, slug: slug, defaults: defaults)
        }
        copyCloud(slug: slug)
    }

    private static let userDefaultsBases = [
        "im.hideKeyboardPortrait",
        "im.hideKeyboardLandscape",
        "im.hideHotButtonLabels",
        "im.keepLastCommand",
        "im.showActionHelp",
        "im.matrixMode",
        "im.actionShortcuts",
        "im.hotButtons",
        "im.sync.updatedAt",
        "im.sync.seeded",
        "im.sync.merged",
        "im.lastSeq",
        "im.disconnectAt",
        "im.disconnectSeq",
        "im.disconnectName",
        "im.disconnectServerMs",
        "im.shownDisconnectMs",
        "im.hmv",
        "im.hmvName",
    ]

    private static let cloudBases = [
        "im.sync.actionShortcuts",
        "im.sync.hotButtons",
        "im.sync.updatedAt",
        "im.sync.seeded",
    ]

    /// Copies the stored object as-is. `im.actionShortcuts` may be the older
    /// string array or the `{text, color}` rows. `im.hotButtons` is the JSON
    /// blob, including `color` when a plate was tinted. A text-only row has
    /// no color field; the loader treats that as white.
    private static func copyDefault(_ base: String, slug: String, defaults: UserDefaults) {
        guard defaults.object(forKey: base) != nil else { return }
        let dest = base + "." + slug
        guard defaults.object(forKey: dest) == nil else { return }
        defaults.set(defaults.object(forKey: base), forKey: dest)
    }

    /// The pre-multi iCloud blob is this character's synced lists. Copy it
    /// once under their name, color payload included. A string-array shortcut
    /// list is the older shape and decodes as white. Later characters read
    /// only their own keys.
    private static func copyCloud(slug: String) {
        let store = NSUbiquitousKeyValueStore.default
        _ = store.synchronize()
        var wrote = false
        for base in cloudBases {
            let dest = base + "." + slug
            guard store.object(forKey: dest) == nil, let value = store.object(forKey: base) else { continue }
            store.set(value, forKey: dest)
            wrote = true
        }
        if wrote {
            _ = store.synchronize()
        }
    }
}

extension Notification.Name {
    /// A player moved a left-menu switch. The menu store uploads that character.
    static let imMenuSettingsEdited = Notification.Name("im.menuSettingsEdited")
    /// iCloud applied switch values for the character in scope. Readers reload.
    static let imMenuSettingsApplied = Notification.Name("im.menuSettingsApplied")
}

/// Left-menu switches that sync with Actions and Hot Buttons. A missing
/// UserDefaults key is the untouched default: it is not uploaded and it
/// does not replace a value iCloud already has for this character.
enum CharacterMenuSwitch {
    static let portrait = "im.hideKeyboardPortrait"
    static let landscape = "im.hideKeyboardLandscape"
    static let hotButtonLabels = "im.hideHotButtonLabels"
    static let keepLastCommand = "im.keepLastCommand"
    static let showActionHelp = "im.showActionHelp"
    static let matrixMode = "im.matrixMode"

    static let bases = [
        portrait,
        landscape,
        hotButtonLabels,
        keepLastCommand,
        showActionHelp,
        matrixMode,
    ]

    /// Cloud key before the per-character suffix. `im.matrixMode` becomes
    /// `im.sync.matrixMode`, then `.<lowercased character>` like the list keys.
    static func syncBase(_ base: String) -> String {
        "im.sync.\(base.dropFirst(3))"
    }

    /// Switches this character has actually stored. Missing keys are omitted.
    static func stored() -> [String: Bool] {
        let defaults = UserDefaults.standard
        var values: [String: Bool] = [:]
        for base in bases {
            let key = CharacterPreferenceScope.storageKey(base)
            guard defaults.object(forKey: key) != nil else { continue }
            values[base] = defaults.bool(forKey: key)
        }
        return values
    }

    /// Writes synced values for this character. Returns whether any key changed.
    @discardableResult
    static func apply(_ values: [String: Bool]) -> Bool {
        let defaults = UserDefaults.standard
        var changed = false
        for base in bases {
            guard let value = values[base] else { continue }
            let key = CharacterPreferenceScope.storageKey(base)
            if defaults.object(forKey: key) == nil || defaults.bool(forKey: key) != value {
                defaults.set(value, forKey: key)
                changed = true
            }
        }
        return changed
    }
}

/// Whether sending a command, or turning the window, dismisses the keyboard.
/// Also whether the input line keeps the last command as grey placeholder text.
/// Missing keys keep the device default. iPhone hides in landscape only.
/// iPad keeps the keyboard up in both orientations. The hot-button switch
/// hides letters only; a missing key leaves them showing. Keep last command
/// defaults off. Show action help defaults on, so the line under Actions
/// stays visible until the switch is turned off. Moving a switch writes the key.
final class KeyboardHidePreferences: ObservableObject {
    /// False until `init` has finished `load()`. The default values below are
    /// only so the properties exist before that call. `didSet` must not write
    /// them, or a missing key would be stored before the saved value is read.
    /// `load` also clears this so a character switch does not write the
    /// previous character's values into the new keys.
    private var saves = false
    private var appliedObserver: NSObjectProtocol?

    @Published var hideInPortrait = false {
        didSet {
            guard hideInPortrait != oldValue else { return }
            store(hideInPortrait, Key.portrait)
        }
    }

    @Published var hideInLandscape = false {
        didSet {
            guard hideInLandscape != oldValue else { return }
            store(hideInLandscape, Key.landscape)
        }
    }

    /// Hide the letter on each on-screen hot button. The plate stays, and it still lights.
    @Published var hideHotButtonLabels = false {
        didSet {
            guard hideHotButtonLabels != oldValue else { return }
            store(hideHotButtonLabels, Key.hotButtonLabels)
        }
    }

    /// Grey placeholder of the last command sent from the input line.
    /// Return on an empty field sends that text. Off leaves the placeholder blank.
    @Published var keepLastCommand = false {
        didSet {
            guard keepLastCommand != oldValue else { return }
            store(keepLastCommand, Key.keepLastCommand)
        }
    }

    /// The line under Actions: double tap to edit.
    /// Missing key leaves it showing.
    @Published var showActionHelp = true {
        didSet {
            guard showActionHelp != oldValue else { return }
            store(showActionHelp, Key.showActionHelp)
        }
    }

    private enum Key {
        static let portrait = "im.hideKeyboardPortrait"
        static let landscape = "im.hideKeyboardLandscape"
        static let hotButtonLabels = "im.hideHotButtonLabels"
        static let keepLastCommand = "im.keepLastCommand"
        static let showActionHelp = "im.showActionHelp"
    }

    /// Character whose keys are loaded. A switch to someone else reads again.
    private var loadedFor = ""

    init() {
        load()
        loadedFor = CharacterPreferenceScope.key
        saves = true
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

    /// Loads the character `CharacterPreferenceScope` currently names.
    /// A missing key uses the fresh-install default, not another character's value.
    /// `force` rereads after iCloud applied a newer value for this same character.
    func reload(force: Bool = false) {
        let key = CharacterPreferenceScope.key
        guard force || key != loadedFor else { return }
        load()
        loadedFor = key
    }

    private func load() {
        let resume = saves
        saves = false
        defer { saves = resume }
        let defaults = UserDefaults.standard
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        hideInPortrait = Self.stored(defaults, scoped(Key.portrait), fallback: false)
        hideInLandscape = Self.stored(defaults, scoped(Key.landscape), fallback: phone)
        hideHotButtonLabels = Self.stored(defaults, scoped(Key.hotButtonLabels), fallback: false)
        keepLastCommand = Self.stored(defaults, scoped(Key.keepLastCommand), fallback: false)
        showActionHelp = Self.stored(defaults, scoped(Key.showActionHelp), fallback: true)
    }

    /// A switch the player moved. `load` turns this off so reading a character
    /// does not write that character's keys. Writing the key is what makes the
    /// value eligible to sync. A missing key stays the untouched default.
    private func store(_ value: Bool, _ base: String) {
        guard saves else { return }
        UserDefaults.standard.set(value, forKey: scoped(base))
        NotificationCenter.default.post(name: .imMenuSettingsEdited, object: nil)
    }

    private func scoped(_ base: String) -> String {
        CharacterPreferenceScope.storageKey(base)
    }

    func hidesKeyboard(isPortrait: Bool) -> Bool {
        isPortrait ? hideInPortrait : hideInLandscape
    }

    /// Hide switch for the window on screen. The drawer writes the same keys.
    static func hidesKeyboardForCurrentInterface() -> Bool {
        let defaults = UserDefaults.standard
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        if interfaceIsPortrait() {
            return stored(defaults, CharacterPreferenceScope.storageKey(Key.portrait), fallback: false)
        }
        return stored(defaults, CharacterPreferenceScope.storageKey(Key.landscape), fallback: phone)
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
/// Portrait and landscape keyboard switches, Matrix Mode, Hide hot button
/// labels, Keep last command, and Show action help stay at the top. Report issues, the newbie
/// guide, and About Nilgiri IM open in Safari. Unlink, while the player is
/// in the game, sits at the bottom of the card.
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
                Toggle("Hide hot button labels", isOn: $preferences.hideHotButtonLabels)
                Toggle("Keep last command", isOn: $preferences.keepLastCommand)
                Toggle("Show action help", isOn: $preferences.showActionHelp)
                VStack(alignment: .leading, spacing: 12) {
                    reportIssuesLine
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

    /// One sentence. "Report issues" is the link, to the same page as before.
    /// The rest is plain text, and the quotes are curly.
    private var reportIssuesLine: some View {
        (Text(reportIssuesLink) + Text(" or take a screenshot and “Share Beta Feedback”"))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                UIApplication.shared.open(url)
                return .handled
            })
            .accessibilityHint("Opens in Safari")
    }

    /// Underlined like the other menu links, in the menu's text colour.
    private var reportIssuesLink: AttributedString {
        var link = AttributedString("Report issues")
        link.underlineStyle = .single
        link.foregroundColor = Color(white: 0.92).matrix
        link.link = URL(string: Self.reportIssuesURL)
        return link
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
