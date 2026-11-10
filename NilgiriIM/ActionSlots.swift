import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One right-edge shortcut. The text is sent as the player left it.
/// A new id is minted when the row is created; reloading mints new ids and
/// the saved order is the string array.
struct ActionShortcut: Identifiable, Equatable {
    let id: UUID
    var text: String

    init(text: String) {
        self.id = UUID()
        self.text = text
    }

    /// Tap command. A hilited word is appended, separated by one space.
    /// Empty shortcut text is not a command. The stored text is not edited,
    /// and the hilite word is the transcript's word with surrounding
    /// whitespace removed, the same way a hot button builds its command.
    static func command(text: String, target: String?) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { return nil }
        let name = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { return body }
        return body + " " + name
    }
}

/// The shortcut list on the right-edge card. Missing storage seeds one row,
/// `get all corpse`. An empty array is a list the player cleared, so the
/// seed is not put back. At most ten rows are kept.
final class ActionShortcutStore: ObservableObject {
    static let limit = 10
    static let seedText = "get all corpse"

    @Published private(set) var shortcuts: [ActionShortcut] {
        didSet { save() }
    }

    private enum Key {
        static let shortcuts = "im.actionShortcuts"
    }

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.stringArray(forKey: Key.shortcuts) {
            shortcuts = stored.prefix(Self.limit).map { ActionShortcut(text: $0) }
        } else {
            shortcuts = [ActionShortcut(text: Self.seedText)]
            defaults.set([Self.seedText], forKey: Key.shortcuts)
        }
    }

    var canAdd: Bool { shortcuts.count < Self.limit }

    /// A blank row at the end. Nil when the list is already full.
    @discardableResult
    func addBlank() -> UUID? {
        guard canAdd else { return nil }
        let item = ActionShortcut(text: "")
        shortcuts.append(item)
        return item.id
    }

    func update(id: UUID, text: String) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        guard shortcuts[index].text != text else { return }
        shortcuts[index].text = text
    }

    func remove(id: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts.remove(at: index)
    }

    func move(from: Int, to: Int) {
        guard shortcuts.indices.contains(from), shortcuts.indices.contains(to), from != to else { return }
        let item = shortcuts.remove(at: from)
        shortcuts.insert(item, at: to)
    }

    private func save() {
        let capped = shortcuts.prefix(Self.limit).map(\.text)
        UserDefaults.standard.set(capped, forKey: Key.shortcuts)
    }
}

/// One play-screen hot button. `text` is the action, copied from the shortcut
/// the player dropped and never rewritten. `icon` is 0, 1, or 2 characters.
/// Empty means the plate is drawn with no glyph.
struct HotButton: Identifiable, Equatable {
    let id: UUID
    var text: String
    var icon: String

    init(id: UUID = UUID(), text: String, icon: String) {
        self.id = id
        self.text = text
        self.icon = Self.clampedIcon(icon)
    }

    /// Newlines are not an icon. Anything past two characters is dropped.
    static func clampedIcon(_ raw: String) -> String {
        let flat = raw.filter { $0.isNewline == false }
        return String(flat.prefix(2))
    }

    /// The glyph a newly dropped action starts with. The first character,
    /// uppercased when it is a letter, so `hit` starts as H. Empty text
    /// starts with no icon. The player can replace it with anything, or clear it.
    static func defaultIcon(for text: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = body.first else { return "" }
        if first.isLetter {
            return String(first).uppercased()
        }
        return String(first)
    }
}

/// The hot buttons, in the order the play screen draws them. At most six.
/// Missing `im.hotButtons` seeds hit [H], look [L], flee [F]. An empty array
/// is a list the player cleared, so the seed is not put back. The old slot
/// key is not read: this list replaces those three pull-downs.
final class HotButtonStore: ObservableObject {
    static let limit = 6

    @Published private(set) var buttons: [HotButton] {
        didSet { save() }
    }

    private enum Key {
        static let buttons = "im.hotButtons"
    }

    private struct Record: Codable {
        var text: String
        var icon: String
    }

    private static let seed: [HotButton] = [
        HotButton(text: "hit", icon: "H"),
        HotButton(text: "look", icon: "L"),
        HotButton(text: "flee", icon: "F"),
    ]

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Key.buttons) == nil {
            buttons = Self.seed
            Self.write(Self.seed, defaults: defaults)
        } else {
            buttons = Self.read(defaults)
        }
    }

    /// Same action twice is refused. Comparison trims both ends and leaves
    /// the stored text alone, so `hit` and `hit ` are one action.
    func canAccept(_ text: String) -> Bool {
        guard buttons.count < Self.limit else { return false }
        let key = Self.matchKey(text)
        return buttons.contains { Self.matchKey($0.text) == key } == false
    }

    @discardableResult
    func insert(text: String, at index: Int) -> Bool {
        guard canAccept(text) else { return false }
        let item = HotButton(text: text, icon: HotButton.defaultIcon(for: text))
        let clamped = min(max(0, index), buttons.count)
        buttons.insert(item, at: clamped)
        return true
    }

    func updateIcon(id: UUID, icon: String) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        let clamped = HotButton.clampedIcon(icon)
        guard buttons[index].icon != clamped else { return }
        buttons[index].icon = clamped
    }

    func remove(id: UUID) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        buttons.remove(at: index)
    }

    func move(from: Int, to: Int) {
        guard buttons.indices.contains(from), buttons.indices.contains(to), from != to else { return }
        let item = buttons.remove(at: from)
        buttons.insert(item, at: to)
    }

    private static func matchKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        Self.write(Array(buttons.prefix(Self.limit)), defaults: .standard)
    }

    private static func write(_ buttons: [HotButton], defaults: UserDefaults) {
        let records = buttons.prefix(Self.limit).map { Record(text: $0.text, icon: HotButton.clampedIcon($0.icon)) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Key.buttons)
    }

    /// A present key that does not decode stays empty. That is not the
    /// missing-key case, so the seed is not written back over it.
    private static func read(_ defaults: UserDefaults) -> [HotButton] {
        guard let data = defaults.data(forKey: Key.buttons),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        return records.prefix(Self.limit).map { HotButton(text: $0.text, icon: $0.icon) }
    }
}

