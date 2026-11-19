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


/// One play-screen hot button. `text` is the action as the player left it.
/// `icon` is 0, 1, or 2 characters. Empty means the plate is drawn with no glyph.
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

/// Actions and hot buttons together. An action text lives in one list only.
/// Every change goes through `apply`, which drops duplicate keys, caps
/// actions at `shortcutLimit` and hot buttons at `hotLimit`, and takes
/// those hot-button keys out of Actions.
final class ActionMenuStore: ObservableObject {
    static let shortcutLimit = 30
    static let hotLimit = 6
    static let seedText = "get all from corpse"
    /// Match key of the loot line seeded before the command included `from`.
    private static let legacyLootKey = "get all corpse"

    @Published private(set) var shortcuts: [ActionShortcut] = [] {
        didSet { noteEdit() }
    }
    @Published private(set) var buttons: [HotButton] = [] {
        didSet { noteEdit() }
    }

    /// Icon last used for a key during this launch. Moving back to Hot
    /// Buttons restores it. Not written to disk.
    private var rememberedIcons: [String: String] = [:]

    /// True while this device still has the untouched factory lists.
    /// A player edit clears it, and it is never set again. Factory seeds
    /// are not uploaded.
    private var seeded = true
    /// True after this launch, or an earlier one, has reconciled against
    /// a known cloud snapshot. Later updates follow `updatedAt`.
    private var merged = false
    /// Timestamp of the blob this device last wrote or adopted.
    private var updatedAt: TimeInterval = 0
    /// Init and a cloud apply save UserDefaults without mirroring. A real
    /// edit flips this on and then every change is written to both stores.
    private var tracksEdits = false
    private var reconciling = false
    private var reconcileAgain = false
    private var cloudStarted = false
    /// One push after the current turn, so a move that changes both lists
    /// synchronizes the finished pair and not the first assignment.
    private var cloudSyncScheduled = false
    private var cloudObserver: NSObjectProtocol?
    private var identityObserver: NSObjectProtocol?

    private enum Key {
        static let shortcuts = "im.actionShortcuts"
        static let buttons = "im.hotButtons"
    }

    /// Cloud copy of the two local payloads, plus the stamp and the seed
    /// flag. `merged` stays in UserDefaults: it is this device's memory
    /// that the first reconciliation already happened.
    private enum SyncKey {
        static let shortcuts = "im.sync.actionShortcuts"
        static let buttons = "im.sync.hotButtons"
        static let updatedAt = "im.sync.updatedAt"
        static let seeded = "im.sync.seeded"
        static let merged = "im.sync.merged"
    }

    private struct Record: Codable {
        var text: String
        var icon: String
    }

    private static let hotSeed: [HotButton] = [
        HotButton(text: "hit", icon: "H"),
        HotButton(text: "look", icon: "L"),
        HotButton(text: "flee", icon: "F"),
    ]

    init() {
        let defaults = UserDefaults.standard
        let loadedButtons: [HotButton]
        if defaults.object(forKey: Key.buttons) == nil {
            loadedButtons = Self.hotSeed
        } else {
            loadedButtons = Self.migrateLegacyLoot(Self.readButtons(defaults))
        }
        let loadedShortcuts: [ActionShortcut]
        if let stored = defaults.stringArray(forKey: Key.shortcuts) {
            // Count cap plus the legacy loot rewrite. Other saved strings and
            // their order are kept, and a list at or under the limit is whole.
            loadedShortcuts = stored.prefix(Self.shortcutLimit).map { ActionShortcut(text: Self.migratedActionText($0)) }
        } else {
            loadedShortcuts = [ActionShortcut(text: Self.seedText)]
        }
        apply(buttons: loadedButtons, shortcuts: loadedShortcuts)
        saveShortcuts()
        saveButtons()
        loadSyncFlags()
        startCloudSync()
        tracksEdits = true
    }

    deinit {
        let center = NotificationCenter.default
        if let cloudObserver {
            center.removeObserver(cloudObserver)
        }
        if let identityObserver {
            center.removeObserver(identityObserver)
        }
    }

    var canAdd: Bool { shortcuts.count < Self.shortcutLimit }

    /// A blank row at the end of Actions. Nil when Actions is full, or when
    /// a blank row is already in either list.
    @discardableResult
    func addBlank() -> UUID? {
        guard canAdd else { return nil }
        let key = Self.matchKey("")
        if contains(key) { return nil }
        let item = ActionShortcut(text: "")
        var next = shortcuts
        next.append(item)
        apply(buttons: buttons, shortcuts: next)
        return item.id
    }

