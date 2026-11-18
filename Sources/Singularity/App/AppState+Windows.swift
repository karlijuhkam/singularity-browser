import AppKit
import SingularityCore

/// A weak reference to a window (a dictionary can't hold `weak` values directly).
struct WeakWindow {
    weak var window: NSWindow?
}

/// Where a tab opened without a click in a window goes (spec 2026-11-18-multi-window-design.md,
/// "Decided after the builder check").
enum TabTarget {
    /// The front browser window: the owner's own actions (palette, menus, Settings, little windows).
    case front
    /// The window showing this tab (an artifact page's `singularity.open`): a window shared in a
    /// meeting never changes by itself. No window shows it: added to the sidebar, selected nowhere.
    case origin(UUID)
    /// Added to the sidebar, selected in no window.
    case nowhere
}

/// More than one browser window (spec `docs/superpowers/specs/2026-11-18-multi-window-design.md`).
///
/// "The front window is live": `selectedSpaceID` and each `Space.selectedTabID` are what the
/// front browser window shows, exactly as with one window, so everything that acts on "the selected
/// tab" keeps acting on the window the owner is in. Every other window keeps a record
/// (`BrowserWindowState`). When another browser window becomes key, the live fields are written into
/// the old front's record and the new front's record is loaded into them (`activateWindow`). After
/// every change, `reconcileWindows` (Core's `WindowLayout.reconcile`) moves other windows off tabs
/// the front shows, off closed tabs and off deleted Spaces, so a tab is on screen in one window at most.
extension AppState {
    enum ResolvedTarget: Equatable { case front, window(UUID), nowhere }

    // MARK: - Reading

    /// Whether `windowID` is the front window. nil (a view outside any window scene, as in tests)
    /// counts as the front one.
    func isFront(_ windowID: UUID?) -> Bool {
        windowID == nil || windowID == frontWindowID || frontWindowID == nil
    }

    private func record(_ id: UUID?) -> BrowserWindowState? {
        guard let id else { return nil }
        return windows.first { $0.id == id }
    }

    /// The Space a window shows.
    /// For a window that isn't the front one, a copy whose `selectedTabID` is that window's own
    /// selection, so views that read `space.selectedTabID` (rows, splits, the home) show the
    /// window's selection without knowing about windows.
    func shownSpace(in windowID: UUID?) -> Space? {
        if isFront(windowID) { return selectedSpace }
        guard let record = record(windowID), let spaceID = record.spaceID, var space = space(spaceID) else { return nil }
        space.selectedTabID = record.selectedTabIDs[spaceID]
        return space
    }

    /// The tab a window has selected in `space` (the Space it shows).
    func shownTabID(in windowID: UUID?, space: Space) -> UUID? {
        if isFront(windowID) { return space.selectedTabID }
        return record(windowID)?.selectedTabIDs[space.id]
    }

    /// The tab a window shows (its selected tab; the whole split it is in is on screen too).
    func shownTab(in windowID: UUID?) -> BrowserTab? {
        guard let space = shownSpace(in: windowID) else { return nil }
        return shownTabID(in: windowID, space: space).flatMap { space.tab($0) }
    }

    /// Every tab on screen in a window: its selected tab and that tab's split.
    func shownTabIDs(in windowID: UUID?) -> Set<UUID> {
        guard let space = shownSpace(in: windowID) else { return [] }
        return WindowLayout.shownTabIDs(in: space, selected: shownTabID(in: windowID, space: space))
    }

    /// The window a tab is on screen in (the front one first), nil when none.
    func windowIDShowing(_ tabID: UUID) -> UUID? {
        if selectedSpace?.visibleTabIDs.contains(tabID) == true { return frontWindowID }
        return windows.first { $0.id != frontWindowID && shownTabIDs(in: $0.id).contains(tabID) }?.id
    }

    func isTabShownInAnyWindow(_ tabID: UUID) -> Bool {
        selectedSpace?.visibleTabIDs.contains(tabID) == true
            || windows.contains { $0.id != frontWindowID && shownTabIDs(in: $0.id).contains(tabID) }
    }