/// Dark grey card on the right edge, the left settings card mirrored.
/// A leftward swipe from the log's right edge opens it. Shortcuts sit above
/// the hot buttons. The strip is only as tall as the log, so Say, Send,
/// and the name bar keep their taps.
struct ActionSlotsDrawer: View {
    @ObservedObject var shortcutStore: ActionShortcutStore
    @ObservedObject var hotButtons: HotButtonStore
    @ObservedObject private var matrixMode = MatrixMode.shared
    /// Toggled by the accessibility action. Each change opens the card.
    @Binding var openRequest: Bool
    /// Global frame of the log between the bars. Empty until the first layout.
    var logFrame: CGRect
    /// Word hilited in the log, appended when a shortcut is sent.
    var hilitedWord: String?
    /// The card settled open or closed. Not called during the drag, so a swipe
    /// that slides back shut does not dismiss the keyboard and bring it back.
    var onOpenChange: (Bool) -> Void
    /// Sends an already joined command. The caller owns the session.
    var onSend: (String) -> Void

    private enum Metrics {
        static let rowStride: CGFloat = 48
        static let deleteDistance: CGFloat = 64
        static let iconHitWidth: CGFloat = 52
    }

    private enum DragList { case actions, hotButtons }

    /// Row being held. Nil when no drag is in progress.
    private struct HeldDrag {
        enum Axis { case horizontal, vertical }
        var id: UUID
        var list: DragList
        var origin: Int
        var translation: CGSize
        var axis: Axis?
        /// Finger, in the window. Translation is taken from this, not a hit test.
        var location: CGPoint
    }

    /// Dark grey, see-through, so the log shows behind the card.
    private static let menuGrey = Color(white: 0.22).opacity(0.55)

    @State private var travel: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var ignoreDrag = false
    /// Last settled open bit already reported through `onOpenChange`.
    @State private var cardOpen = false
    /// Shortcut row in inline edit. Nil shows every row as a label.
    @State private var editingID: UUID?
    /// Hot-button icon in inline edit. Nil shows every icon as a plate.
    @State private var editingIconID: UUID?
    /// Hold-and-drag. While set, the card's own pan stays put.
    @State private var held: HeldDrag?
    /// True from the long-press began until the finger lifts.
    @State private var heldActive = false
    /// The system drop session is over the Hot Buttons well or the append bar.
    @State private var hotDropTargeted = false

    var body: some View {
        GeometryReader { geo in
            let width = min(300, geo.size.width * 0.84)
            let insets = Self.windowInsets
            let edge = max(24, insets.right + 20)
            let progress = width > 0 ? min(1, max(0, travel / width)) : 0
            let drawerGlobal = geo.frame(in: .global)
            let stripTop = max(0, logFrame.minY - drawerGlobal.minY)
            let stripHeight = min(max(0, logFrame.height), max(0, geo.size.height - stripTop))
            ZStack(alignment: .trailing) {
                if travel > 0 {
                    HStack(spacing: 0) {
                        Color.black.opacity(0.4 * progress)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                settleCard(open: false, width: width)
                            }
                            .simultaneousGesture(pan(width: width, fromEdgeOnly: false))
                        Color.clear
                            .frame(width: travel)
                            .allowsHitTesting(false)
                    }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                    card(width: width, height: geo.size.height, insets: insets)
                        .offset(x: width - travel)
                        .accessibilityHidden(travel < width * 0.8)
                        .simultaneousGesture(pan(width: width, fromEdgeOnly: false))
                }

                // Full-screen clear. Only the log's right strip takes the swipe,
                // so the bars and the rest of the log still scroll and accept taps.
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: stripTop)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                        Color.clear
                            .frame(width: edge)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(pan(width: width, fromEdgeOnly: true))
                            .allowsHitTesting(travel < 8 || dragOrigin != nil)
                    }
                    .frame(height: stripHeight)
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

    private static let space = "actionSlotsDrawer"