    func updateShortcut(id: UUID, text: String) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        guard shortcuts[index].text != text else { return }
        let key = Self.matchKey(text)
        let taken = shortcuts.contains { $0.id != id && Self.matchKey($0.text) == key }
            || buttons.contains { Self.matchKey($0.text) == key }
        // One blank only. Clearing this row while that blank already exists
        // cannot be stored, and writing the old text back leaves the last
        // character stuck. Drop the row instead.
        if taken, key.isEmpty {
            removeShortcut(id: id)
            return
        }
        guard taken == false else { return }
        var next = shortcuts
        next[index].text = text
        apply(buttons: buttons, shortcuts: next)
    }

    /// Swipe-to-delete. The row is gone from both lists.
    func removeShortcut(id: UUID) {
        guard shortcuts.contains(where: { $0.id == id }) else { return }
        apply(buttons: buttons, shortcuts: shortcuts.filter { $0.id != id })
    }

    /// Drop one hot button. The words are not copied into Actions.
    func removeButton(id: UUID) {
        guard buttons.contains(where: { $0.id == id }) else { return }
        apply(buttons: buttons.filter { $0.id != id }, shortcuts: shortcuts)
    }

    func moveShortcut(from: Int, to: Int) {
        guard shortcuts.indices.contains(from), shortcuts.indices.contains(to), from != to else { return }
        var next = shortcuts
        let item = next.remove(at: from)
        next.insert(item, at: to)
        apply(buttons: buttons, shortcuts: next)
    }

    func updateIcon(id: UUID, icon: String) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        let clamped = HotButton.clampedIcon(icon)
        guard buttons[index].icon != clamped else { return }
        var next = buttons
        next[index].icon = clamped
        rememberedIcons[Self.matchKey(next[index].text)] = clamped
        apply(buttons: next, shortcuts: shortcuts)
    }

    /// Rewrite one hot button's words in place. The icon and the slot stay.
    /// A key already used by another row is refused, so the command stays in
    /// this list only. Clearing onto the empty key that already exists
    /// removes the button, the same as an action. `apply` writes the button
    /// and syncs `im.sync.hotButtons` with the other edits.
    func updateButtonText(id: UUID, text: String) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        guard buttons[index].text != text else { return }
        let key = Self.matchKey(text)
        let taken = buttons.contains { $0.id != id && Self.matchKey($0.text) == key }
            || shortcuts.contains { Self.matchKey($0.text) == key }
        if taken, key.isEmpty {
            removeButton(id: id)
            return
        }
        guard taken == false else { return }
        var next = buttons
        next[index].text = text
        apply(buttons: next, shortcuts: shortcuts)
    }

    func moveHotButton(from: Int, to: Int) {
        guard buttons.indices.contains(from), buttons.indices.contains(to), from != to else { return }
        var next = buttons
        let item = next.remove(at: from)
        next.insert(item, at: to)
        apply(buttons: next, shortcuts: shortcuts)
    }

    /// Move an Actions row into Hot Buttons. Already there: leave the hot
    /// button where a previous call put it, and drop the Actions copy.
    /// Full and not already there: refuse, and the row stays in Actions.
    @discardableResult
    func moveToHotButtons(text: String, at index: Int, reposition: Bool) -> Bool {
        let key = Self.matchKey(text)
        if let existing = buttons.firstIndex(where: { Self.matchKey($0.text) == key }) {
            var next = buttons
            let item = next.remove(at: existing)
            if reposition {
                let dest = Self.destination(index, removing: existing, count: buttons.count)
                next.insert(item, at: dest)
            } else {
                next.insert(item, at: min(existing, next.count))
            }
            apply(buttons: next, shortcuts: shortcuts)
            return true
        }
        guard buttons.count < Self.hotLimit else { return false }
        let stored = shortcuts.first(where: { Self.matchKey($0.text) == key })?.text ?? text
        let icon = rememberedIcons[key] ?? HotButton.defaultIcon(for: stored)
        var next = buttons
        let dest = min(max(0, index), next.count)
        next.insert(HotButton(text: stored, icon: icon), at: dest)
        apply(buttons: next, shortcuts: shortcuts)
        return true
    }

    /// Move a hot button back into Actions. Already only in Actions: move
    /// that row when `reposition` is set. The stored words are not rewritten.
    /// A new row is refused when Actions is at `shortcutLimit`, and the hot
    /// button stays where it is. Drags and drops both come through here.
    @discardableResult
    func moveToActions(text: String, at index: Int, reposition: Bool) -> Bool {
        let key = Self.matchKey(text)
        let alreadyInActions = shortcuts.contains { Self.matchKey($0.text) == key }
        guard alreadyInActions || shortcuts.count < Self.shortcutLimit else { return false }
        var nextButtons = buttons
        var carried: String?
        if let existing = nextButtons.firstIndex(where: { Self.matchKey($0.text) == key }) {
            let button = nextButtons.remove(at: existing)
            carried = button.text
            rememberedIcons[key] = button.icon
        }
        var nextShortcuts = shortcuts
        if let existing = nextShortcuts.firstIndex(where: { Self.matchKey($0.text) == key }) {
            let item = nextShortcuts.remove(at: existing)
            if reposition {
                let dest = Self.destination(index, removing: existing, count: shortcuts.count)
                nextShortcuts.insert(item, at: dest)
            } else {
                nextShortcuts.insert(item, at: min(existing, nextShortcuts.count))
            }
            apply(buttons: nextButtons, shortcuts: nextShortcuts)
            return true
        }
        let stored = carried ?? shortcuts.first(where: { Self.matchKey($0.text) == key })?.text ?? text
        let dest = min(max(0, index), nextShortcuts.count)
        nextShortcuts.insert(ActionShortcut(text: stored), at: dest)
        apply(buttons: nextButtons, shortcuts: nextShortcuts)
        return true
    }

    @discardableResult
    func moveToActions(id: UUID, at index: Int, reposition: Bool) -> Bool {
        guard let button = buttons.first(where: { $0.id == id }) else { return false }
        return moveToActions(text: button.text, at: index, reposition: reposition)
    }

    private func contains(_ key: String) -> Bool {
        shortcuts.contains { Self.matchKey($0.text) == key }
            || buttons.contains { Self.matchKey($0.text) == key }
    }

    /// Index in the array after `removing` has been taken out.
    /// Index in the array after the row at `removing` has been taken out.
    /// `index` is the slot in the array before that removal. `count` is the
    /// old count, so an index of `count` means the end.
    private static func destination(_ index: Int, removing: Int, count: Int) -> Int {
        var dest = index
        if removing < dest { dest -= 1 }
        return min(max(0, dest), max(0, count - 1))
    }

    /// One write of both lists. Hot buttons keep the first of each key, at
    /// most `hotLimit`. Actions lose any key that is a hot button, then their
    /// own duplicates, and keep at most `shortcutLimit`. The stored text of
    /// a kept row is not edited.
    private func apply(buttons proposedButtons: [HotButton], shortcuts proposedShortcuts: [ActionShortcut]) {
        let nextButtons = Self.uniqueButtons(proposedButtons)
        let hotKeys = Set(nextButtons.map { Self.matchKey($0.text) })
        var seen = Set<String>()
        var nextShortcuts: [ActionShortcut] = []
        for shortcut in proposedShortcuts {
            let key = Self.matchKey(shortcut.text)
            if hotKeys.contains(key) || seen.contains(key) { continue }
            seen.insert(key)
            nextShortcuts.append(shortcut)
            if nextShortcuts.count == Self.shortcutLimit { break }
        }
        if nextButtons != buttons {
            buttons = nextButtons
            saveButtons()
        }
        if nextShortcuts != shortcuts {
            shortcuts = nextShortcuts
            saveShortcuts()
        }
    }

    private static func uniqueButtons(_ buttons: [HotButton]) -> [HotButton] {
        var seen = Set<String>()
        var result: [HotButton] = []
        for button in buttons {
            let key = matchKey(button.text)
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(button)
            if result.count == hotLimit { break }
        }
        return result
    }

    static func matchKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Load-only. The old loot seed becomes `seedText`. Any other text stays.
    /// The key is `matchKey`, the same trim dedupe uses. A hot button keeps
    /// its icon and place. `apply` then drops an Actions row that now shares
    /// a hot-button key, so the command lives in one list.
    private static func migratedActionText(_ text: String) -> String {
        matchKey(text) == legacyLootKey ? seedText : text
    }

    private static func migrateLegacyLoot(_ buttons: [HotButton]) -> [HotButton] {
        buttons.map { button in
            let text = migratedActionText(button.text)
            guard text != button.text else { return button }
            var copy = button
            copy.text = text
            return copy
        }
    }

    private func saveShortcuts() {
        let capped = shortcuts.prefix(Self.shortcutLimit).map(\.text)
        UserDefaults.standard.set(capped, forKey: Key.shortcuts)
    }

    private func saveButtons() {
        guard let data = Self.buttonData(buttons) else { return }
        UserDefaults.standard.set(data, forKey: Key.buttons)
    }

    /// Same JSON `im.hotButtons` already stores: an array of `{text, icon}`.
    private static func buttonData(_ buttons: [HotButton]) -> Data? {
        let records = buttons.map { Record(text: $0.text, icon: HotButton.clampedIcon($0.icon)) }
        return try? JSONEncoder().encode(records)
    }

    /// A present key that does not decode stays empty. That is not the
    /// missing-key case, so the seed is not written back over it.
    private static func readButtons(_ defaults: UserDefaults) -> [HotButton] {
        buttons(from: defaults.data(forKey: Key.buttons))
    }

    private static func buttons(from data: Data?) -> [HotButton] {
        guard let data,
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        return records.map { HotButton(text: $0.text, icon: $0.icon) }
    }

    /// One cloud snapshot. `exists` is false when none of the payload keys
    /// have been written. An empty list under a present key is a real edit.
    private struct CloudLists {
        var buttons: [HotButton]
        var shortcuts: [ActionShortcut]
        var updatedAt: TimeInterval
        var seeded: Bool
        var exists: Bool

        /// Player data. A blob still marked as the factory seed is not one,
        /// and neither is a store that has never been written.
        var hasPlayerData: Bool { exists && seeded == false }
    }

    /// The flag is missing on the first launch after this sync ships.
    /// Lists that are still the factory seed stay seeded. Anything else
    /// was edited before sync existed, so it is eligible to upload.
    private func loadSyncFlags() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SyncKey.seeded) == nil {
            seeded = Self.isFactorySeed(buttons: buttons, shortcuts: shortcuts)
            defaults.set(seeded, forKey: SyncKey.seeded)
        } else {
            seeded = defaults.bool(forKey: SyncKey.seeded)
        }
        merged = defaults.bool(forKey: SyncKey.merged)
        updatedAt = defaults.double(forKey: SyncKey.updatedAt)
    }

    private func storeSyncFlags() {
        let defaults = UserDefaults.standard
        defaults.set(seeded, forKey: SyncKey.seeded)
        defaults.set(merged, forKey: SyncKey.merged)
        defaults.set(updatedAt, forKey: SyncKey.updatedAt)
    }

    /// hit / look / flee, in that order, plus the one loot shortcut.
    /// Text and icon, not row id. A player who edited and then landed
    /// back on these rows is not a seed: the stored flag says so.
    private static func isFactorySeed(buttons: [HotButton], shortcuts: [ActionShortcut]) -> Bool {
        guard shortcuts.map(\.text) == [seedText] else { return false }
        guard buttons.count == hotSeed.count else { return false }
        for (button, seed) in zip(buttons, hotSeed) {
            if button.text != seed.text || button.icon != seed.icon { return false }
        }
        return true
    }

    private var iCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// Signed out: do not read or write the key-value store. Edits stay
    /// in UserDefaults, the same path they used before sync existed.
    private func startCloudSync() {
        if cloudStarted == false {
            cloudStarted = true
            let center = NotificationCenter.default
            let store = NSUbiquitousKeyValueStore.default
            cloudObserver = center.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store,
                queue: OperationQueue.main
            ) { [weak self] note in
                self?.cloudStoreChanged(note)
            }
            identityObserver = center.addObserver(
                forName: NSNotification.Name.NSUbiquityIdentityDidChange,
                object: nil,
                queue: OperationQueue.main
            ) { [weak self] _ in
                self?.iCloudAccountChanged()
            }
        }
        pullCloud()
    }

    private func iCloudAccountChanged() {
        guard iCloudAvailable else { return }
        pullCloud()
    }

    /// Launch read. `synchronize` fetches the ubiquitous store. A cache
    /// that already has keys can merge now. An empty cache waits for
    /// `didChangeExternallyNotification`, which is the initial download.
    private func pullCloud() {
        guard iCloudAvailable else { return }
        let store = NSUbiquitousKeyValueStore.default
        _ = store.synchronize()
        let cloud = readCloud()
        if cloud.exists {
            reconcile(cloud, cloudKnown: true)
        }
    }

    /// External changes only. Applied on the main thread, through `apply`,
    /// so the hot-button cap, the shortcut cap, and the one-list rule hold.
    private func cloudStoreChanged(_ note: Notification) {
        if Thread.isMainThread == false {
            DispatchQueue.main.async { [weak self] in
                self?.cloudStoreChanged(note)
            }
            return
        }
        guard iCloudAvailable else { return }
        let reason = Self.changeReason(in: note)
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange { return }
        // A different iCloud account replaces the store. Reconcile once
        // against that snapshot instead of treating it as a later write.
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            merged = false
            UserDefaults.standard.set(false, forKey: SyncKey.merged)
        }
        let initial = reason == NSUbiquitousKeyValueStoreInitialSyncChange
        let cloud = readCloud()
        if cloud.exists || initial || reason == NSUbiquitousKeyValueStoreAccountChange {
            reconcile(cloud, cloudKnown: true)
        }
    }

    /// First snapshot: upload, adopt, or union. After `merged`, the newer
    /// `updatedAt` replaces both lists. A tied stamp changes nothing.
    private func reconcile(_ cloud: CloudLists, cloudKnown: Bool) {
        if reconciling {
            reconcileAgain = true
            return
        }
        reconciling = true
        reconcileAgain = false
        if merged == false {
            if cloudKnown {
                let upload: Bool
                if cloud.hasPlayerData && seeded {
                    adopt(cloud)
                    upload = false
                } else if cloud.hasPlayerData {
                    let united = Self.unionLists(
                        localButtons: buttons,
                        localShortcuts: shortcuts,
                        cloudButtons: cloud.buttons,
                        cloudShortcuts: cloud.shortcuts
                    )
                    replaceFromSync(buttons: united.buttons, shortcuts: united.shortcuts)
                    seeded = false
                    updatedAt = Date().timeIntervalSince1970
                    upload = true
                } else if seeded == false {
                    if updatedAt <= 0 {
                        updatedAt = Date().timeIntervalSince1970
                    }
                    upload = true
                } else {
                    upload = false
                }
                merged = true
                storeSyncFlags()
                if upload {
                    writeCloud(updatedAt: updatedAt)
                }
            }
        } else if cloud.hasPlayerData == false {
            // No player blob in the cloud. A customized device still uploads,
            // including when this device has never stamped a write.
            if seeded == false && updatedAt <= cloud.updatedAt {
                updatedAt = Date().timeIntervalSince1970
                UserDefaults.standard.set(updatedAt, forKey: SyncKey.updatedAt)
            }
            if seeded == false && updatedAt > cloud.updatedAt {
                writeCloud(updatedAt: updatedAt)
            }
        } else if cloud.updatedAt > updatedAt {
            adopt(cloud)
        } else if cloud.updatedAt < updatedAt && seeded == false {
            writeCloud(updatedAt: updatedAt)
        }
        reconciling = false
        if reconcileAgain {
            reconcileAgain = false
            reconcile(readCloud(), cloudKnown: true)
        }
    }

    /// Take the cloud lists. The seed flag clears first so a crash in
    /// between cannot later treat the adopted rows as an untouched seed.
    private func adopt(_ cloud: CloudLists) {
        seeded = false
        UserDefaults.standard.set(false, forKey: SyncKey.seeded)
        if sameLists(buttons: cloud.buttons, shortcuts: cloud.shortcuts) == false {
            replaceFromSync(buttons: cloud.buttons, shortcuts: cloud.shortcuts)
        }
        updatedAt = cloud.updatedAt
        UserDefaults.standard.set(updatedAt, forKey: SyncKey.updatedAt)
    }

    /// `apply` enforces one text per list and `hotLimit`. `cappedLists`
    /// also stops Actions at `shortcutLimit` before that call, so a blob
    /// from a build with a higher cap cannot keep growing this one.
    private func replaceFromSync(buttons: [HotButton], shortcuts: [ActionShortcut]) {
        let wasTracking = tracksEdits
        tracksEdits = false
        let next = Self.cappedLists(buttons: buttons, shortcuts: shortcuts)
        apply(buttons: next.buttons, shortcuts: next.shortcuts)
        tracksEdits = wasTracking
    }

    /// Compare the lists `apply` would keep, so a cloud payload that is
    /// already on screen does not mint new row ids on every download.
    private func sameLists(buttons proposedButtons: [HotButton], shortcuts proposedShortcuts: [ActionShortcut]) -> Bool {
        let next = Self.cappedLists(buttons: proposedButtons, shortcuts: proposedShortcuts)
        let sameButtons = buttons.map(\.text) == next.buttons.map(\.text)
            && buttons.map(\.icon) == next.buttons.map(\.icon)
        return sameButtons && shortcuts.map(\.text) == next.shortcuts.map(\.text)
    }

    /// Same dedupe as `apply`, then `shortcutLimit`. Hot-button keys leave
    /// Actions. The kept row's text and icon are not rewritten.
    private static func cappedLists(
        buttons proposedButtons: [HotButton],
        shortcuts proposedShortcuts: [ActionShortcut]
    ) -> (buttons: [HotButton], shortcuts: [ActionShortcut]) {
        let nextButtons = uniqueButtons(proposedButtons)
        let hotKeys = Set(nextButtons.map { matchKey($0.text) })
        var seen = Set<String>()
        var nextShortcuts: [ActionShortcut] = []
        for shortcut in proposedShortcuts {
            let key = matchKey(shortcut.text)
            if hotKeys.contains(key) || seen.contains(key) { continue }
            seen.insert(key)
            nextShortcuts.append(shortcut)
            if nextShortcuts.count == shortcutLimit { break }
        }
        return (nextButtons, nextShortcuts)
    }

    /// Hot buttons first, this device's row first, so its icon wins when
    /// both sides have the key. Past `hotLimit`, a hot-button text joins
    /// Actions. Actions then keep the first `shortcutLimit` texts not
    /// already on a hot button.
    private static func unionLists(
        localButtons: [HotButton],
        localShortcuts: [ActionShortcut],
        cloudButtons: [HotButton],
        cloudShortcuts: [ActionShortcut]
    ) -> (buttons: [HotButton], shortcuts: [ActionShortcut]) {
        var seen = Set<String>()
        var mergedButtons: [HotButton] = []
        var overflow: [String] = []
        func considerHot(_ button: HotButton) {
            let key = matchKey(button.text)
            if seen.contains(key) { return }
            if mergedButtons.count < hotLimit {
                seen.insert(key)
                mergedButtons.append(button)
            } else {
                overflow.append(button.text)
            }
        }
        for button in localButtons { considerHot(button) }
        for button in cloudButtons { considerHot(button) }

        var mergedShortcuts: [ActionShortcut] = []
        func considerAction(_ shortcut: ActionShortcut) {
            let key = matchKey(shortcut.text)
            if seen.contains(key) { return }
            if mergedShortcuts.count == shortcutLimit { return }
            seen.insert(key)
            mergedShortcuts.append(shortcut)
        }
        for shortcut in localShortcuts { considerAction(shortcut) }
        for shortcut in cloudShortcuts { considerAction(shortcut) }
        for text in overflow { considerAction(ActionShortcut(text: text)) }
        return (mergedButtons, mergedShortcuts)
    }

    /// A player edit. `apply` has already written UserDefaults. The seed
    /// flag and the stamp are saved immediately. The key-value store is
    /// updated now, and `synchronize` waits until this turn finishes so a
    /// two-list move is one blob.
    private func noteEdit() {
        guard tracksEdits else { return }
        seeded = false
        updatedAt = Date().timeIntervalSince1970
        storeSyncFlags()
        writeCloud(updatedAt: updatedAt, push: false)
        scheduleCloudPush()
    }

    private func scheduleCloudPush() {
        guard cloudSyncScheduled == false, iCloudAvailable else { return }
        cloudSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cloudSyncScheduled = false
            guard self.iCloudAvailable else { return }
            _ = NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    /// No-op when iCloud is signed out, or while the lists are still the
    /// factory seed. Payloads go out first and `updatedAt` last. Nothing
    /// is written unless the hot-button JSON encodes, so a partial blob
    /// cannot wipe the other list.
    private func writeCloud(updatedAt stamp: TimeInterval, push: Bool = true) {
        guard iCloudAvailable, seeded == false else { return }
        guard let data = Self.buttonData(buttons) else { return }
        let store = NSUbiquitousKeyValueStore.default
        let texts = Array(shortcuts.prefix(Self.shortcutLimit).map(\.text))
        store.set(texts, forKey: SyncKey.shortcuts)
        store.set(data, forKey: SyncKey.buttons)
        store.set(false, forKey: SyncKey.seeded)
        store.set(stamp, forKey: SyncKey.updatedAt)
        if push {
            _ = store.synchronize()
        }
    }

    /// The legacy loot line is rewritten here, before `apply`, the same
    /// way a local load rewrites it. A missing payload is an empty list
    /// only when its key is present; absent keys mean the store is empty.
    private func readCloud() -> CloudLists {
        let store = NSUbiquitousKeyValueStore.default
        let shortcutsValue = store.object(forKey: SyncKey.shortcuts)
        let buttonsValue = store.object(forKey: SyncKey.buttons)
        let updatedValue = store.object(forKey: SyncKey.updatedAt)
        let exists = shortcutsValue != nil || buttonsValue != nil || updatedValue != nil
        let texts = (store.array(forKey: SyncKey.shortcuts) ?? []).compactMap { $0 as? String }
        let cloudShortcuts = texts.map { ActionShortcut(text: Self.migratedActionText($0)) }
        let cloudButtons = Self.migrateLegacyLoot(Self.buttons(from: store.data(forKey: SyncKey.buttons)))
        return CloudLists(
            buttons: cloudButtons,
            shortcuts: cloudShortcuts,
            updatedAt: store.double(forKey: SyncKey.updatedAt),
            seeded: store.bool(forKey: SyncKey.seeded),
            exists: exists
        )
    }

    private static func changeReason(in note: Notification) -> Int? {
        guard let value = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}

/// Dark grey card on the right edge, the left settings card mirrored.
/// A leftward swipe from the log's right edge opens it. Shortcuts sit above
/// the hot buttons. The strip is only as tall as the log, so Say, Send,
/// and the name bar keep their taps.
struct ActionSlotsDrawer: View {
    @ObservedObject var menu: ActionMenuStore
    @ObservedObject private var matrixMode = MatrixMode.shared
    /// Toggled by the accessibility action. Each change opens the card.
    @Binding var openRequest: Bool
    /// Global frame of the log between the bars. Empty until the first layout.
    var logFrame: CGRect
    /// Word hilited in the log, appended when a shortcut is sent.
    var hilitedWord: String?
    /// Left-menu switch. On shows the two lines under Actions.
    var showActionHelp: Bool
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
    /// Hot-button words in inline edit. Same field as an action, including Delete.
    @State private var editingButtonID: UUID?
    /// A system drop already placed this drag. The finger-up path must not
    /// place it a second time.
    @State private var dropClaimed = false
    /// Match keys just deleted. The system-drag load finishes after the
    /// finger lifts and would otherwise write that row back.
    @State private var revokedDropKeys: Set<String> = []
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
        // The column is at least as tall as the window and scrolls when the
        // rows overflow. A full Actions list is taller than an iPhone in
        // portrait or landscape, so this is what keeps the last row reachable.
        // The row hold locks this scroll view, so a reorder or a move between
        // Actions and Hot Buttons still follows the finger. Bounce stays off
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
            .onChange(of: editingButtonID) { _, id in
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
                acceptActionDrop(items, at: menu.buttons.count, reposition: false)
            } isTargeted: { targeted in
                setHotDropTargeted(targeted)
            }
            .onDrop(of: [UTType.utf8PlainText, UTType.plainText], isTargeted: $hotDropTargeted) { providers in
                loadActionDrop(providers, at: menu.buttons.count)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                sectionTitle("Actions")
                if menu.canAdd {
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
            if showActionHelp {
                VStack(alignment: .leading, spacing: 2) {
                    helpLine("Hold and drag right to delete")
                    helpLine("Double tap to edit")
                }
            }
        }
    }

    private func helpLine(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(MatrixShade.display(Color(white: 0.62), enabled: matrixMode.enabled))
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
            ForEach(Array(menu.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                shortcutRow(index: index, shortcut: shortcut, width: width)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.rowStride, alignment: .topLeading)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, location in
            acceptActionReturn(items, at: indexForShortcutDrop(location.y))
        } isTargeted: { _ in }
        .onDrop(of: [UTType.utf8PlainText, UTType.plainText], isTargeted: nil) { providers in
            loadActionReturn(providers, at: menu.shortcuts.count)
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
                        onText: { menu.updateShortcut(id: shortcut.id, text: $0) },
                        onCommit: {
                            if editingID == shortcut.id {
                                editingID = nil
                            }
                        },
                        onDelete: { deleteShortcut(shortcut.id) }
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
                                dragLabel: trimmed.isEmpty ? "shortcut" : shortcut.text,
                                dragLabelDimmed: trimmed.isEmpty,
                                onTap: { _ in activate(shortcut, width: width) },
                                onDoubleTap: { editShortcut(shortcut.id) },
                                onPressBegan: { location in
                                    beginDrag(shortcut.id, list: .actions, location: location)
                                },
                                onPressChanged: { translation, location in
                                    updateDrag(translation, location)
                                },
                                onPressEnded: { translation, location, committed in
                                    finishDrag(translation: translation, location: location, committed: committed)
                                },
                                onDragEnded: { translation in
                                    // The lift cancels the hold before the finger
                                    // has moved the delete distance. Finish from
                                    // where the drag actually ended.
                                    guard translation.width >= Metrics.deleteDistance,
                                          translation.width > abs(translation.height) * 1.25 else { return }
                                    deleteShortcut(shortcut.id)
                                }
                            )
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(trimmed.isEmpty ? "Empty shortcut" : shortcut.text)
                        .accessibilityHint(shortcutHint)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { activate(shortcut, width: width) }
                        .accessibilityAction(named: Text("Edit")) { editShortcut(shortcut.id) }
                        .accessibilityAction(named: Text("Delete")) { deleteShortcut(shortcut.id) }
                        .accessibilityAction(named: Text("Move up")) { moveShortcut(shortcut.id, by: -1) }
                        .accessibilityAction(named: Text("Move down")) { moveShortcut(shortcut.id, by: 1) }
                        .accessibilityAction(named: Text("Add to hot buttons")) {
                            menu.moveToHotButtons(
                                text: shortcut.text,
                                at: menu.buttons.count,
                                reposition: true
                            )
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
    /// Double tap the row to edit the words, the same field an action uses,
    /// including Delete. Hold the row to reorder inside this list. A drag
    /// that leaves the list removes only that hot button; the action row is
    /// a different object.
    /// The well keeps a row of height when the list is empty, and it accepts
    /// the action row's `String` drop there.
    private var hotButtonRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.buttons.enumerated()), id: \.element.id) { index, button in
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
            acceptActionDrop(items, at: indexForRowDrop(location.y), reposition: true)
        } isTargeted: { targeted in
            setHotDropTargeted(targeted)
        }
        .onDrop(of: [UTType.utf8PlainText, UTType.plainText], isTargeted: $hotDropTargeted) { providers in
            loadActionDrop(providers, at: menu.buttons.count)
        }
    }

    /// Quiet when the list is empty, so the well is still a visible target.
    /// Brighter while a drop is aimed at it.
    private var hotWellFill: Double {
        if hotDropTargeted || actionDragIntoHotButtons { return 0.12 }
        if menu.buttons.isEmpty { return 0.06 }
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
                    onText: { menu.updateIcon(id: button.id, icon: $0) },
                    onCommit: {
                        // The trash sits outside this field. Resigning on the
                        // touch down would remove it before the touch up lands.
                        DispatchQueue.main.async {
                            if editingIconID == button.id {
                                editingIconID = nil
                            }
                        }
                    }
                )
                .frame(width: 40, height: 32)
                .background(iconPlateFill)
            } else if editingButtonID == button.id {
                iconPlate(button.icon)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingButtonID = nil
                        editingIconID = button.id
                    }
            } else {
                iconPlate(button.icon)
            }
            if editingButtonID == button.id {
                ShortcutEditor(
                    text: button.text,
                    placeholder: "action",
                    fieldLabel: "Hot button text",
                    onText: { menu.updateButtonText(id: button.id, text: $0) },
                    onCommit: {
                        if editingButtonID == button.id {
                            editingButtonID = nil
                        }
                    },
                    onDelete: { deleteHotButton(button.id) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                Text(verbatim: trimmed.isEmpty ? "action" : button.text)
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(Color(white: 0.92).opacity(trimmed.isEmpty ? 0.35 : 1))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            if editingIconID == button.id {
                rowDeleteButton { deleteHotButton(button.id) }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.rowStride)
        .overlay {
            if editingIconID != button.id, editingButtonID != button.id {
                ShortcutRowGestures(
                    yieldsToSystemDrag: true,
                    dragText: button.text,
                    dragLabel: trimmed.isEmpty ? "action" : button.text,
                    dragLabelDimmed: trimmed.isEmpty,
                    dragBadge: button.icon,
                    previewMatrix: matrixMode.enabled,
                    onTap: { point in
                        guard point.x <= Metrics.iconHitWidth else { return }
                        editingID = nil
                        editingButtonID = nil
                        editingIconID = button.id
                    },
                    onDoubleTap: { editHotButtonText(button.id) },
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
        .accessibilityElement(children: editingIconID == button.id || editingButtonID == button.id ? .contain : .ignore)
        .accessibilityLabel(trimmed.isEmpty ? "Empty hot button" : button.text)
        .accessibilityValue(button.icon.isEmpty ? "No icon" : "Icon \(button.icon)")
        .accessibilityHint("Double tap to edit. Drag out of hot buttons to move it back to actions")
        .accessibilityAction(named: Text("Edit")) { editHotButtonText(button.id) }
        .accessibilityAction(named: Text("Edit icon")) {
            editingID = nil
            editingButtonID = nil
            editingIconID = button.id
        }
        .accessibilityAction(named: Text("Delete")) { deleteHotButton(button.id) }
        .accessibilityAction(named: Text("Move up")) { moveHotButton(button.id, by: -1) }
        .accessibilityAction(named: Text("Move down")) { moveHotButton(button.id, by: 1) }
        .accessibilityAction(named: Text("Move to actions")) {
            menu.moveToActions(id: button.id, at: menu.shortcuts.count, reposition: true)
        }
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
            editingButtonID = nil
            heldActive = false
            held = nil
            hotDropTargeted = false
            dropClaimed = false
        }
        withAnimation(.easeOut(duration: 0.22)) {
            travel = open ? width : 0
        }
        guard open != cardOpen else { return }
        cardOpen = open
        onOpenChange(open)
    }

    private func addShortcut() {
        guard let id = menu.addBlank() else { return }
        editShortcut(id)
    }

    /// One editor at a time. Opening an action closes a hot-button field.
    private func editShortcut(_ id: UUID) {
        editingIconID = nil
        editingButtonID = nil
        editingID = id
    }

    /// Same field an action uses, on this hot button. The slot does not move.
    private func editHotButtonText(_ id: UUID) {
        editingID = nil
        editingIconID = nil
        editingButtonID = id
    }

    /// Single tap. A shortcut is sent and the card closes. The joined command
    /// already includes the hilite. Blank text has nothing to send, so the
    /// tap opens the inline editor instead of closing the card.
    private func activate(_ shortcut: ActionShortcut, width: CGFloat) {
        guard let command = ActionShortcut.command(text: shortcut.text, target: hilitedWord) else {
            editShortcut(shortcut.id)
            return
        }
        editingID = nil
        editingIconID = nil
        editingButtonID = nil
        settleCard(open: false, width: width)
        onSend(command)
    }

    private func deleteShortcut(_ id: UUID) {
        if editingID == id {
            editingID = nil
        }
        if let text = menu.shortcuts.first(where: { $0.id == id })?.text {
            let key = ActionMenuStore.matchKey(text)
            revokedDropKeys.insert(key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                revokedDropKeys.remove(key)
            }
        }
        withAnimation(.easeOut(duration: 0.18)) {
            if held?.id == id {
                held = nil
                heldActive = false
            }
            menu.removeShortcut(id: id)
        }
    }

    private func deleteHotButton(_ id: UUID) {
        if editingIconID == id {
            editingIconID = nil
        }
        if editingButtonID == id {
            editingButtonID = nil
        }
        withAnimation(.easeOut(duration: 0.18)) {
            if held?.id == id {
                held = nil
                heldActive = false
            }
            menu.removeButton(id: id)
        }
    }

    /// Trailing trash. Shown while that row's field is up.
    private func rowDeleteButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.9))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete")
    }

    private func moveShortcut(_ id: UUID, by delta: Int) {
        guard let index = menu.shortcuts.firstIndex(where: { $0.id == id }) else { return }
        menu.moveShortcut(from: index, to: index + delta)
    }

    private func moveHotButton(_ id: UUID, by delta: Int) {
        guard let index = menu.buttons.firstIndex(where: { $0.id == id }) else { return }
        menu.moveHotButton(from: index, to: index + delta)
    }

    private func beginDrag(_ id: UUID, list: DragList, location: CGPoint) {
        guard editingID == nil, editingIconID == nil, editingButtonID == nil else { return }
        let index: Int?
        switch list {
        case .actions:
            index = menu.shortcuts.firstIndex(where: { $0.id == id })
        case .hotButtons:
            index = menu.buttons.firstIndex(where: { $0.id == id })
        }
        guard let index else { return }
        dropClaimed = false
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
        // Already past the line. A system drag can cancel the hold on the
        // way out; the row should still go.
        if current.list == .actions, current.axis == .horizontal,
           current.translation.width >= Metrics.deleteDistance {
            deleteShortcut(current.id)
            return
        }
        if committed, current.list == .actions, current.axis == .vertical,
           let shortcut = menu.shortcuts.first(where: { $0.id == current.id }),
           draggedDownIntoHotButtons(
               origin: current.origin,
               translationY: current.translation.height,
               actionCount: menu.shortcuts.count
           ) {
            // Move. A system drop may already have placed it; don't place it again.
            withAnimation(.easeOut(duration: 0.16)) {
                held = nil
                heldActive = false
                if dropClaimed == false {
                    menu.moveToHotButtons(
                        text: shortcut.text,
                        at: menu.buttons.count,
                        reposition: true
                    )
                }
                dropClaimed = false
            }
            return
        }
        if committed, current.list == .actions, current.axis == .vertical,
           let index = menu.shortcuts.firstIndex(where: { $0.id == current.id }) {
            let target = verticalTravel(
                origin: current.origin,
                translationY: current.translation.height,
                count: menu.shortcuts.count
            ).target
            let dest = index + (target - current.origin)
            if menu.shortcuts.indices.contains(dest), dest != index {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    held = nil
                    heldActive = false
                    menu.moveShortcut(from: index, to: dest)
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
                count: menu.buttons.count
            ) {
                // Back to Actions. A drop on the Actions list may already
                // have chosen the slot; otherwise append.
                withAnimation(.easeOut(duration: 0.18)) {
                    held = nil
                    heldActive = false
                    if dropClaimed == false {
                        menu.moveToActions(
                            id: current.id,
                            at: menu.shortcuts.count,
                            reposition: true
                        )
                    }
                    dropClaimed = false
                }
                return
            }
            if let index = menu.buttons.firstIndex(where: { $0.id == current.id }) {
                let target = verticalTravel(
                    origin: current.origin,
                    translationY: current.translation.height,
                    count: menu.buttons.count
                ).target
                let dest = index + (target - current.origin)
                if menu.buttons.indices.contains(dest), dest != index {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        held = nil
                        heldActive = false
                        menu.moveHotButton(from: index, to: dest)
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
        let shortcuts = menu.shortcuts
        guard shortcuts.indices.contains(index) else { return .zero }
        if axis == .horizontal {
            guard shortcuts[index].id == drag.id else { return .zero }
            return CGSize(width: max(0, drag.translation.width), height: 0)
        }
        // A move into Hot Buttons takes the row out of Actions on release.
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
        guard menu.shortcuts.indices.contains(index) else { return 1 }
        guard menu.shortcuts[index].id == drag.id else { return 1 }
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
        let buttons = menu.buttons
        guard buttons.indices.contains(index) else { return .zero }
        if let drag = held, drag.list == .hotButtons {
            return hotDragOffset(index: index, drag: drag, count: buttons.count)
        }
        return .zero
    }

    private func hotDragOffset(index: Int, drag: HeldDrag, count: Int) -> CGSize {
        let buttons = menu.buttons
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
        guard menu.buttons.indices.contains(index) else { return 1 }
        guard menu.buttons[index].id == drag.id else { return 1 }
        if hotDragExited(
            origin: drag.origin,
            translation: drag.translation,
            count: menu.buttons.count
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
            actionCount: menu.shortcuts.count
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

    /// One move into Hot Buttons. A later handler for the same drag must not
    /// insert a second row: `reposition` is false for that follow-up.
    private func acceptActionDrop(_ items: [String], at index: Int, reposition: Bool) -> Bool {
        guard let text = items.first, dropRevoked(text) == false else { return false }
        dropClaimed = true
        return menu.moveToHotButtons(text: text, at: index, reposition: reposition)
    }

    private func acceptActionReturn(_ items: [String], at index: Int) -> Bool {
        guard let text = items.first, dropRevoked(text) == false else { return false }
        dropClaimed = true
        return menu.moveToActions(text: text, at: index, reposition: true)
    }

    /// Same bytes the row's drag registers: `public.utf8-plain-text` and
    /// `public.plain-text`. The load finishes after the drop is accepted, so
    /// this pass does not move a row that is already in the destination.
    private func loadActionDrop(_ providers: [NSItemProvider], at index: Int) -> Bool {
        dropClaimed = true
        return loadTransferredText(providers) { text in
            if self.dropRevoked(text) { return false }
            return self.menu.moveToHotButtons(text: text, at: index, reposition: false)
        }
    }

    private func loadActionReturn(_ providers: [NSItemProvider], at index: Int) -> Bool {
        dropClaimed = true
        return loadTransferredText(providers) { text in
            if self.dropRevoked(text) { return false }
            return self.menu.moveToActions(text: text, at: index, reposition: false)
        }
    }

    /// True when this text was deleted a moment ago. The in-flight drop
    /// load must not insert it again.
    private func dropRevoked(_ text: String) -> Bool {
        revokedDropKeys.contains(ActionMenuStore.matchKey(text))
    }

    private func loadTransferredText(
        _ providers: [NSItemProvider],
        place: @escaping (String) -> Bool
    ) -> Bool {
        guard let provider = providers.first else { return false }
        let identifiers = [UTType.utf8PlainText.identifier, UTType.plainText.identifier]
        guard let type = identifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                _ = place(text)
            }
        }
        return true
    }

    /// Midpoint of each row in the well. The well's local origin is the first
    /// row, including when that row is the empty minimum-height target.
    private func indexForRowDrop(_ localY: CGFloat) -> Int {
        indexForDrop(localY, count: menu.buttons.count)
    }

    private func indexForShortcutDrop(_ localY: CGFloat) -> Int {
        indexForDrop(localY, count: menu.shortcuts.count)
    }

    private func indexForDrop(_ localY: CGFloat, count: Int) -> Int {
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
            guard editingID == id || editingIconID == id || editingButtonID == id else { return }
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
    var placeholder: String = "shortcut"
    var fieldLabel: String = "Shortcut text"
    var onText: (String) -> Void
    var onCommit: () -> Void
    var onDelete: () -> Void

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
        applyChrome(field)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.changed(_:)),
            for: .editingChanged
        )
        let trash = UIButton(type: .system)
        let symbol = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        trash.setImage(UIImage(systemName: "trash.fill", withConfiguration: symbol), for: .normal)
        trash.tintColor = UIColor.systemRed.withAlphaComponent(0.9)
        trash.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        trash.accessibilityLabel = "Delete"
        trash.addTarget(
            context.coordinator,
            action: #selector(Coordinator.deleteTapped),
            for: .touchUpInside
        )
        // A plain button's intrinsic size is the glyph. The container keeps
        // a 44pt target, which is what the field uses for a right view.
        // Inside the field, so the tap does not resign the editor first.
        trash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let slot = UIView(frame: trash.frame)
        slot.addSubview(trash)
        field.rightView = slot
        field.rightViewMode = .always
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

    private func applyChrome(_ field: UITextField) {
        field.accessibilityLabel = fieldLabel
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 0.92, alpha: 0.35)]
        )
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onText = onText
        coordinator.onCommit = onCommit
        coordinator.onDelete = onDelete
        applyChrome(field)
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
        var onDelete: () -> Void = {}
        var applying = false
        var didFocus = false

        @objc func deleteTapped() {
            onDelete()
        }

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

/// Lifted row. The gesture overlay is clear, and an opaque empty snapshot
/// lifts as a black bar. This plate matches the row: dark fill, white
/// label, and, for a hot button, the key badge. An empty badge is still drawn.
private enum DragLiftPlate {
    static let plateColor = UIColor(white: 0.22, alpha: 1)
    static let cornerRadius: CGFloat = 8
    private static let rowHeight: CGFloat = 48
    private static let inset: CGFloat = 8
    private static let badgeSize = CGSize(width: 40, height: 32)
    private static let badgeGap: CGFloat = 10

    static func view(
        label: String,
        dimmed: Bool,
        badge: String?,
        matrix: Bool,
        width: CGFloat
    ) -> UIView {
        let font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        let measured = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let badgeBlock: CGFloat = badge == nil ? 0 : badgeSize.width + badgeGap
        let fitted = max(120, min(360, measured + badgeBlock + inset * 2))
        let barWidth = width > 1 ? width : fitted
        let container = UIView(frame: CGRect(x: 0, y: 0, width: barWidth, height: rowHeight))
        container.backgroundColor = plateColor
        container.isOpaque = true
        container.layer.cornerRadius = cornerRadius
        container.clipsToBounds = true

        var textX = inset
        if let badge {
            let originY = (rowHeight - badgeSize.height) / 2
            let glyph = UILabel(frame: CGRect(x: inset, y: originY, width: badgeSize.width, height: badgeSize.height))
            glyph.text = badge
            glyph.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .bold)
            glyph.textColor = MatrixShade.display(UIColor(white: 0.92, alpha: 1), enabled: matrix)
            glyph.textAlignment = .center
            glyph.backgroundColor = UIColor(white: 1, alpha: 0.12)
            glyph.isOpaque = false
            glyph.layer.cornerRadius = cornerRadius
            glyph.clipsToBounds = true
            glyph.adjustsFontSizeToFitWidth = true
            glyph.minimumScaleFactor = 0.5
            container.addSubview(glyph)
            textX = inset + badgeSize.width + badgeGap
        }

        let title = UILabel(frame: CGRect(x: textX, y: 0, width: max(0, barWidth - textX - inset), height: rowHeight))
        title.text = label
        title.font = font
        title.textColor = UIColor(white: 0.92, alpha: dimmed ? 0.35 : 1)
        title.lineBreakMode = .byTruncatingTail
        title.backgroundColor = .clear
        title.isOpaque = false
        container.addSubview(title)
        return container
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
    /// Words on the lift preview. The overlay itself has no label.
    var dragLabel: String = ""
    var dragLabelDimmed: Bool = false
    /// Nil on an action. A hot button passes its icon, which may be empty.
    var dragBadge: String? = nil
    var previewMatrix: Bool = false
    var onTap: (CGPoint) -> Void
    var onDoubleTap: (() -> Void)?
    var onPressBegan: (CGPoint) -> Void
    var onPressChanged: (CGSize, CGPoint) -> Void
    var onPressEnded: (CGSize, CGPoint, Bool) -> Void
    /// Window translation of a system drag that started here, when it ends.
    /// Nil on a row that should not finish a delete from that drag.
    var onDragEnded: ((CGSize) -> Void)? = nil

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
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
        context.coordinator.dragLabel = dragLabel
        context.coordinator.dragLabelDimmed = dragLabelDimmed
        context.coordinator.dragBadge = dragBadge
        context.coordinator.previewMatrix = previewMatrix
        context.coordinator.onDragEnded = onDragEnded
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
        coordinator.dragLabel = dragLabel
        coordinator.dragLabelDimmed = dragLabelDimmed
        coordinator.dragBadge = dragBadge
        coordinator.previewMatrix = previewMatrix
        coordinator.onTap = onTap
        coordinator.onDoubleTap = onDoubleTap
        coordinator.onPressBegan = onPressBegan
        coordinator.onPressChanged = onPressChanged
        coordinator.onPressEnded = onPressEnded
        coordinator.onDragEnded = onDragEnded
        if let press = uiView.gestureRecognizers?.compactMap({ $0 as? UILongPressGestureRecognizer }).first {
            press.cancelsTouchesInView = yieldsToSystemDrag == false
            press.delegate = coordinator
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIDragInteractionDelegate {
        var yieldsToSystemDrag = false
        var dragText = ""
        var dragLabel = ""
        var dragLabelDimmed = false
        var dragBadge: String?
        var previewMatrix = false
        var onTap: (CGPoint) -> Void = { _ in }
        var onDoubleTap: (() -> Void)?
        var onPressBegan: (CGPoint) -> Void = { _ in }
        var onPressChanged: (CGSize, CGPoint) -> Void = { _, _ in }
        var onPressEnded: (CGSize, CGPoint, Bool) -> Void = { _, _, _ in }
        var onDragEnded: ((CGSize) -> Void)?
        var origin: CGPoint?
        var dragOrigin: CGPoint?
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
            provider.registerObject(text as NSString, visibility: .all)
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
            let label = dragLabel.isEmpty ? text : dragLabel
            let dimmed = dragLabelDimmed
            let badge = dragBadge
            let matrix = previewMatrix
            let rowWidth = interaction.view?.bounds.width ?? 0
            item.previewProvider = {
                let plate = DragLiftPlate.view(
                    label: label,
                    dimmed: dimmed,
                    badge: badge,
                    matrix: matrix,
                    width: rowWidth
                )
                let parameters = UIDragPreviewParameters()
                parameters.backgroundColor = DragLiftPlate.plateColor
                parameters.visiblePath = UIBezierPath(
                    roundedRect: plate.bounds,
                    cornerRadius: DragLiftPlate.cornerRadius
                )
                return UIDragPreview(view: plate, parameters: parameters)
            }
            return [item]
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
            dragOrigin = sessionWindowLocation(session, interaction: interaction)
        }

        func dragInteraction(
            _ interaction: UIDragInteraction,
            session: UIDragSession,
            didEndWith _: UIDropOperation
        ) {
            defer { dragOrigin = nil }
            guard let origin = dragOrigin,
                  let location = sessionWindowLocation(session, interaction: interaction) else { return }
            onDragEnded?(translation(from: origin, to: location))
        }

        /// The row may have slid under the finger. Window space stays put.
        private func sessionWindowLocation(_ session: UIDragSession, interaction: UIDragInteraction) -> CGPoint? {
            guard let view = interaction.view else { return nil }
            let local = session.location(in: view)
            if let window = view.window {
                return view.convert(local, to: window)
            }
            return view.convert(local, to: nil)
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