    /// Selected (focused) in some window: the front's `Space.selectedTabID`, or a record's.
    func isTabSelectedInAnyWindow(_ tabID: UUID, spaceID: UUID) -> Bool {
        if space(spaceID)?.selectedTabID == tabID, selectedSpaceID == spaceID { return true }
        return windows.contains { $0.id != frontWindowID && $0.spaceID == spaceID && $0.selectedTabIDs[spaceID] == tabID }
    }

    func sidebarHidden(in windowID: UUID?) -> Bool {
        record(windowID ?? frontWindowID)?.sidebarHidden ?? settings.sidebarHidden
    }

    /// The welcome flow covers this window (the one it was opened in).
    func welcomeCovers(_ windowID: UUID?) -> Bool {
        guard onboarding != nil else { return false }
        let covered = onboardingWindowID ?? frontWindowID
        return covered == nil || (windowID ?? frontWindowID) == covered
    }

    /// The window the plugin's panel is drawn in.
    func panelIsIn(_ windowID: UUID?) -> Bool {
        let owner = panelWindowID.flatMap { id in windows.contains { $0.id == id } ? id : nil } ?? frontWindowID
        return owner == nil || (windowID ?? frontWindowID) == owner
    }

    /// The front browser window's NSWindow (extensions, sheets, the sidebar's slide-out, the inbox).
    var mainWindow: NSWindow? {
        if let id = frontWindowID, let window = nsWindows[id]?.window { return window }
        return nsWindows.values.lazy.compactMap(\.window).first { $0.isVisible }
    }

    func nsWindow(for id: UUID) -> NSWindow? { nsWindows[id]?.window }

    // MARK: - Launch and saving

    /// `state.json`'s windows, or one window made from the older fields. Called from `init`.
    func restoreWindows(from file: AppStateFile) {
        var restored = file.windows
        if restored.isEmpty {
            var selected: [UUID: UUID] = [:]
            for space in spaces { if let tab = space.selectedTabID { selected[space.id] = tab } }
            restored = [BrowserWindowState(spaceID: selectedSpaceID, selectedTabIDs: selected,
                                           sidebarHidden: settings.sidebarHidden)]
        }
        windows = restored
        let front = file.frontWindowID.flatMap { id in restored.first { $0.id == id } } ?? restored[0]
        frontWindowID = front.id
        loadIntoLiveFields(front)
        reconcileWindows()
    }

    /// The records as they are now, the front one brought up to date from the live fields.
    func windowsForSaving() -> [BrowserWindowState] {
        windows.map { $0.id == frontWindowID ? liveRecord(of: $0) : $0 }
    }

    private func liveRecord(of window: BrowserWindowState) -> BrowserWindowState {
        var record = window
        record.spaceID = selectedSpaceID
        for space in spaces {
            if let tab = space.selectedTabID { record.selectedTabIDs[space.id] = tab }
        }
        return record
    }

    /// Puts a record's Space and selections into the live fields (without the side effects of
    /// selecting: this is a window coming forward, not the owner going to a tab).
    private func loadIntoLiveFields(_ record: BrowserWindowState) {
        // Half-swapped, the live fields would describe no window; the rule must not run on them.
        let wasReconciling = reconcilingWindows
        reconcilingWindows = true
        defer { reconcilingWindows = wasReconciling }
        if let spaceID = record.spaceID, space(spaceID) != nil { setLiveSpace(spaceID) }
        for (spaceID, tabID) in record.selectedTabIDs {
            guard let space = space(spaceID), space.tab(tabID) != nil, space.selectedTabID != tabID else { continue }
            mutateSpace(spaceID) { $0.selectedTabID = tabID }
        }
        // The Space it shows with nothing selected (its home): exactly that, never the tab another
        // window left in the live field.
        if let spaceID = record.spaceID, record.selectedTabIDs[spaceID] == nil, space(spaceID)?.selectedTabID != nil {
            mutateSpace(spaceID) { $0.selectedTabID = nil }
        }
        if settings.sidebarHidden != record.sidebarHidden {
            updateSettings { $0.sidebarHidden = record.sidebarHidden }
        }
    }

    // MARK: - The front window