    /// The drawer's geometry reader is pushed under the safe area, so its own
    /// insets are not the notch. The window still has them.
    private static var windowInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow?.safeAreaInsets ?? scene?.windows.first?.safeAreaInsets ?? .zero
    }

    private func card(width: CGFloat, height: CGFloat, insets: UIEdgeInsets) -> some View {
        // The column is at least as tall as the window. A short landscape
        // window scrolls instead of clipping the last row. Bounce stays off
        // while nothing overflows.
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        actionsHeader
                        shortcutRows(width: width)
                    }
                    sectionDivider
                    hotButtonSection
                }
                .font(.system(size: 17))
                .foregroundStyle(MatrixShade.display(Color(white: 0.92), enabled: matrixMode.enabled))
                .padding(.trailing, insets.right + 20)
                .padding(.leading, 18)
                .padding(.top, insets.top + 24)
                .padding(.bottom, insets.bottom + 20)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(heldActive)
            // A scroll while editing must not take the keyboard down. The
            // command field is already resigned for the open card.
            .scrollDismissesKeyboard(.never)
            // The drawer already pads for the notch. A scroll view would add
            // that inset again and leave a gap above Actions.
            .ignoresSafeArea()
            .onChange(of: editingID) { _, id in
                guard let id else { return }
                scrollEditingRow(id, proxy: proxy)
            }
            .onChange(of: editingIconID) { _, id in
                guard let id else { return }
                scrollEditingRow(id, proxy: proxy)
            }
        }
        .ignoresSafeArea()
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Self.menuGrey)
        .overlay(alignment: .bottom) {
            if showAppendBar {
                appendBar
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 14, x: -8, y: 0)
    }

    /// Actions above, then the hot-button well. The well is the drop target:
    /// a `String` in `public.utf8-plain-text`, the same payload `.draggable`
    /// writes on an action row. An empty list keeps one row of height so the
    /// target does not collapse.
    private var hotButtonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Hot Buttons")
            hotButtonRows
        }
    }

    /// Shown while an action is being dragged down, and while a system drop
    /// is over the card. It stays on screen when the well has scrolled away,
    /// and a drop here appends. Minimum height so an empty hit still lands.
    private var showAppendBar: Bool {
        if hotDropTargeted { return true }
        guard let drag = held, drag.list == .actions, drag.axis == .vertical else { return false }
        return true
    }

    private var appendBar: some View {
        Text("Hot Buttons")
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(MatrixShade.display(Color(white: 0.78), enabled: matrixMode.enabled))
            .frame(maxWidth: .infinity, minHeight: Metrics.rowStride, alignment: .center)
            .padding(.bottom, Self.windowInsets.bottom)
            .background(Color(white: hotDropTargeted ? 0.34 : 0.18).opacity(0.94))
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                acceptActionDrop(items, at: hotButtons.buttons.count)
            } isTargeted: { targeted in
                setHotDropTargeted(targeted)
            }
            .onDrop(of: [UTType.utf8PlainText, UTType.plainText], isTargeted: $hotDropTargeted) { providers in
                loadActionDrop(providers, at: hotButtons.buttons.count)
            }
            .accessibilityHidden(true)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(MatrixShade.display(Color(white: 0.62), enabled: matrixMode.enabled))
            .accessibilityAddTraits(.isHeader)
    }

    private var actionsHeader: some View {
        HStack(alignment: .center, spacing: 0) {
            sectionTitle("Actions")
            if shortcutStore.canAdd {
                Button(action: addShortcut) {
                    Text("+")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.92))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add shortcut")
            }
            Spacer(minLength: 0)
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private func shortcutRows(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shortcutStore.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                shortcutRow(index: index, shortcut: shortcut, width: width)
            }
        }
    }

    private func shortcutRow(index: Int, shortcut: ActionShortcut, width: CGFloat) -> some View {
        let offset = actionRowOffset(index: index)
        let dragging = held?.list == .actions && held?.id == shortcut.id
        let deleting = dragging && held?.axis == .horizontal
        let trimmed = shortcut.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ZStack(alignment: .leading) {
            if deleting {
                Text("Delete")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .opacity(min(1, max(0, (held?.translation.width ?? 0) / Metrics.deleteDistance)))
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
            }
            Group {
                if editingID == shortcut.id {
                    ShortcutEditor(
                        text: shortcut.text,
                        onText: { shortcutStore.update(id: shortcut.id, text: $0) },
                        onCommit: {
                            if editingID == shortcut.id {
                                editingID = nil
                            }
                        }
                    )
                    .accessibilityLabel("Shortcut text")
                } else {
                    Text(verbatim: trimmed.isEmpty ? "shortcut" : shortcut.text)
                        .font(.system(size: 17, design: .monospaced))
                        .foregroundStyle(Color(white: 0.92).opacity(trimmed.isEmpty ? 0.35 : 1))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .overlay {
                            ShortcutRowGestures(
                                yieldsToSystemDrag: true,
                                dragText: shortcut.text,
                                onTap: { _ in activate(shortcut, width: width) },
                                onDoubleTap: { editingID = shortcut.id },
                                onPressBegan: { location in
                                    beginDrag(shortcut.id, list: .actions, location: location)
                                },
                                onPressChanged: { translation, location in
                                    updateDrag(translation, location)
                                },
                                onPressEnded: { translation, location, committed in
                                    finishDrag(translation: translation, location: location, committed: committed)
                                }
                            )
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(trimmed.isEmpty ? "Empty shortcut" : shortcut.text)
                        .accessibilityHint(shortcutHint)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { activate(shortcut, width: width) }
                        .accessibilityAction(named: Text("Edit")) { editingID = shortcut.id }
                        .accessibilityAction(named: Text("Delete")) { deleteShortcut(shortcut.id) }
                        .accessibilityAction(named: Text("Move up")) { moveShortcut(shortcut.id, by: -1) }
                        .accessibilityAction(named: Text("Move down")) { moveShortcut(shortcut.id, by: 1) }
                        .accessibilityAction(named: Text("Add to hot buttons")) {
                            hotButtons.insert(text: shortcut.text, at: hotButtons.buttons.count)
                        }
                }
            }
            .offset(offset)
            .background(deleting ? Color(white: 0.22) : Color.clear)
            .opacity(actionRowOpacity(index: index))
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.rowStride)
        .zIndex(dragging ? 1 : 0)
        .id(shortcut.id)
    }

    private var shortcutHint: String {
        let name = hilitedWord?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { return "Sends this shortcut" }
        return "Sends this shortcut followed by \(name)"
    }

    /// Icon plate and the action text, in list order. The plate is what the
    /// play-screen button shows. Tap the plate to type 0, 1, or 2 characters.
    /// Hold the row to reorder inside this list. A drag that leaves the list
    /// removes only that hot button; the action row is a different object.
    /// The well keeps a row of height when the list is empty, and it accepts
    /// the action row's `String` drop there.
    private var hotButtonRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hotButtons.buttons.enumerated()), id: \.element.id) { index, button in
                hotButtonRow(index: index, button: button)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.rowStride, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hotWellFill))
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, location in
            acceptActionDrop(items, at: indexForRowDrop(location.y))
        } isTargeted: { targeted in
            setHotDropTargeted(targeted)
        }
        .onDrop(of: [UTType.utf8PlainText, UTType.plainText], isTargeted: $hotDropTargeted) { providers in
            loadActionDrop(providers, at: hotButtons.buttons.count)
        }
    }

    /// Quiet when the list is empty, so the well is still a visible target.
    /// Brighter while a drop is aimed at it.
    private var hotWellFill: Double {
        if hotDropTargeted || actionDragIntoHotButtons { return 0.12 }
        if hotButtons.buttons.isEmpty { return 0.06 }
        return 0
    }

    private func hotButtonRow(index: Int, button: HotButton) -> some View {
        let offset = hotRowOffset(index: index)
        let dragging = held?.list == .hotButtons && held?.id == button.id
        let trimmed = button.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 10) {
            if editingIconID == button.id {
                IconEditor(
                    text: button.icon,
                    matrix: matrixMode.enabled,
                    onText: { hotButtons.updateIcon(id: button.id, icon: $0) },
                    onCommit: {
                        if editingIconID == button.id {
                            editingIconID = nil
                        }
                    }
                )
                .frame(width: 40, height: 32)
                .background(iconPlateFill)
            } else {
                iconPlate(button.icon)
            }
            Text(verbatim: trimmed.isEmpty ? "action" : button.text)
                .font(.system(size: 17, design: .monospaced))
                .foregroundStyle(Color(white: 0.92).opacity(trimmed.isEmpty ? 0.35 : 1))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.rowStride)
        .overlay {
            if editingIconID != button.id {
                ShortcutRowGestures(
                    onTap: { point in
                        guard point.x <= Metrics.iconHitWidth else { return }
                        editingID = nil
                        editingIconID = button.id
                    },
                    onDoubleTap: nil,
                    onPressBegan: { location in
                        beginDrag(button.id, list: .hotButtons, location: location)
                    },
                    onPressChanged: { translation, location in
                        updateDrag(translation, location)
                    },
                    onPressEnded: { translation, location, committed in
                        finishDrag(translation: translation, location: location, committed: committed)
                    }
                )
            }
        }
        .offset(offset)
        .opacity(hotRowOpacity(index: index))
        .zIndex(dragging ? 1 : 0)
        .id(button.id)
        .accessibilityElement(children: editingIconID == button.id ? .contain : .ignore)
        .accessibilityLabel(trimmed.isEmpty ? "Empty hot button" : button.text)
        .accessibilityValue(button.icon.isEmpty ? "No icon" : "Icon \(button.icon)")
        .accessibilityHint("Drag out of hot buttons to remove")
        .accessibilityAction(named: Text("Edit icon")) {
            editingID = nil
            editingIconID = button.id
        }
        .accessibilityAction(named: Text("Move up")) { moveHotButton(button.id, by: -1) }
        .accessibilityAction(named: Text("Move down")) { moveHotButton(button.id, by: 1) }
        .accessibilityAction(named: Text("Remove")) { removeHotButton(button.id) }
    }

    private func iconPlate(_ icon: String) -> some View {
        Text(verbatim: icon)
            .font(.system(size: 17, weight: .bold, design: .monospaced))
            .foregroundStyle(MatrixShade.display(Color(white: 0.92), enabled: matrixMode.enabled))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: 40, height: 32)
            .background(iconPlateFill)
    }

    private var iconPlateFill: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.12))
    }

    /// Opens from the right edge, or follows a finger that is already dragging the card.
    /// A vertical move that starts while the card is closed is left alone.
    private func pan(width: CGFloat, fromEdgeOnly: Bool) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(Self.space))
            .onChanged { value in
                // A held row owns the finger. The card must not follow it shut.
                if heldActive {
                    ignoreDrag = true
                    return
                }
                if ignoreDrag { return }
                if dragOrigin == nil {
                    let translation = value.translation
                    guard hypot(translation.width, translation.height) >= 10 else { return }
                    if fromEdgeOnly && travel < 1 {
                        let opening = translation.width < 0 && abs(translation.width) > abs(translation.height)
                        if opening == false {
                            ignoreDrag = true
                            return
                        }
                    }
                    dragOrigin = travel
                }
                guard let dragOrigin else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                let next = min(width, max(0, dragOrigin - value.translation.width))
                withTransaction(transaction) {
                    travel = next
                }
            }
            .onEnded { value in
                let origin = dragOrigin
                dragOrigin = nil
                let blocked = ignoreDrag || heldActive
                ignoreDrag = false
                guard blocked == false, let origin else { return }
                let predicted = origin - value.predictedEndTranslation.width
                settleCard(open: predicted > width * 0.45, width: width)
            }
    }

    /// Snaps the card fully open or fully away, and reports that edge once.
    /// Mid-drag `travel` is not an open: the finger can still slide it shut.
    private func settleCard(open: Bool, width: CGFloat) {
        if open == false {
            editingID = nil
            editingIconID = nil
            heldActive = false
            held = nil
            hotDropTargeted = false
        }
        withAnimation(.easeOut(duration: 0.22)) {
            travel = open ? width : 0
        }
        guard open != cardOpen else { return }
        cardOpen = open
        onOpenChange(open)
    }

    private func addShortcut() {
        guard let id = shortcutStore.addBlank() else { return }
        editingIconID = nil
        editingID = id
    }

    /// Single tap. A shortcut is sent and the card closes. The joined command
    /// already includes the hilite. Blank text has nothing to send, so the
    /// tap opens the inline editor instead of closing the card.
    private func activate(_ shortcut: ActionShortcut, width: CGFloat) {
        guard let command = ActionShortcut.command(text: shortcut.text, target: hilitedWord) else {
            editingIconID = nil
            editingID = shortcut.id
            return
        }
        editingID = nil
        editingIconID = nil
        settleCard(open: false, width: width)
        onSend(command)
    }

    private func deleteShortcut(_ id: UUID) {
        if editingID == id {
            editingID = nil
        }
        withAnimation(.easeOut(duration: 0.18)) {
            if held?.id == id {
                held = nil
                heldActive = false
            }
            shortcutStore.remove(id: id)
        }
    }

    private func moveShortcut(_ id: UUID, by delta: Int) {
        guard let index = shortcutStore.shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcutStore.move(from: index, to: index + delta)
    }

    private func removeHotButton(_ id: UUID) {
        if editingIconID == id {
            editingIconID = nil
        }
        withAnimation(.easeOut(duration: 0.18)) {
            if held?.id == id {
                held = nil
                heldActive = false
            }
            hotButtons.remove(id: id)
        }
    }

    private func moveHotButton(_ id: UUID, by delta: Int) {
        guard let index = hotButtons.buttons.firstIndex(where: { $0.id == id }) else { return }
        hotButtons.move(from: index, to: index + delta)
    }

    private func beginDrag(_ id: UUID, list: DragList, location: CGPoint) {
        guard editingID == nil, editingIconID == nil else { return }
        let index: Int?
        switch list {
        case .actions:
            index = shortcutStore.shortcuts.firstIndex(where: { $0.id == id })
        case .hotButtons:
            index = hotButtons.buttons.firstIndex(where: { $0.id == id })
        }
        guard let index else { return }
        heldActive = true
        held = HeldDrag(id: id, list: list, origin: index, translation: .zero, axis: nil, location: location)
    }

    private func updateDrag(_ translation: CGSize, _ location: CGPoint) {
        guard var current = held else { return }
        if current.list == .actions {
            current.axis = lockedAxis(for: translation, current: current.axis)
        }
        current.translation = translation
        current.location = location
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            held = current
        }
    }

    private func finishDrag(translation: CGSize, location: CGPoint, committed: Bool) {
        guard var current = held else { return }
        guard cardOpen else {
            held = nil
            heldActive = false
            return
        }
        current.translation = translation
        current.location = location
        if current.list == .actions, current.axis == nil {
            current.axis = lockedAxis(for: translation, current: nil)
        }
        if committed, current.list == .actions, current.axis == .horizontal,
           current.translation.width >= Metrics.deleteDistance {
            deleteShortcut(current.id)
            return
        }
        if committed, current.list == .actions, current.axis == .vertical,
           let shortcut = shortcutStore.shortcuts.first(where: { $0.id == current.id }),
           draggedDownIntoHotButtons(
               origin: current.origin,
               translationY: current.translation.height,
               actionCount: shortcutStore.shortcuts.count
           ) {
            // Copy. The action row stays in the Actions list.
            withAnimation(.easeOut(duration: 0.16)) {
                held = nil
                heldActive = false
                hotButtons.insert(text: shortcut.text, at: hotButtons.buttons.count)
            }
            return
        }
        if committed, current.list == .actions, current.axis == .vertical,
           let index = shortcutStore.shortcuts.firstIndex(where: { $0.id == current.id }) {
            let target = verticalTravel(
                origin: current.origin,
                translationY: current.translation.height,
                count: shortcutStore.shortcuts.count
            ).target
            let dest = index + (target - current.origin)
            if shortcutStore.shortcuts.indices.contains(dest), dest != index {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    held = nil
                    heldActive = false
                    shortcutStore.move(from: index, to: dest)
                }
                return
            }
        }
        if committed, current.list == .hotButtons {
            // Leaving the section removes this entry only. The shortcut with
            // the same words, if there is one, is a different row and stays.
            if hotDragExited(
                origin: current.origin,
                translation: current.translation,
                count: hotButtons.buttons.count
            ) {
                removeHotButton(current.id)
                return
            }
            if let index = hotButtons.buttons.firstIndex(where: { $0.id == current.id }) {
                let target = verticalTravel(
                    origin: current.origin,
                    translationY: current.translation.height,
                    count: hotButtons.buttons.count
                ).target
                let dest = index + (target - current.origin)
                if hotButtons.buttons.indices.contains(dest), dest != index {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        held = nil
                        heldActive = false
                        hotButtons.move(from: index, to: dest)
                    }
                    return
                }
            }
        }
        withAnimation(.easeOut(duration: 0.16)) {
            held = nil
            heldActive = false
        }
    }

    /// Rightward travel deletes an action. Vertical travel reorders it, and
    /// can leave the list to land on the hot buttons. A leftward move is
    /// neither: the card pan is already suppressed for this hold.
    private func lockedAxis(for translation: CGSize, current: HeldDrag.Axis?) -> HeldDrag.Axis? {
        if let current { return current }
        let dx = translation.width
        let dy = translation.height
        if dx > 16, dx > abs(dy) * 1.25 {
            return .horizontal
        }
        if abs(dy) > 16 {
            return .vertical
        }
        return nil
    }

    private func verticalTravel(
        origin: Int,
        translationY: CGFloat,
        count: Int
    ) -> (travel: CGFloat, target: Int) {
        let stride = Metrics.rowStride
        guard count > 0, origin >= 0, origin < count else { return (0, max(0, origin)) }
        let maxDown = CGFloat(count - 1 - origin) * stride
        let maxUp = CGFloat(origin) * stride
        let travel = min(maxDown, max(-maxUp, translationY))
        let delta = Int((travel / stride).rounded())
        let target = min(count - 1, max(0, origin + delta))
        return (travel, target)
    }

    private func actionRowOffset(index: Int) -> CGSize {
        guard let drag = held, drag.list == .actions, let axis = drag.axis else { return .zero }
        let shortcuts = shortcutStore.shortcuts
        guard shortcuts.indices.contains(index) else { return .zero }
        if axis == .horizontal {
            guard shortcuts[index].id == drag.id else { return .zero }
            return CGSize(width: max(0, drag.translation.width), height: 0)
        }
        // A copy heading into Hot Buttons leaves the action where it is.
        if actionDragIntoHotButtons {
            return .zero
        }
        let placed = verticalTravel(
            origin: drag.origin,
            translationY: drag.translation.height,
            count: shortcuts.count
        )
        if index == drag.origin {
            return CGSize(width: 0, height: placed.travel)
        }
        if placed.target > drag.origin, index > drag.origin, index <= placed.target {
            return CGSize(width: 0, height: -Metrics.rowStride)
        }
        if placed.target < drag.origin, index < drag.origin, index >= placed.target {
            return CGSize(width: 0, height: Metrics.rowStride)
        }
        return .zero
    }

    private func actionRowOpacity(index: Int) -> Double {
        guard let drag = held, drag.list == .actions else { return 1 }
        guard shortcutStore.shortcuts.indices.contains(index) else { return 1 }
        guard shortcutStore.shortcuts[index].id == drag.id else { return 1 }
        if drag.axis == .horizontal {
            let progress = min(1, max(0, drag.translation.width / Metrics.deleteDistance))
            return 1 - 0.45 * progress
        }
        if actionDragIntoHotButtons {
            return 0.4
        }
        return 1
    }

    private func hotRowOffset(index: Int) -> CGSize {
        let buttons = hotButtons.buttons
        guard buttons.indices.contains(index) else { return .zero }
        if let drag = held, drag.list == .hotButtons {
            return hotDragOffset(index: index, drag: drag, count: buttons.count)
        }
        return .zero
    }

    private func hotDragOffset(index: Int, drag: HeldDrag, count: Int) -> CGSize {
        let buttons = hotButtons.buttons
        guard buttons.indices.contains(index) else { return .zero }
        let exited = hotDragExited(origin: drag.origin, translation: drag.translation, count: count)
        if exited == false {
            let placed = verticalTravel(
                origin: drag.origin,
                translationY: drag.translation.height,
                count: count
            )
            if index == drag.origin {
                return CGSize(width: 0, height: placed.travel)
            }
            if placed.target > drag.origin, index > drag.origin, index <= placed.target {
                return CGSize(width: 0, height: -Metrics.rowStride)
            }
            if placed.target < drag.origin, index < drag.origin, index >= placed.target {
                return CGSize(width: 0, height: Metrics.rowStride)
            }
            return .zero
        }
        if buttons[index].id == drag.id {
            return CGSize(width: drag.translation.width, height: drag.translation.height)
        }
        if index > drag.origin {
            return CGSize(width: 0, height: -Metrics.rowStride)
        }
        return .zero
    }

    private func hotRowOpacity(index: Int) -> Double {
        guard let drag = held, drag.list == .hotButtons else { return 1 }
        guard hotButtons.buttons.indices.contains(index) else { return 1 }
        guard hotButtons.buttons[index].id == drag.id else { return 1 }
        if hotDragExited(
            origin: drag.origin,
            translation: drag.translation,
            count: hotButtons.buttons.count
        ) {
            return 0.7
        }
        return 1
    }

    /// Downward travel past the last action row. Measured from the row the
    /// finger started on, so it does not depend on a window frame.
    private var actionDragIntoHotButtons: Bool {
        guard let drag = held, drag.list == .actions, drag.axis == .vertical else { return false }
        return draggedDownIntoHotButtons(
            origin: drag.origin,
            translationY: drag.translation.height,
            actionCount: shortcutStore.shortcuts.count
        )
    }

    private func draggedDownIntoHotButtons(origin: Int, translationY: CGFloat, actionCount: Int) -> Bool {
        let pastBottom = translationY - CGFloat(max(0, actionCount - 1 - origin)) * Metrics.rowStride
        return pastBottom > 40
    }

    /// Up past the top of the section (toward Actions), down past the last
    /// row, or clearly sideways. A reorder inside the list stays put.
    private func hotDragExited(origin: Int, translation: CGSize, count: Int) -> Bool {
        let stride = Metrics.rowStride
        let above = -translation.height - CGFloat(origin) * stride
        if above > 28 { return true }
        let below = translation.height - CGFloat(max(0, count - 1 - origin)) * stride
        if below > 36 { return true }
        if abs(translation.width) > 56, abs(translation.width) > abs(translation.height) * 1.1 {
            return true
        }
        return false
    }

    /// `items` is the action text. Inserts a copy. Does not remove the action
    /// row. Refuses a 7th and a duplicate.
    private func acceptActionDrop(_ items: [String], at index: Int) -> Bool {
        guard let text = items.first else { return false }
        return hotButtons.insert(text: text, at: index)
    }

    /// Same bytes the action row's drag registers: `public.utf8-plain-text`
    /// and `public.plain-text`. The load finishes after the drop is accepted.
    private func loadActionDrop(_ providers: [NSItemProvider], at index: Int) -> Bool {
        guard let provider = providers.first else { return false }
        let identifiers = [UTType.utf8PlainText.identifier, UTType.plainText.identifier]
        guard let type = identifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                _ = self.hotButtons.insert(text: text, at: index)
            }
        }
        return true
    }

    /// Midpoint of each row in the well. The well's local origin is the first
    /// row, including when that row is the empty minimum-height target.
    private func indexForRowDrop(_ localY: CGFloat) -> Int {
        let count = hotButtons.buttons.count
        guard count > 0 else { return 0 }
        if localY < 0 { return 0 }
        for index in 0..<count {
            let mid = (CGFloat(index) + 0.5) * Metrics.rowStride
            if localY < mid { return index }
        }
        return count
    }

    private func setHotDropTargeted(_ targeted: Bool) {
        guard hotDropTargeted != targeted else { return }
        hotDropTargeted = targeted
    }

    /// Puts the editing row near the top of the card, above the keyboard.
    /// The scroll view ignores the safe area, so a center anchor can sit
    /// under the keys on a short landscape window.
    private func scrollEditingRow(_ id: UUID, proxy: ScrollViewProxy) {
        func align() {
            guard editingID == id || editingIconID == id else { return }
            proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.12))
        }
        DispatchQueue.main.async(execute: align)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: align)
    }
}

