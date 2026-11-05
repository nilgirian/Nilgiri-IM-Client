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

/// Dark grey card on the right edge, the left settings card mirrored.
/// A leftward swipe from the log's right edge opens it. Three pull-downs
/// assign the slots. The strip is only as tall as the log, so Say, Send,
/// and the name bar keep their taps.
struct ActionSlotsDrawer: View {
    @ObservedObject var store: ActionSlotStore
    /// Toggled by the accessibility action. Each change opens the card.
    @Binding var openRequest: Bool
    /// Global frame of the log between the bars. Empty until the first layout.
    var logFrame: CGRect
    /// The card settled open or closed. Not called during the drag, so a swipe
    /// that slides back shut does not dismiss the keyboard and bring it back.
    var onOpenChange: (Bool) -> Void

    /// Dark grey, see-through, so the log shows behind the card.
    private static let menuGrey = Color(white: 0.22).opacity(0.55)

    @State private var travel: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var ignoreDrag = false
    /// Last settled open bit already reported through `onOpenChange`.
    @State private var cardOpen = false

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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Text("Actions")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.62))
                ForEach(0..<ActionSlotStore.count, id: \.self) { index in
                    slotRow(index)
                }
            }
            .font(.system(size: 17))
            .foregroundStyle(Color(white: 0.92))
            .padding(.trailing, insets.right + 20)
            .padding(.leading, 18)
            .padding(.top, insets.top + 24)
            .padding(.bottom, insets.bottom + 20)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The drawer already pads for the notch. A scroll view would add that
        // inset again and leave a gap above Actions.
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
            .tint(Color(white: 0.78))
        }
    }

    /// Opens from the right edge, or follows a finger that is already dragging the card.
    /// A vertical move that starts while the card is closed is left alone.
    private func pan(width: CGFloat, fromEdgeOnly: Bool) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(Self.space))
            .onChanged { value in
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
                ignoreDrag = false
                guard let origin else { return }
                let predicted = origin - value.predictedEndTranslation.width
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