    /// Another browser window became key: it is the front one now (the swap described above).
    /// Not `selectSpace`/`selectTab`: a window coming forward is not the owner going to a tab, so
    /// inbox entries stay and the "previous tab" for ⌘\ doesn't change.
    func activateWindow(_ id: UUID) {
        guard id != frontWindowID, let index = windows.firstIndex(where: { $0.id == id }) else { return }
        if let old = windows.firstIndex(where: { $0.id == frontWindowID }) {
            windows[old] = liveRecord(of: windows[old])
        }
        frontWindowID = id
        sidebarPeek.close()
        loadIntoLiveFields(windows[index])
        stateFileDirty = true
        scheduleSave()
        reconcileWindows()
        loadSelectedTab()
        applyWindowButtons()
    }

    /// The front window's Space shows a tab that another window has on screen (after a Space switch
    /// or a Space deleted): pick a free one instead. Taking a tab over is only for a click on it.
    func keepFrontOffOtherWindows() {
        guard let space = selectedSpace, let selected = space.selectedTabID else { return }
        let taken = takenByOtherWindows(spaceID: space.id, except: frontWindowID)
        guard !WindowLayout.shownTabIDs(in: space, selected: selected).isDisjoint(with: taken) else { return }
        let free = WindowLayout.freeTab(in: space, preferring: selected, taken: taken)
        let wasReconciling = reconcilingWindows
        reconcilingWindows = true
        defer { reconcilingWindows = wasReconciling }
        mutateSpace(space.id) { $0.selectedTabID = free }
    }

    /// Tabs of a Space on screen in windows other than `except` (records only, plus the live
    /// front when it isn't `except`).
    private func takenByOtherWindows(spaceID: UUID, except: UUID?) -> Set<UUID> {
        var taken: Set<UUID> = []
        for window in windows where window.id != except {
            guard let space = space(spaceID) else { break }
            if window.id == frontWindowID {
                if selectedSpaceID == spaceID { taken.formUnion(space.visibleTabIDs) }
            } else if window.spaceID == spaceID {
                taken.formUnion(WindowLayout.shownTabIDs(in: space, selected: window.selectedTabIDs[spaceID]))
            }
        }
        return taken
    }

    /// Applies the one-place rule to every window but the front one. Called at the end of every
    /// change of Spaces or selection, in the same turn, so SwiftUI never draws one tab twice.
    func reconcileWindows() {
        guard !reconcilingWindows, windows.count > 1 else { return }
        reconcilingWindows = true
        defer { reconcilingWindows = false }
        let fixed = WindowLayout.reconcile(windows, frontID: frontWindowID, frontSpaceID: selectedSpaceID,
                                           frontSelected: selectedSpace?.selectedTabID, spaces: spaces)
        guard fixed != windows else { return }
        windows = fixed
        stateFileDirty = true
        scheduleSave()
        loadBackgroundWindows()
    }

    /// Makes the tabs on screen in windows other than the front one live (web views, shells,
    /// artifact servers). The front's are loaded by `loadSelectedTab`.
    func loadBackgroundWindows() {
        for window in windows where window.id != frontWindowID {
            guard let spaceID = window.spaceID, let space = space(spaceID) else { continue }
            let shown = WindowLayout.shownTabIDs(in: space, selected: window.selectedTabIDs[spaceID])
            guard !shown.isEmpty else { continue }
            if artifacts.host(space.id) == nil, space.tabs.contains(where: { $0.artifactPath != nil }) {
                Task { _ = await ensureArtifactHost(space) }
            }
            for tabID in shown {
                if let tab = space.tab(tabID) { loadTab(tab, in: space) }
            }
        }
    }

    // MARK: - Tabs opened without a click

    func resolve(_ target: TabTarget) -> ResolvedTarget {
        switch target {
        case .front: return .front
        case .nowhere: return .nowhere
        case .origin(let tabID):
            guard let windowID = windowIDShowing(tabID) else { return .nowhere }
            return isFront(windowID) ? .front : .window(windowID)
        }
    }