/// Inline shortcut field. A plain field, not the command field: that one
/// refuses to resign while this orientation keeps the keyboard, and the
/// editor would never receive keys. Return ends the edit. The card is open,
/// so the command field stays resigned until the card closes.
private struct ShortcutEditor: UIViewRepresentable {
    var text: String
    var onText: (String) -> Void
    var onCommit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        field.textColor = UIColor(white: 0.92, alpha: 1)
        field.tintColor = field.textColor
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.keyboardType = .asciiCapable
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.autocapitalizationType = .none
        field.keyboardAppearance = .dark
        field.adjustsFontForContentSizeCategory = false
        field.attributedPlaceholder = NSAttributedString(
            string: "shortcut",
            attributes: [.foregroundColor: UIColor(white: 0.92, alpha: 0.35)]
        )
        field.accessibilityLabel = "Shortcut text"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.changed(_:)),
            for: .editingChanged
        )
        return field
    }

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
        return CGSize(width: width, height: 48)
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onText = onText
        coordinator.onCommit = onCommit
        if field.markedTextRange == nil, field.text != text {
            coordinator.applying = true
            field.text = text
            coordinator.applying = false
        }
        // One become. A second call from a later layout restarts the session
        // and the keyboard never attaches.
        if coordinator.didFocus == false {
            coordinator.didFocus = true
            coordinator.scheduleBecome(field)
        }
    }

    static func dismantleUIView(_ uiView: UITextField, coordinator: Coordinator) {
        coordinator.didFocus = false
        if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onText: (String) -> Void = { _ in }
        var onCommit: () -> Void = {}
        var applying = false
        var didFocus = false

        @objc func changed(_ field: UITextField) {
            guard applying == false else { return }
            let raw = field.text ?? ""
            let flat = raw
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "")
            if flat != raw {
                applying = true
                field.text = flat
                applying = false
            }
            onText(flat)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            let end = textField.endOfDocument
            textField.selectedTextRange = textField.textRange(from: end, to: end)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            onCommit()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return false
        }

        func scheduleBecome(_ field: UITextField, retries: Int = 8) {
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                guard self.didFocus else { return }
                guard field.window != nil else {
                    guard retries > 0 else { return }
                    self.scheduleBecome(field, retries: retries - 1)
                    return
                }
                guard field.isFirstResponder == false else { return }
                if field.becomeFirstResponder() {
                    return
                }
                guard retries > 0 else { return }
                // The command field may still be first responder for this frame.
                // Ask it to resign, then try again. A refused resign just retries.
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
                self.scheduleBecome(field, retries: retries - 1)
            }
        }
    }
}

