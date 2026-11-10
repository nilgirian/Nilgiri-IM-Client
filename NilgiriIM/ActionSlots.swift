import SwiftUI
import UIKit

/// One assignable right-edge action. `blank` shows no icon and sends nothing.
/// The letter is a bold system glyph. `hit` uses H; the issue named letters
/// for kick, backstab, look, flee, and drink, and left hit to match that set.
enum SkillAction: String, CaseIterable, Identifiable {
    case blank
    case hit
    case kick
    case backstab
    case look
    case flee
    case drink

    var id: String { rawValue }

    /// Pull-down title. The word is the command, so it stays lowercase.
    var menuTitle: String { rawValue }

    var letter: String? {
        switch self {
        case .blank: return nil
        case .hit: return "H"
        case .kick: return "K"
        case .backstab: return "B"
        case .look: return "L"
        case .flee: return "F"
        case .drink: return "D"
        }
    }

    /// `kick`, or `kick guard` when a word is hilited. Nil for a blank slot.
    /// The hilite is sent as stored. A missing hilite sends the verb alone.
    func command(target: String?) -> String? {
        guard self != .blank else { return nil }
        let name = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { return rawValue }
        return rawValue + " " + name
    }
}

/// Three action slots. Missing or unknown values stay blank. A change writes
/// `im.actionSlots` so the icons are still there after a relaunch.
final class ActionSlotStore: ObservableObject {
    static let count = 3

    @Published var slots: [SkillAction] {
        didSet { save() }
    }

    private enum Key {
        static let slots = "im.actionSlots"
    }

    init() {
        slots = Self.load()
    }

    func binding(at index: Int) -> Binding<SkillAction> {
        Binding(
            get: {
                guard self.slots.indices.contains(index) else { return .blank }
                return self.slots[index]
            },
            set: { newValue in
                guard self.slots.indices.contains(index) else { return }
                guard self.slots[index] != newValue else { return }
                self.slots[index] = newValue
            }
        )
    }

    private func save() {
        UserDefaults.standard.set(slots.map(\.rawValue), forKey: Key.slots)
    }

    private static func load() -> [SkillAction] {
        guard let raw = UserDefaults.standard.stringArray(forKey: Key.slots) else {
            return Array(repeating: .blank, count: count)
        }
        var loaded = raw.prefix(count).map { SkillAction(rawValue: $0) ?? .blank }
        while loaded.count < count {
            loaded.append(.blank)
        }
        return loaded
    }
}

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