    /// Selects a tab in a window that isn't the front one (its record), then keeps the rest apart.
    func selectInBackground(_ tabID: UUID, spaceID: UUID, windowID: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == windowID }), windows[index].spaceID == spaceID else { return }
        windows[index].selectedTabIDs[spaceID] = tabID
        stateFileDirty = true
        scheduleSave()
        // The front window keeps what it shows; if it showed this tab, the background window
        // gets another one from the rule (the front always wins).
        reconcileWindows()
        loadBackgroundWindows()
    }

    // MARK: - Opening and closing

    /// File → New Window: a record on the front window's Space, showing that Space's last tab only
    /// when no window shows it (otherwise its home). Not front until its NSWindow becomes key.
    @discardableResult
    func addWindow() -> UUID {
        if let front = windows.firstIndex(where: { $0.id == frontWindowID }) {
            windows[front] = liveRecord(of: windows[front])
        }
        let spaceID = selectedSpaceID ?? spaces.first?.id
        var window = BrowserWindowState(spaceID: spaceID)
        if let spaceID, let space = space(spaceID), let last = space.selectedTabID {
            let taken = takenByOtherWindows(spaceID: spaceID, except: nil)
            if WindowLayout.shownTabIDs(in: space, selected: last).isDisjoint(with: taken) {
                window.selectedTabIDs[spaceID] = last
            }
        }
        windows.append(window)
        stateFileDirty = true
        scheduleSave()
        return window.id
    }

    /// File → New Window (⌘N) and the palette: a new record, then its window.
    func newWindow() {
        closeWelcomeIfFrontCovered()
        let id = addWindow()
        openBrowserWindow?(id)
    }

    private func closeWelcomeIfFrontCovered() {
        if welcomeCoversWindow { closeWelcome() }
    }

    /// The window a new SwiftUI scene shows: `requested` when it is a record no scene shows yet,
    /// else the first such record. nil when every record is shown: a window SwiftUI restored by
    /// itself, which then closes (a new record for it would add a window at every launch).
    func claimWindow(_ requested: UUID?) -> UUID? {
        let chosen: UUID?
        if let requested, windows.contains(where: { $0.id == requested }), !claimedWindowIDs.contains(requested) {
            chosen = requested
        } else {
            chosen = windows.first { !claimedWindowIDs.contains($0.id) }?.id
        }
        if let chosen { claimedWindowIDs.insert(chosen) }
        return chosen
    }

    /// Records no scene shows yet (opened by the first window at launch).
    func unclaimedWindowIDs() -> [UUID] {
        windows.map(\.id).filter { !claimedWindowIDs.contains($0) }
    }

    /// A window's NSWindow, once its view is in it.
    func registerWindow(_ window: NSWindow, for id: UUID) {
        guard nsWindows[id]?.window !== window else { return }
        nsWindows[id] = WeakWindow(window: window)
        mainWindowWasShown = true
        applyWindowButtons()
    }

    /// A browser window was closed. Its tabs stay in their Spaces. The last window keeps its record
    /// (closing it quits the app, and the next launch opens it again).
    func windowClosed(_ id: UUID) {
        nsWindows[id] = nil
        claimedWindowIDs.remove(id)
        guard !isTerminating, windows.count > 1, let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let wasFront = id == frontWindowID
        windows.remove(at: index)
        if panelWindowID == id { panelWindowID = nil }
        if onboardingWindowID == id { onboardingWindowID = nil }
        stateFileDirty = true
        scheduleSave()
        guard wasFront else { return }
        // The next window: one still on screen, else any record.
        frontWindowID = nil
        let next = windows.first { nsWindows[$0.id]?.window?.isVisible == true } ?? windows.first
        if let next { activateWindow(next.id) }
    }

    /// A window moved or was resized.
    func windowFrameChanged(_ id: UUID, frame: NSRect) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        let new = WindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.size.width, height: frame.size.height)
        guard windows[index].frame != new else { return }
        windows[index].frame = new
        stateFileDirty = true
        scheduleSave()
    }

    /// The front window's sidebar (⌘S). Settings keep a copy so an older version opens the same way.
    func setFrontSidebarHidden(_ hidden: Bool) {
        if let index = windows.firstIndex(where: { $0.id == frontWindowID }) {
            windows[index].sidebarHidden = hidden
            stateFileDirty = true
            scheduleSave()
        }
        updateSettings { $0.sidebarHidden = hidden }
        applyWindowButtons()
    }
}