/// Icon field on a hot-button row. Two characters at most. Empty is kept:
/// the play-screen plate is then blank. Same focus retry as the shortcut
/// field, for the same reason.
private struct IconEditor: UIViewRepresentable {
    var text: String
    var matrix: Bool
    var onText: (String) -> Void
    var onCommit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .bold)
        field.textColor = UIColor(white: 0.92, alpha: 1)
        field.tintColor = field.textColor
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.textAlignment = .center
        field.keyboardType = .asciiCapable
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.autocapitalizationType = .none
        field.keyboardAppearance = .dark
        field.adjustsFontForContentSizeCategory = false
        field.accessibilityLabel = "Hot button icon"
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.changed(_:)),
            for: .editingChanged
        )
        return field
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView _: UITextField,
        context _: Context
    ) -> CGSize? {
        let width: CGFloat
        if let proposed = proposal.width, proposed > 0, proposed < .greatestFiniteMagnitude {
            width = proposed
        } else {
            width = 40
        }
        return CGSize(width: width, height: 32)
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onText = onText
        coordinator.onCommit = onCommit
        let ink = MatrixShade.display(UIColor(white: 0.92, alpha: 1), enabled: matrix)
        field.textColor = ink
        field.tintColor = ink
        if field.markedTextRange == nil, field.text != text {
            coordinator.applying = true
            field.text = text
            coordinator.applying = false
        }
        if coordinator.didFocus == false {
            coordinator.didFocus = true
            coordinator.scheduleBecome(field)
        }
    }

    static func dismantleUIView(_ uiView: UITextField, coordinator: Coordinator) {
        coordinator.didFocus = false
        if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onText: (String) -> Void = { _ in }
        var onCommit: () -> Void = {}
        var applying = false
        var didFocus = false

        @objc func changed(_ field: UITextField) {
            guard applying == false else { return }
            guard field.markedTextRange == nil else { return }
            let raw = field.text ?? ""
            let flat = String(raw.filter { $0.isNewline == false }.prefix(2))
            if flat != raw {
                applying = true
                field.text = flat
                applying = false
            }
            onText(flat)
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if applying { return false }
            if string.contains(where: { $0.isNewline }) {
                return false
            }
            let current = textField.text ?? ""
            guard let swiftRange = Range(range, in: current) else { return false }
            let replaced = current.replacingCharacters(in: swiftRange, with: string)
            let next = String(replaced.filter { $0.isNewline == false }.prefix(2))
            if next == replaced {
                return true
            }
            // A paste longer than two characters keeps the first two.
            // `applying` stops the assignment from re-entering this method.
            applying = true
            textField.text = next
            applying = false
            onText(next)
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            let start = textField.beginningOfDocument
            let end = textField.endOfDocument
            textField.selectedTextRange = textField.textRange(from: start, to: end)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            onCommit()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return false
        }

        func scheduleBecome(_ field: UITextField, retries: Int = 8) {
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                guard self.didFocus else { return }
                guard field.window != nil else {
                    guard retries > 0 else { return }
                    self.scheduleBecome(field, retries: retries - 1)
                    return
                }
                guard field.isFirstResponder == false else { return }
                if field.becomeFirstResponder() {
                    return
                }
                guard retries > 0 else { return }
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
                self.scheduleBecome(field, retries: retries - 1)
            }
        }
    }
}