/// Dark grey card on the right edge, the left settings card mirrored.
/// A leftward swipe from the log's right edge opens it. Shortcuts sit above
/// the three pull-downs. The strip is only as tall as the log, so Say, Send,
/// and the name bar keep their taps.
struct ActionSlotsDrawer: View {
    @ObservedObject var store: ActionSlotStore
    @ObservedObject var shortcutStore: ActionShortcutStore
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
    }

    /// Row being held. Nil when no shortcut drag is in progress.
    private struct ShortcutDrag {
        enum Axis { case horizontal, vertical }
        var id: UUID
        var origin: Int
        var translation: CGSize
        var axis: Axis?
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
    /// Hold-and-drag on a shortcut. While set, the card's own pan stays put.
    @State private var shortcutDrag: ShortcutDrag?
    /// True from the long-press began until the finger lifts.
    @State private var shortcutDragActive = false

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
        // window scrolls instead of clipping the last slot. Bounce stays off
        // while nothing overflows.
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        actionsHeader
                        shortcutRows(width: width)
                    }
                    sectionDivider
                    sectionTitle("Hot Buttons")
                    ForEach(0..<ActionSlotStore.count, id: \.self) { index in
                        slotRow(index)
                    }
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
            .scrollDisabled(shortcutDragActive)
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
        }
        .ignoresSafeArea()
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Self.menuGrey)
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
        let offset = rowOffset(index: index)
        let dragging = shortcutDrag?.id == shortcut.id
        let deleting = dragging && shortcutDrag?.axis == .horizontal
        let trimmed = shortcut.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ZStack(alignment: .leading) {
            if deleting {
                Text("Delete")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .opacity(min(1, max(0, (shortcutDrag?.translation.width ?? 0) / Metrics.deleteDistance)))
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
                                onTap: { activate(shortcut, width: width) },
                                onDoubleTap: { editingID = shortcut.id },
                                onPressBegan: { beginDrag(shortcut) },
                                onPressChanged: { updateDrag($0) },
                                onPressEnded: { translation, committed in
                                    finishDrag(translation: translation, committed: committed)
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
                }
            }
            .offset(offset)
            .background(deleting ? Color(white: 0.22) : Color.clear)
            .opacity(rowOpacity(index: index))
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

    /// Slot name on the left, pull-down of the action on the right.
    private func slotRow(_ index: Int) -> some View {
        HStack(spacing: 12) {
            Text("Slot \(index + 1)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Slot \(index + 1)", selection: store.binding(at: index)) {
                ForEach(SkillAction.allCases) { action in
                    Text(verbatim: action.menuTitle).tag(action)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(MatrixShade.display(Color(white: 0.78), enabled: matrixMode.enabled))
        }
    }

    /// Opens from the right edge, or follows a finger that is already dragging the card.
    /// A vertical move that starts while the card is closed is left alone.
    private func pan(width: CGFloat, fromEdgeOnly: Bool) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(Self.space))
            .onChanged { value in
                // A held shortcut owns the finger. The card must not follow it shut.
                if shortcutDragActive {
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
                let blocked = ignoreDrag || shortcutDragActive
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
            shortcutDragActive = false
            shortcutDrag = nil
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
        editingID = id
    }

    /// Single tap. A shortcut is sent and the card closes. The joined command
    /// already includes the hilite. Blank text has nothing to send, so the
    /// tap opens the inline editor instead of closing the card.
    private func activate(_ shortcut: ActionShortcut, width: CGFloat) {
        guard let command = ActionShortcut.command(text: shortcut.text, target: hilitedWord) else {
            editingID = shortcut.id
            return
        }
        editingID = nil
        settleCard(open: false, width: width)
        onSend(command)
    }

    private func deleteShortcut(_ id: UUID) {
        if editingID == id {
            editingID = nil
        }
        withAnimation(.easeOut(duration: 0.18)) {
            if shortcutDrag?.id == id {
                shortcutDrag = nil
                shortcutDragActive = false
            }
            shortcutStore.remove(id: id)
        }
    }

    private func moveShortcut(_ id: UUID, by delta: Int) {
        guard let index = shortcutStore.shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcutStore.move(from: index, to: index + delta)
    }

    private func beginDrag(_ shortcut: ActionShortcut) {
        guard editingID == nil else { return }
        guard let index = shortcutStore.shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcutDragActive = true
        shortcutDrag = ShortcutDrag(id: shortcut.id, origin: index, translation: .zero, axis: nil)
    }

    private func updateDrag(_ translation: CGSize) {
        guard var current = shortcutDrag else { return }
        current.axis = lockedAxis(for: translation, current: current.axis)
        current.translation = translation
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            shortcutDrag = current
        }
    }

    private func finishDrag(translation: CGSize, committed: Bool) {
        guard var current = shortcutDrag else { return }
        guard cardOpen else {
            shortcutDrag = nil
            shortcutDragActive = false
            return
        }
        current.translation = translation
        if current.axis == nil {
            current.axis = lockedAxis(for: translation, current: nil)
        }
        if committed, current.axis == .horizontal,
           current.translation.width >= Metrics.deleteDistance {
            deleteShortcut(current.id)
            return
        }
        if committed, current.axis == .vertical,
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
                    shortcutDrag = nil
                    shortcutDragActive = false
                    shortcutStore.move(from: index, to: dest)
                }
                return
            }
        }
        withAnimation(.easeOut(duration: 0.16)) {
            shortcutDrag = nil
            shortcutDragActive = false
        }
    }

    /// Rightward travel deletes. Vertical travel reorders. A leftward move
    /// is neither: the card pan is already suppressed for this hold.
    private func lockedAxis(for translation: CGSize, current: ShortcutDrag.Axis?) -> ShortcutDrag.Axis? {
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

    private func rowOffset(index: Int) -> CGSize {
        guard let drag = shortcutDrag, let axis = drag.axis else { return .zero }
        let shortcuts = shortcutStore.shortcuts
        guard shortcuts.indices.contains(index) else { return .zero }
        if axis == .horizontal {
            guard shortcuts[index].id == drag.id else { return .zero }
            return CGSize(width: max(0, drag.translation.width), height: 0)
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

    private func rowOpacity(index: Int) -> Double {
        guard let drag = shortcutDrag, drag.axis == .horizontal else { return 1 }
        guard shortcutStore.shortcuts.indices.contains(index) else { return 1 }
        guard shortcutStore.shortcuts[index].id == drag.id else { return 1 }
        let progress = min(1, max(0, drag.translation.width / Metrics.deleteDistance))
        return 1 - 0.45 * progress
    }

    /// Puts the editing row near the top of the card, above the keyboard.
    /// The scroll view ignores the safe area, so a center anchor can sit
    /// under the keys on a short landscape window.
    private func scrollEditingRow(_ id: UUID, proxy: ScrollViewProxy) {
        func align() {
            guard editingID == id else { return }
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

/// Tap, double tap, and hold on one shortcut row. The single tap waits until
/// the double tap fails, so an edit does not also send. A hold that already
/// began swallows the tap that follows the finger lifting.
private struct ShortcutRowGestures: UIViewRepresentable {
    var onTap: () -> Void
    var onDoubleTap: () -> Void
    var onPressBegan: () -> Void
    var onPressChanged: (CGSize) -> Void
    var onPressEnded: (CGSize, Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let single = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.singleTap)
        )
        single.numberOfTapsRequired = 1
        single.cancelsTouchesInView = false
        let double = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.doubleTap)
        )
        double.numberOfTapsRequired = 2
        double.cancelsTouchesInView = false
        single.require(toFail: double)
        let press = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.longPress(_:))
        )
        press.minimumPressDuration = 0.35
        press.cancelsTouchesInView = true
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(press)
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
        coordinator.onTap = onTap
        coordinator.onDoubleTap = onDoubleTap
        coordinator.onPressBegan = onPressBegan
        coordinator.onPressChanged = onPressChanged
        coordinator.onPressEnded = onPressEnded
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onTap: () -> Void = {}
        var onDoubleTap: () -> Void = {}
        var onPressBegan: () -> Void = {}
        var onPressChanged: (CGSize) -> Void = { _ in }
        var onPressEnded: (CGSize, Bool) -> Void = { _, _ in }
        var origin: CGPoint?
        var pressed = false
        var suppressTapsUntil = Date.distantPast

        @objc func singleTap() {
            guard Date() >= suppressTapsUntil else { return }
            onTap()
        }

        @objc func doubleTap() {
            guard Date() >= suppressTapsUntil else { return }
            onDoubleTap()
        }

        @objc func longPress(_ gesture: UILongPressGestureRecognizer) {
            let location = gesture.location(in: gesture.view?.window)
            switch gesture.state {
            case .began:
                origin = location
                pressed = true
                suppressTapsUntil = .distantFuture
                setScrollLocked(true, from: gesture.view)
                onPressBegan()
            case .changed:
                guard pressed, let origin else { return }
                onPressChanged(translation(from: origin, to: location))
            case .ended:
                guard pressed else { return }
                pressed = false
                let translation = origin.map { translation(from: $0, to: location) } ?? .zero
                origin = nil
                suppressTapsUntil = Date().addingTimeInterval(0.45)
                setScrollLocked(false, from: gesture.view)
                onPressEnded(translation, true)
            case .cancelled, .failed:
                guard pressed else { return }
                pressed = false
                let translation = origin.map { translation(from: $0, to: location) } ?? .zero
                origin = nil
                suppressTapsUntil = Date().addingTimeInterval(0.45)
                setScrollLocked(false, from: gesture.view)
                onPressEnded(translation, false)
            default:
                break
            }
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