/// Tap, double tap, and hold on one row. The single tap waits until the
/// double tap fails, so an edit does not also send. A hold that already
/// began swallows the tap that follows the finger lifting. A nil double tap
/// is a row with no second action: the single tap fires on its own.
private struct ShortcutRowGestures: UIViewRepresentable {
    /// An action row yields so the system drag can start beside this hold.
    /// A hot-button row keeps the hold exclusive: that drag reorders or
    /// removes, and it does not publish a text payload.
    var yieldsToSystemDrag: Bool = false
    /// Action text published as `public.utf8-plain-text` and `public.plain-text`.
    /// The Hot Buttons well and the append bar both accept those types.
    var dragText: String = ""
    var onTap: (CGPoint) -> Void
    var onDoubleTap: (() -> Void)?
    var onPressBegan: (CGPoint) -> Void
    var onPressChanged: (CGSize, CGPoint) -> Void
    var onPressEnded: (CGSize, CGPoint, Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let single = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.singleTap(_:))
        )
        single.numberOfTapsRequired = 1
        single.cancelsTouchesInView = false
        let press = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.longPress(_:))
        )
        press.minimumPressDuration = 0.35
        press.cancelsTouchesInView = yieldsToSystemDrag == false
        press.delegate = context.coordinator
        context.coordinator.yieldsToSystemDrag = yieldsToSystemDrag
        context.coordinator.dragText = dragText
        if yieldsToSystemDrag {
            let drag = UIDragInteraction(delegate: context.coordinator)
            drag.isEnabled = true
            drag.allowsSimultaneousRecognitionDuringLift = true
            view.addInteraction(drag)
        }
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(press)
        if onDoubleTap != nil {
            let double = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.doubleTap)
            )
            double.numberOfTapsRequired = 2
            double.cancelsTouchesInView = false
            single.require(toFail: double)
            view.addGestureRecognizer(double)
        }
        return view
    }

    /// The row proposes the hit size. A plain `UIView` has no intrinsic size,
    /// and a zero-sized overlay would miss every tap.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView _: UIView,
        context _: Context
    ) -> CGSize? {
        let width = proposal.width ?? 0
        let height = proposal.height ?? 48
        return CGSize(
            width: width > 0 && width < .greatestFiniteMagnitude ? width : 1,
            height: height > 0 && height < .greatestFiniteMagnitude ? height : 48
        )
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.yieldsToSystemDrag = yieldsToSystemDrag
        coordinator.dragText = dragText
        coordinator.onTap = onTap
        coordinator.onDoubleTap = onDoubleTap
        coordinator.onPressBegan = onPressBegan
        coordinator.onPressChanged = onPressChanged
        coordinator.onPressEnded = onPressEnded
        if let press = uiView.gestureRecognizers?.compactMap({ $0 as? UILongPressGestureRecognizer }).first {
            press.cancelsTouchesInView = yieldsToSystemDrag == false
            press.delegate = coordinator
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIDragInteractionDelegate {
        var yieldsToSystemDrag = false
        var dragText = ""
        var onTap: (CGPoint) -> Void = { _ in }
        var onDoubleTap: (() -> Void)?
        var onPressBegan: (CGPoint) -> Void = { _ in }
        var onPressChanged: (CGSize, CGPoint) -> Void = { _, _ in }
        var onPressEnded: (CGSize, CGPoint, Bool) -> Void = { _, _, _ in }
        var origin: CGPoint?
        var pressed = false
        var suppressTapsUntil = Date.distantPast

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            yieldsToSystemDrag
        }

        /// Action text as `public.utf8-plain-text` and `public.plain-text`.
        /// The hot-button drop calls `dropDestination(for: String.self)`, which
        /// reads those same types. A hot-button row publishes nothing.
        func dragInteraction(
            _ interaction: UIDragInteraction,
            itemsForBeginning session: UIDragSession
        ) -> [UIDragItem] {
            guard yieldsToSystemDrag else { return [] }
            let text = dragText
            let provider = NSItemProvider()
            _ = provider.registerObject(text as NSString, visibility: .all)
            for type in [UTType.utf8PlainText, UTType.plainText] {
                provider.registerDataRepresentation(
                    forTypeIdentifier: type.identifier,
                    visibility: .all
                ) { completion in
                    completion(Data(text.utf8), nil)
                    return nil
                }
            }
            let item = UIDragItem(itemProvider: provider)
            item.localObject = text
            return [item]
        }

        @objc func singleTap(_ gesture: UITapGestureRecognizer) {
            guard Date() >= suppressTapsUntil else { return }
            onTap(gesture.location(in: gesture.view))
        }

        @objc func doubleTap() {
            guard Date() >= suppressTapsUntil else { return }
            onDoubleTap?()
        }

        @objc func longPress(_ gesture: UILongPressGestureRecognizer) {
            let location = windowLocation(gesture)
            switch gesture.state {
            case .began:
                origin = location
                pressed = true
                suppressTapsUntil = .distantFuture
                setScrollLocked(true, from: gesture.view)
                onPressBegan(location)
            case .changed:
                guard pressed, let origin else { return }
                onPressChanged(translation(from: origin, to: location), location)
            case .ended:
                guard pressed else { return }
                pressed = false
                let moved = origin.map { translation(from: $0, to: location) } ?? .zero
                origin = nil
                suppressTapsUntil = Date().addingTimeInterval(0.45)
                setScrollLocked(false, from: gesture.view)
                onPressEnded(moved, location, true)
            case .cancelled, .failed:
                guard pressed else { return }
                pressed = false
                let moved = origin.map { translation(from: $0, to: location) } ?? .zero
                origin = nil
                suppressTapsUntil = Date().addingTimeInterval(0.45)
                setScrollLocked(false, from: gesture.view)
                onPressEnded(moved, location, false)
            default:
                break
            }
        }

        /// Window coordinates, same space as the frame probes. A nil window
        /// falls back to the screen, which matches a fullscreen window.
        private func windowLocation(_ gesture: UIGestureRecognizer) -> CGPoint {
            guard let view = gesture.view else { return gesture.location(in: nil) }
            let local = gesture.location(in: view)
            if let window = view.window {
                return view.convert(local, to: window)
            }
            return view.convert(local, to: nil)
        }

        private func translation(from origin: CGPoint, to location: CGPoint) -> CGSize {
            CGSize(width: location.x - origin.x, height: location.y - origin.y)
        }

        /// The scroll view would otherwise take the hold once the finger moves.
        /// Re-enabled when the hold ends. SwiftUI's scrollDisabled follows.
        private func setScrollLocked(_ locked: Bool, from view: UIView?) {
            var current = view?.superview
            while let next = current {
                if let scroll = next as? UIScrollView {
                    scroll.isScrollEnabled = locked == false
                    return
                }
                current = next.superview
            }
        }
    }
}

