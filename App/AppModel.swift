import SwiftUI
import GRDB
import Observation
import MacBenchCore

/// Read before `AppModel` exists, so it cannot live on the type.
private let streamVisibleKey = "stream.visible"
private let fileSortKey = "files.sort"

enum Selection: Hashable {
    case activity
    case openTasks
    case project(UUID)
    case node(UUID)

    /// A short stable string, so the selection and the open folders survive a
    /// relaunch without dragging a Codable conformance through the view layer.
    var token: String {
        switch self {
        case .activity: "activity"
        case .openTasks: "tasks"
        case .project(let id): "p:\(id.uuidString)"
        case .node(let id): "n:\(id.uuidString)"
        }
    }

    init?(token: String) {
        switch token {
        // "unread" is what this list was called until it stopped being about
        // what you had read. A layout stored under the old name still opens it.
        case "activity", "unread": self = .activity
        case "tasks": self = .openTasks
        default:
            let parts = token.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
            switch parts[0] {
            case "p": self = .project(id)
            case "n": self = .node(id)
            default: return nil
            }
        }
    }
}

/// One part of the path in the header of the middle column: what it is called,
/// and what selecting it would mean.
struct Crumb: Identifiable, Hashable {
    var id: Int
    var name: String
    /// Nil where there is nowhere to go: the file at the end of the path.
    var target: Selection?
}

/// One row of the sidebar tree. Only folders appear here — files live in the
/// right-hand column, so the tree stays the shape of the work rather than a
/// second Finder.
struct TreeItem: Identifiable, Hashable {
    var id: Selection
    var title: String
    var path: String
    var projectID: UUID
    var isProject: Bool
    var children: [TreeItem]?
}

@MainActor
@Observable
final class AppModel {

    // MARK: - State

    private(set) var store: Store
    private(set) var identity: LocalIdentity?
    private(set) var isReady = false

    var projects: [Project] = []
    var members: [Member] = []
    var categories: [MacBenchCore.Category] = []
    var tree: [TreeItem] = []
    var signals = ActivitySignals()

    /// What the sidebar points at: a project, a folder, or one of the two lists.
    var selection: Selection = .activity {
        didSet {
            guard selection != oldValue else { return }
            keptUnread.removeAll()
            activityDepth = 1
            streamDepth = 1
            filter.searchText = ""
            selectedFile = nil
            selectedEntry = nil
            persistSelection()
            refreshDetail()
        }
    }

    /// A file picked inside the current folder. Kept apart from `selection` on
    /// purpose: clicking a file narrows the stream below the list, it does not
    /// replace the view or un-highlight the folder in the sidebar.
    var selectedFile: UUID? {
        didSet {
            guard selectedFile != oldValue else { return }
            keptUnread.removeAll()
            streamDepth = 1
            readHiddenChanges()
            refreshDetail()
        }
    }

    /// A file's changes count as read once the file is picked, when the column
    /// beside it is not going to show them — put away, or set to leave file
    /// changes out. Otherwise nothing could ever put them on screen, and the dot
    /// on the file stayed however often it was clicked.
    private func readHiddenChanges() {
        guard let selectedFile, let viewer = identity?.member.id else { return }
        let changesAreShown = switch selection {
        case .project, .node: filter.includeSystem
        // Beside the two lists the conversation is shown unfiltered.
        case .activity, .openTasks: true
        }
        guard !isStreamVisible || !changesAreShown else { return }
        try? store.markChangesRead(nodeID: selectedFile, member: viewer)
    }

    /// The row the middle column points at, in the two lists that span projects:
    /// a task, or something that happened. Held whole rather than by id on
    /// purpose — ticking a task off takes it out of its list, and the
    /// conversation beside it must not empty itself in the same gesture.
    /// The entry the conversation column should point at for a moment, so that
    /// landing there shows you where. Cleared on its own.
    private(set) var flashingEntry: UUID?
    private var flashTask: Task<Void, Never>?

    func flash(_ id: UUID) {
        flashingEntry = id
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.flashingEntry = nil
        }
    }

    var selectedEntry: TimelineItem? {
        didSet {
            guard selectedEntry?.id != oldValue?.id else { return }
            streamDepth = 1
            if let selectedEntry { flash(selectedEntry.id) }
            let file = selectedEntry?.node.flatMap { $0.isPlaceholder ? nil : $0.id }
            // Selecting a task is selecting what it is about: that is what gives
            // the stream its scope and the composer its project.
            if file != selectedFile { selectedFile = file } else { refreshDetail() }
        }
    }
    /// Whether the conversation column is showing. It lives here rather than in
    /// the view because a row in the middle column has to be able to open it:
    /// picking a line while that column is collapsed otherwise does nothing at
    /// all, and nothing is the one answer a click must never give.
    var isStreamVisible: Bool = UserDefaults.standard.object(forKey: streamVisibleKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isStreamVisible, forKey: streamVisibleKey) }
    }
    /// Which folders are open, and where you were. Restored on launch: a tree that
    /// collapses itself every morning makes you re-navigate to the same place
    /// every morning.
    var expanded: Set<Selection> = [] {
        didSet { if expanded != oldValue { persistExpansion() } }
    }
    var filter = TimelineFilter() { didSet { refreshDetail(); persistFilters() } }
    /// The task list filters itself, separately from the stream. They ask
    /// different questions — "which tasks" against "what is in this folder" — and
    /// sharing one setting meant a trip to the task list left every project
    /// stream showing nothing but tasks.
    var taskFilter = TimelineFilter.tasks { didSet { refreshDetail(); persistFilters() } }
    var sidebarFilter: SidebarFilter = .all { didSet { persistFilters() } }
    var searchText = "" {
        didSet {
            refreshSearch()
            // Starting or ending a search changes what the column beside it is
            // about. It used to go on showing the selection from before, beside
            // results that had nothing to do with it.
            if searchText.isEmpty != oldValue.isEmpty {
                searchPick = nil
                refreshDetail()
            }
        }
    }
    var isSearching: Bool { !searchText.isEmpty }

    /// How far back the feed and the conversation column reach, in pages. Each
    /// list stopped at one page and said nothing about it, so a project's first
    /// weeks were simply not there. Back to one page whenever the list becomes
    /// about something else.
    private(set) var activityDepth = 1
    private(set) var streamDepth = 1
    static let historyPage = TimelineFilter().limit

    /// Whether the list may reach further back than it shows.
    var activityIsCut: Bool { activity.count >= activityDepth * Self.historyPage }
    var timelineIsCut: Bool { timeline.count >= streamDepth * Self.historyPage }

    func showEarlierActivity() {
        activityDepth += 1
        refreshDetail()
    }

    func showEarlierStream() {
        streamDepth += 1
        refreshDetail()
    }

    /// The query for the conversation column, one page per step back.
    private var streamFilter: TimelineFilter {
        var filter = TimelineFilter()
        filter.limit = streamDepth * Self.historyPage
        return filter
    }
    /// The line picked among the search results. The conversation column shows
    /// what was said around it, as it does beside the feed; kept apart from
    /// `selectedEntry` so that ending the search puts back what was there.
    var searchPick: TimelineItem? {
        didSet {
            guard searchPick?.id != oldValue?.id else { return }
            streamDepth = 1
            if let searchPick { flash(searchPick.id) }
            refreshDetail()
        }
    }

    var timeline: [TimelineItem] = []
    /// Every task, when the sidebar points at Tasks. The middle column shows these
    /// instead of files: which file a task is about is one of its details, not the
    /// thing being listed.
    var tasks: [TimelineItem] = []
    /// Everything that has happened, when the sidebar points at Latest activity.
    /// Same idea as `tasks`: the middle column shows what you came for.
    var activity: [TimelineItem] = []
    var files: [FileListItem] = []
    /// The folders inside the current one, shown above its files. A folder that
    /// only appeared when the list was otherwise empty meant the way down was
    /// visible in the sidebar and nowhere else, in the column you are looking at.
    var subfolders: [Node] = []
    /// The order of both lists. Remembered, because a list that reorders itself
    /// every morning is a list you have to read again every morning.
    var fileSort: FileSort = FileSort(stored: UserDefaults.standard.string(forKey: fileSortKey)) {
        didSet {
            guard fileSort != oldValue else { return }
            UserDefaults.standard.set(fileSort.rawValue, forKey: fileSortKey)
            files = fileSort.sorted(files)
            subfolders = fileSort.sorted(subfolders)
        }
    }
    var breadcrumb: [Crumb] = []
    var searchResults = SearchResults()
    var engineStatus: [UUID: ProjectEngine.Status] = [:] {
        // Also on its own, not only with the database: a download that has been
        // pending too long changes nothing in the database, only in the clock.
        didSet { refreshBanners() }
    }
    /// The entry the composer is currently answering. A reply is the one thing
    /// besides an assigned task that is allowed to notify the other person, so it
    /// needs to be reachable in one gesture.
    var replyTarget: TimelineItem?
    var banners: [Banner] = []
    /// Machines whose changes are announced but not here yet, for the sidebar.
    private(set) var catchingUp: [PeerCatchUp] = []
    /// People whose changes have just finished arriving. Said once, briefly: the
    /// spinner going away on its own left nobody knowing whether it had worked.
    private(set) var arrived: [String] = []
    /// The project a confirmation is currently being asked about. Held here rather
    /// than in the row, because the row's context menu is gone by the time the
    /// dialog would open.
    var projectPendingRemoval: UUID?
    /// Projects put away, for Settings, which is where they come back from.
    private(set) var archivedProjects: [Project] = []

    enum SidebarFilter: String, CaseIterable, Identifiable {
        case all, unread, open
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            // Short on purpose: three long words in a segmented control are a
            // minimum width for the sidebar, which then cannot be dragged
            // narrower than they are.
            case .unread: "Unread"
            case .open: "Tasks"
            }
        }
    }

    struct Banner: Identifiable, Hashable {
        enum Level { case info, warning }
        var level: Level = .warning
        var text: String
        var detail: String?
        /// What it says, not when it was said. The same condition is rebuilt on
        /// every refresh — which happens on any change to the database — so an
        /// identity made fresh each time meant the window redrew the same warning
        /// several times a second, and nothing could be dismissed for longer than
        /// that.
        var id: String { text + (detail ?? "") }
    }

    /// Another machine whose log promises more than is on this disk. Almost always
    /// iCloud still downloading, which settles by itself within seconds — so it is
    /// shown as something happening, in the sidebar, and not as a warning. Only
    /// once it has not settled for a while is it a problem worth a banner.
    struct PeerCatchUp: Identifiable, Hashable {
        var projectID: UUID
        var device: String
        var who: String
        var since: Date
        var isStuck: Bool
        var id: String { projectID.uuidString + device }
    }

    /// Long enough that it is not iCloud being slow any more.
    static let catchUpStuckAfter: TimeInterval = 10 * 60

    // MARK: - Internals

    private let access = ProjectAccess()
    private let notifier = Notifier()
    private let hotKey = GlobalHotKey()
    /// Set by the scene, which is the only place that can open a window.
    var quickCaptureAction: (() -> Void)?
    private var lastNotifiedAt = Date()
    private var engines: [UUID: ProjectEngine] = [:]
    private var observationCancellable: AnyDatabaseCancellable?
    private var refreshTask: Task<Void, Never>?
    private var statusTasks: [UUID: Task<Void, Never>] = [:]
    private let supportDirectory: URL
    private let identityFile: IdentityFile
    private let projectsFile: ProjectsFile
    /// What `projects.json` holds, so it is only written when that changes.
    private var mirroredProjects: [SavedProject]?

    init() {
        supportDirectory = URL.applicationSupportDirectory.appending(path: "MacBench", directoryHint: .isDirectory)
        identityFile = IdentityFile(directory: supportDirectory)
        projectsFile = ProjectsFile(directory: supportDirectory)
        do {
            store = try Store(url: supportDirectory.appending(path: "index.sqlite"))
        } catch {
            // A database we cannot open is not recoverable in the UI, and pretending
            // otherwise would lose whatever comes next. Start over from the logs.
            // The write-ahead log goes with it: left behind, SQLite applies it to
            // the fresh file, which then fails to open as well — and the second
            // attempt has nothing to fall back on.
            let broken = supportDirectory.appending(path: "index.sqlite")
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: supportDirectory.appending(path: "index.sqlite" + suffix))
            }
            store = try! Store(url: broken)
            indexWasRebuilt = true
        }
        // From its own file, so that the index going above takes nobody with it.
        identity = identityFile.load(orAdopt: try? store.setting(Self.identityKey, as: LocalIdentity.self))
        // Copied onto another Mac, it becomes a device of its own. See `claimed`.
        if let loaded = identity {
            let claimed = loaded.claimed(by: MachineID.current, name: Host.current().localizedName)
            if claimed != loaded {
                identity = claimed
                persist(claimed)
            }
        }
        // And the folders it watched, from theirs. An index with no project at
        // all next to a list that has some is one that was started again.
        mirroredProjects = projectsFile.load()
        if let saved = mirroredProjects, !saved.isEmpty,
           (try? store.projects(includeArchived: true))?.isEmpty == true {
            _ = try? store.restore(saved)
        }
    }

    /// Keeps `projects.json` up to date with the index. Cheap enough to ask on
    /// every refresh: one small table, written only when it differs.
    private func mirrorProjects() {
        guard let current = try? store.savedProjects(), current != mirroredProjects else { return }
        if (try? projectsFile.save(current)) != nil { mirroredProjects = current }
    }

    /// Kept in both places. The file is what survives a rebuilt index; the copy
    /// in the index is what an older build reads, and what the file is made
    /// again from if writing it failed.
    private func persist(_ identity: LocalIdentity) {
        try? identityFile.save(identity)
        try? store.setSetting(Self.identityKey, value: identity)
    }

    static let identityKey = "local.identity"
    static let hotKeyKey = "hotkey.quickCapture"
    static let archiveDaysKey = "archive.afterDays"
    static let expandedKey = "ui.expandedFolders"
    static let selectionKey = "ui.lastSelection"
    static let filtersKey = "ui.filters"

    /// How long a deleted file stays in the lists before moving to the archive.
    /// Zero keeps everything visible. Local to this Mac, like every other
    /// preference about how much you want to see.
    var archiveAfterDays: Int {
        get { (try? store.setting(Self.archiveDaysKey, as: Int.self)) ?? 90 }
        set {
            try? store.setSetting(Self.archiveDaysKey, value: newValue)
            Task {
                for engine in engines.values { await engine.setArchiveAfterDays(newValue) }
                refreshAll()
            }
        }
    }

    /// Re-reads the stored shortcut and rebinds it. Called at launch and whenever
    /// it is changed in Settings, so a new combination works immediately.
    func installHotKey() {
        let stored = try? store.setting(Self.hotKeyKey, as: GlobalHotKey.StoredCombination.self)
        guard let combination = stored?.combination ?? (stored == nil ? .default : nil) else {
            hotKey.unregister()
            return
        }
        hotKey.register(combination) { [weak self] in self?.quickCaptureAction?() }
    }

    // MARK: - Start-up

    /// Guards against starting twice. Every window runs this, and a second one
    /// used to install a second database observation over the first — which then
    /// ran forever with nobody holding it — and to put the sidebar back to the
    /// folder that was open at launch, under the hands of somebody who had since
    /// navigated somewhere else.
    private var hasStarted = false

    func start() async {
        guard !hasStarted, let identity else { isReady = true; return }
        hasStarted = true
        try? store.upsert(member: identity.member)
        await startEngines()
        startRetrying()
        observeDatabase()
        restoreLayout()
        refreshAll()
        isReady = true
        // Asked on the side. The question waits for an answer, and it arrives as a
        // notification in a corner that is easy to miss: the folder picked during
        // onboarding was added only once somebody had found and answered it, and
        // until then the window stood there empty.
        Task { await notifier.requestAuthorisation() }
    }

    func completeOnboarding(name: String, colorHex: String, deviceName: String,
                            existingMember: Member?) async {
        let member = existingMember ?? Member(name: name, colorHex: colorHex)
        let identity = LocalIdentity(deviceName: deviceName, member: member)
        persist(identity)
        try? store.upsert(member: member)
        self.identity = identity
        await start()
        for engine in engines.values { try? await engine.announceSelf() }
    }

    private func startEngines() async {
        projects = (try? store.projects(includeArchived: true)) ?? []
        guard let identity else { return }
        for project in projects where !project.isArchived {
            await startEngine(for: project, identity: identity)
        }
    }

    /// Projects that could not be started are tried again, once a minute and
    /// whenever the Mac wakes. What stops one is usually iCloud not having a file
    /// here yet — this Mac's own log on a Mac that was offline, which a start
    /// refuses to write past — or a drive that is not mounted. Both settle by
    /// themselves, and a project nobody watches used to stay that way until the
    /// app was opened again, while the banner asked for exactly that.
    private func startRetrying() {
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.retryUnwatched()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.retryUnwatched() }
        }
    }

    private func retryUnwatched() async {
        guard let identity else { return }
        let waiting = projects.filter {
            !$0.isArchived && engines[$0.id] == nil && unreachableProjects[$0.id] != nil
        }
        guard !waiting.isEmpty else { return }
        for project in waiting { await startEngine(for: project, identity: identity) }
        refreshAll()
    }

    private var retryTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?

    private func startEngine(for project: Project, identity: LocalIdentity) async {
        guard engines[project.id] == nil else { return }
        do {
            let location = try store.projectLocation(project.id)
            let url = try access.open(project: project, bookmark: location?.bookmark,
                                      fallbackPath: location?.path, store: store)
            let engine = try ProjectEngine(projectID: project.id, root: url, store: store,
                                           identity: identity, supportDirectory: supportDirectory)
            // Claimed before the first suspension. A retry on waking and one on
            // the minute can both get this far for the same project, and two
            // engines would be two writers in one device folder.
            engines[project.id] = engine
            await engine.setArchiveAfterDays(archiveAfterDays)
            statusTasks[project.id] = Task { [weak self] in
                for await status in await engine.statusUpdates() {
                    await MainActor.run { self?.engineStatus[project.id] = status }
                }
            }
            await engine.start()
            try? await engine.publish(categories: (try? store.categories()) ?? [])
            unreachableProjects[project.id] = nil
        } catch {
            unreachableProjects[project.id] = error.localizedDescription
        }
    }

    /// Warnings the reader has put away. Held for this run only: a condition that
    /// is still broken tomorrow says so again tomorrow, and the reason stays
    /// readable in Settings in the meantime.
    private var dismissedBanners: Set<String> = []
    private var catchUpSince: [String: Date] = [:]
    private var arrivedTask: Task<Void, Never>?

    func dismiss(_ banner: Banner) {
        // Something that went wrong once is gone when put away. Should it happen
        // again it is news again, which a lasting condition put away is not.
        if failures.contains(where: { $0.id == banner.id }) {
            failures.removeAll { $0.id == banner.id }
        } else {
            dismissedBanners.insert(banner.id)
        }
        refreshBanners()
    }

    /// Things somebody asked for that did not happen: a folder not added, a
    /// message or a change that did not go through. Held until put away. They
    /// used to be appended to the banners directly, and the next refresh —
    /// within a fraction of a second, on any change to the database — rebuilt
    /// the list without them, so the one message saying so was never seen.
    private var failures: [Banner] = []

    private func reportFailure(_ text: String, _ error: any Error) {
        let banner = Banner(text: text, detail: error.localizedDescription)
        failures.removeAll { $0.id == banner.id }
        failures.append(banner)
        refreshBanners()
    }

    /// Why a project is not being watched, for the place that is about that
    /// project. Putting the banner away must not put the problem away.
    func unwatchedReason(for projectID: UUID) -> String? { unreachableProjects[projectID] }

    /// Projects whose folder could not be opened, and why.
    ///
    /// Held as state rather than announced once. A project that is not running is
    /// a condition that lasts until somebody fixes it, and appending a banner for
    /// it meant the next refresh — which happens on any database change, so within
    /// a fraction of a second — replaced the whole list and took it away again.
    /// The one message saying "this project is not being watched" was the one
    /// nobody ever saw.
    private var unreachableProjects: [UUID: String] = [:]

    /// The index could not be opened at launch and was started again. Who this
    /// Mac is survives that; which folders it watched does not, and without a
    /// word the window would simply come up empty.
    private var indexWasRebuilt = false

    func stop() async {
        for engine in engines.values { await engine.stop() }
        for task in statusTasks.values { task.cancel() }
        observationCancellable?.cancel()
        access.releaseAll()
    }

    // MARK: - Remembering where you were

    private var isRestoring = false

    private func restoreLayout() {
        isRestoring = true
        defer { isRestoring = false }
        if let stored = try? store.setting(Self.expandedKey, as: [String].self) {
            expanded = Set(stored.compactMap(Selection.init(token:)))
        }
        if let token = try? store.setting(Self.selectionKey, as: String.self),
           let restored = Selection(token: token), exists(restored) {
            selection = restored
        }
        restoreFilters()
    }

    private func exists(_ selection: Selection) -> Bool {
        switch selection {
        case .activity, .openTasks: true
        case .project(let id): projects.contains { $0.id == id }
        case .node(let id): (try? store.node(id: id)) != nil
        }
    }

    /// What the filters are for, and what they are not.
    ///
    /// Kept: the categories you narrowed to, whether file changes are in the
    /// stream, how the project tree is thinned out, and whose tasks the task
    /// list shows. Those describe how you like to work — "only mine" turned out
    /// to be a way of working, not a search, and setting it again every morning
    /// was the complaint.
    ///
    /// Deliberately not kept: "Done". It is something you go looking for once,
    /// and restoring it would open the app on a list that is empty for a reason
    /// written down three days ago.
    private struct StoredFilters: Codable {
        var includeSystem = true
        var categories: [UUID] = []
        var taskCategories: [UUID] = []
        var sidebar = SidebarFilter.all.rawValue
        var taskAssignee: UUID?
    }

    private func restoreFilters() {
        guard let stored = try? store.setting(Self.filtersKey, as: StoredFilters.self) else { return }
        // A category somebody deleted on the other Mac would otherwise sit in the
        // filter as an id with no chip to switch it off again.
        let known = Set(((try? store.categories()) ?? []).map(\.id))
        filter.includeSystem = stored.includeSystem
        filter.categories = Set(stored.categories).intersection(known)
        taskFilter.categories = Set(stored.taskCategories).intersection(known)
        if let id = stored.taskAssignee, ((try? store.members()) ?? []).contains(where: { $0.id == id }) {
            taskFilter.assignee = .member(id)
        }
        sidebarFilter = SidebarFilter(rawValue: stored.sidebar) ?? .all
    }

    private func persistFilters() {
        guard !isRestoring else { return }
        try? store.setSetting(Self.filtersKey, value: StoredFilters(
            includeSystem: filter.includeSystem,
            categories: Array(filter.categories),
            taskCategories: Array(taskFilter.categories),
            sidebar: sidebarFilter.rawValue,
            taskAssignee: { if case .member(let id) = taskFilter.assignee { id } else { nil } }()))
    }

    private func persistExpansion() {
        guard !isRestoring else { return }
        try? store.setSetting(Self.expandedKey, value: expanded.map(\.token).sorted())
    }

    private func persistSelection() {
        guard !isRestoring else { return }
        try? store.setSetting(Self.selectionKey, value: selection.token)
    }

    // MARK: - Live updates

    private func observeDatabase() {
        observationCancellable?.cancel()
        let observation = DatabaseRegionObservation(tracking: .fullDatabase)
        observationCancellable = observation.start(in: store.writer, onError: { _ in }) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            // A burst of writes during a scan would otherwise redraw the window
            // dozens of times a second for no benefit.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.refreshAll()
        }
    }

    func refreshAll() {
        guard let viewer = identity?.member.id else { return }
        mirrorProjects()
        projects = (try? store.projects()) ?? []
        archivedProjects = (try? store.projects(includeArchived: true))?.filter(\.isArchived) ?? []
        // A project archived or removed since it was picked would leave a list
        // narrowed to something with no pill to switch it off again.
        let known = Set(projects.map(\.id))
        if let id = filter.project, !known.contains(id) { filter.project = nil }
        if let id = taskFilter.project, !known.contains(id) { taskFilter.project = nil }
        members = (try? store.members()) ?? []
        categories = (try? store.categories()) ?? []
        signals = (try? store.activitySignals(viewer: viewer)) ?? ActivitySignals()
        rebuildTree()
        refreshDetail()
        if !searchText.isEmpty { refreshSearch() }
        refreshBanners()
        notifyIfNeeded(viewer: viewer)
    }

    private func notifyIfNeeded(viewer: UUID) {
        let since = lastNotifiedAt
        lastNotifiedAt = Date()
        guard let items = try? store.entriesDeservingNotification(since: since, viewer: viewer),
              !items.isEmpty || !engineStatus.isEmpty else { return }
        let projects = self.projects
        let conflicts = engineStatus.map { ($0.key, $0.value.unresolvedConflicts) }
        Task { [notifier] in
            await notifier.announce(items, projects: projects)
            for (projectID, paths) in conflicts where !paths.isEmpty {
                let name = projects.first { $0.id == projectID }?.name ?? ""
                await notifier.announceConflicts(paths, project: name)
            }
        }
    }

    private func rebuildTree() {
        tree = projects.map { project in
            TreeItem(id: .project(project.id), title: project.name, path: "",
                     projectID: project.id, isProject: true,
                     children: folderChildren(project: project.id, parent: ""))
        }
    }

    private func folderChildren(project: UUID, parent: String) -> [TreeItem]? {
        let folders = (try? store.folders(projectID: project, parentPath: parent)) ?? []
        guard !folders.isEmpty else { return nil }
        return folders.map { folder in
            TreeItem(id: .node(folder.id), title: folder.name, path: folder.relativePath,
                     projectID: project, isProject: false,
                     children: folderChildren(project: project, parent: folder.relativePath))
        }
    }

    /// Which project a line belongs to, for the two lists that span projects —
    /// nil where the list already says so: narrowed to one project, or there is
    /// only one to begin with.
    func projectLabel(for entry: Entry, narrowedTo project: UUID?) -> String? {
        guard project == nil, projects.count > 1 else { return nil }
        return projects.first { $0.id == entry.projectID }?.name
    }

    func refreshDetail() {
        guard let viewer = identity?.member.id else { return }
        if isSearching {
            refreshSearchContext(viewer: viewer)
            return
        }
        switch selection {
        case .openTasks: refreshTaskList(viewer: viewer)
        case .activity: refreshActivity(viewer: viewer)
        case .project, .node: refreshFolder(viewer: viewer)
        }
    }

    /// A project or a folder: which files are in it, and what was said about the
    /// one you picked.
    private func refreshFolder(viewer: UUID) {
        tasks = []
        activity = []
        var scope: TimelineScope
        switch selection {
        case .project(let id): scope = .project(id)
        case .node(let id):
            let node = try? store.node(id: id)
            scope = (node?.isDirectory ?? true) ? .folder(id) : .file(id)
        // Not reachable: those two are lists of their own, handled above.
        case .activity, .openTasks: return
        }
        if let selectedFile { scope = .file(selectedFile) }
        // The project picked in Latest activity narrows that list, not this one:
        // here the sidebar has already said which project, and a different one
        // left over from the feed would empty the stream for no visible reason.
        var filter = filter
        filter.project = nil
        filter.limit = streamDepth * Self.historyPage
        timeline = (try? store.timeline(scope: scope, filter: filter, viewer: viewer)) ?? []
        files = fileSort.sorted(currentFiles(viewer: viewer))
        subfolders = fileSort.sorted(currentSubfolders())
        breadcrumb = currentBreadcrumb()
    }

    /// The task list, and beside it the conversation around the task you picked —
    /// not a second copy of the list. The context is shown unfiltered on purpose:
    /// a thread with half its messages missing is worse than no thread.
    private func refreshTaskList(viewer: UUID) {
        tasks = (try? store.timeline(scope: .openTasks, filter: taskFilter, viewer: viewer)) ?? []
        activity = []
        refreshContext(in: tasks, viewer: viewer)
    }

    /// The feed, and beside it the conversation the selected line belongs to. The
    /// filter bar narrows the feed, not the conversation: a thread with half its
    /// messages missing is worse than no thread.
    private func refreshActivity(viewer: UUID) {
        var filter = filter
        filter.limit = activityDepth * Self.historyPage
        activity = (try? store.timeline(scope: .activity, filter: filter, viewer: viewer)) ?? []
        tasks = []
        refreshContext(in: activity, viewer: viewer)
    }

    /// Beside the search results: the conversation around the result picked,
    /// and nothing until one is.
    private func refreshSearchContext(viewer: UUID) {
        if let current = searchPick,
           let fresh = searchResults.entries.first(where: { $0.id == current.id }) {
            searchPick = fresh
        }
        if let file = searchPickFile {
            timeline = (try? store.timeline(scope: .file(file), filter: streamFilter, viewer: viewer)) ?? []
        } else if let projectID = searchPick?.entry.projectID {
            timeline = (try? store.timeline(scope: .project(projectID), filter: streamFilter,
                                            viewer: viewer)) ?? []
        } else {
            timeline = []
        }
    }

    private var searchPickFile: UUID? {
        searchPick?.node.flatMap { $0.isPlaceholder ? nil : $0.id }
    }

    private func refreshContext(in list: [TimelineItem], viewer: UUID) {
        if let current = selectedEntry, let fresh = list.first(where: { $0.id == current.id }) {
            selectedEntry = fresh
        }
        files = []
        subfolders = []
        breadcrumb = []
        if let selectedFile {
            timeline = (try? store.timeline(scope: .file(selectedFile), filter: streamFilter,
                                            viewer: viewer)) ?? []
        } else if let projectID = selectedEntry?.entry.projectID {
            timeline = (try? store.timeline(scope: .project(projectID), filter: streamFilter,
                                            viewer: viewer)) ?? []
        } else {
            timeline = []
        }
    }

    /// The files of the folder the sidebar points at. Selecting one of them does
    /// not change this list — that is what keeps the file you clicked in view,
    /// next to its neighbours, instead of dropping you somewhere else.
    private func currentFiles(viewer: UUID) -> [FileListItem] {
        switch selection {
        case .project(let id):
            return (try? store.files(projectID: id, parentPath: "", viewer: viewer)) ?? []
        case .node(let id):
            guard let node = try? store.node(id: id) else { return [] }
            let folder = node.isDirectory ? node.relativePath : (node.parentPath ?? "")
            return (try? store.files(projectID: node.projectID,
                                     parentPath: folder, viewer: viewer)) ?? []
        // Both show a list of their own in the middle column, not files.
        case .activity, .openTasks:
            return []
        }
    }

    private func currentSubfolders() -> [Node] {
        switch selection {
        case .project(let id):
            return (try? store.folders(projectID: id, parentPath: "")) ?? []
        case .node(let id):
            guard let node = try? store.node(id: id), node.isDirectory else { return [] }
            return (try? store.folders(projectID: node.projectID, parentPath: node.relativePath)) ?? []
        case .activity, .openTasks:
            return []
        }
    }

    /// Each part of the path carries where it leads, so the row can be walked
    /// back up rather than only read. A part whose folder is not in the index —
    /// which a path can outlive — carries nothing and is shown as plain text.
    private func currentBreadcrumb() -> [Crumb] {
        switch selection {
        case .activity, .openTasks: return []
        case .project(let id):
            return [Crumb(id: 0, name: projects.first { $0.id == id }?.name ?? "",
                          target: .project(id))]
        case .node(let id):
            guard let node = try? store.node(id: id) else { return [] }
            let projectID = node.projectID
            var parts = [Crumb(id: 0, name: projects.first { $0.id == projectID }?.name ?? "",
                               target: .project(projectID))]
            var path = ""
            for component in node.relativePath.split(separator: "/").map(String.init) {
                path = path.isEmpty ? component : path + "/" + component
                let step = try? store.node(projectID: projectID, relativePath: path)
                parts.append(Crumb(id: parts.count, name: component,
                                   target: step.map { .node($0.id) }))
            }
            // The file picked inside the folder is the end of the path, and the
            // end of the path is where you already are: it leads nowhere. The
            // folder before it is the way back out of it.
            if let selectedFile, let file = try? store.node(id: selectedFile), file.id != node.id {
                parts.append(Crumb(id: parts.count, name: file.name, target: nil))
            }
            return parts
        }
    }

    private func refreshSearch() {
        guard let viewer = identity?.member.id else { return }
        searchResults = (try? store.search(searchText, viewer: viewer)) ?? SearchResults()
    }

    private func refreshBanners() {
        refreshCatchUp()
        var found: [Banner] = []
        found.append(contentsOf: failures)
        if indexWasRebuilt && projects.isEmpty {
            found.append(Banner(
                text: String(localized: "The list of projects had to be started again"),
                detail: String(localized: "Add your project folders once more. Everything written in them comes back from the folders themselves.")))
        }
        for project in projects {
            guard let reason = unreachableProjects[project.id] else { continue }
            found.append(Banner(text: String(localized: "\(project.name) is not being watched"),
                                detail: reason))
        }
        for catchUp in catchingUp where catchUp.isStuck {
            let name = projects.first { $0.id == catchUp.projectID }?.name ?? ""
            let since = catchUp.since.formatted(Calendar.current.isDateInToday(catchUp.since)
                ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute())
            found.append(Banner(
                text: String(localized: "iCloud is not delivering changes from \(catchUp.who) in \(name)"),
                detail: String(localized: "Waiting since \(since). Check that iCloud Drive is syncing on both Macs. The changes show up here by themselves once they arrive.")))
        }
        for (projectID, status) in engineStatus {
            let name = projects.first { $0.id == projectID }?.name ?? ""
            // What the engine could not do: write its log, keep watching a folder
            // that was renamed under it. It used to go into a status nobody read,
            // which made a project that had stopped working look like a quiet one.
            for (kind, error) in status.problems.sorted(by: { $0.key < $1.key }) {
                // What it means for the others comes first: nothing is lost, it
                // has only not left this Mac yet.
                let text = kind == .log && status.unwrittenRecords > 0
                    ? String(localized: "\(status.unwrittenRecords) changes in \(name) have not reached the others yet")
                    : String(localized: "Something went wrong in \(name)")
                found.append(Banner(text: text, detail: error))
            }
            if let reason = status.lastSync?.devicesUnreadable {
                found.append(Banner(
                    text: String(localized: "Could not look for the other Macs in \(name): \(reason)"),
                    detail: String(localized: "Entries may be missing until this resolves.")))
            }
            for problem in status.lastSync?.incompletePeers ?? [] {
                let who = displayName(problem)
                switch problem.kind {
                case .waitingForDownload, .missingRecords:
                    continue
                case .unreadable(let detail):
                    found.append(Banner(
                        text: String(localized: "Could not read part of \(who)'s log in \(name): \(detail)"),
                        detail: String(localized: "Entries may be missing until this resolves.")))
                case .newerFormat:
                    found.append(Banner(
                        text: String(localized: "\(who) is running a newer version"),
                        detail: String(localized: "Update MacBench on this Mac to see what they write.")))
                }
            }
            for conflict in status.unresolvedConflicts {
                found.append(Banner(level: .warning,
                    text: String(localized: "iCloud made a conflict copy of \(conflict)"),
                    detail: String(localized: "Both of you saved this file at the same time. Open the folder and keep the version you want.")))
            }
        }
        banners = found.filter { !dismissedBanners.contains($0.id) }
    }

    /// Folds what the last pull of every project found missing into one line per
    /// machine: a missing log file and the entries inside it are the same wait.
    private func refreshCatchUp() {
        let now = Date()
        let known = Set(projects.map(\.id))
        var current: [PeerCatchUp] = []
        for (projectID, status) in engineStatus where known.contains(projectID) {
            for problem in status.lastSync?.incompletePeers ?? [] {
                switch problem.kind {
                case .waitingForDownload, .missingRecords: break
                case .unreadable, .newerFormat: continue
                }
                let id = projectID.uuidString + problem.deviceName
                guard !current.contains(where: { $0.id == id }) else { continue }
                let since = catchUpSince[id] ?? now
                current.append(PeerCatchUp(
                    projectID: projectID, device: problem.deviceName, who: displayName(problem),
                    since: since, isStuck: now.timeIntervalSince(since) > Self.catchUpStuckAfter))
            }
        }
        current.sort { $0.since < $1.since }
        let ids = Set(current.map(\.id))
        // Gone because it arrived, not because the project or its engine went away.
        let finished = catchingUp.filter {
            !ids.contains($0.id) && known.contains($0.projectID)
                && engineStatus[$0.projectID]?.lastSync != nil
        }
        catchUpSince = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.since) })
        if current != catchingUp { catchingUp = current }
        if !finished.isEmpty { announceArrival(of: finished.map(\.who)) }
    }

    private func announceArrival(of names: [String]) {
        for name in names where !arrived.contains(name) { arrived.append(name) }
        arrivedTask?.cancel()
        arrivedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.arrived = []
        }
    }

    func catchingUp(project: UUID) -> [PeerCatchUp] {
        catchingUp.filter { $0.projectID == project }
    }

    /// A name as the other person typed it, which an older version saved untrimmed.
    private func displayName(_ problem: PeerProblem) -> String {
        let name = problem.memberName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? problem.deviceName : name
    }

    // MARK: - Dots in the tree

    /// A folder shows a dot when something below it is new. Once it is open, the
    /// dot moves down to where the news actually is, so the eye is led to the file
    /// rather than being told twice.
    func hasUnread(_ item: TreeItem) -> Bool {
        marked(item, paths: signals.unreadPaths[item.projectID] ?? [])
    }

    func hasOpenTasks(_ item: TreeItem) -> Bool {
        marked(item, paths: signals.openTaskPaths[item.projectID] ?? [])
    }

    private func marked(_ item: TreeItem, paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        let isOpen = expanded.contains(item.id)
        for path in paths {
            let directParent = (path as NSString).deletingLastPathComponent
            if directParent == item.path { return true }
            if !isOpen, item.path.isEmpty || path.hasPrefix(item.path + "/") { return true }
        }
        return false
    }

    func unreadCount(project: UUID) -> Int { signals.unreadPaths[project]?.count ?? 0 }

    // MARK: - The filter above the tree

    /// The tree as the filter above it thins it out: a folder stays when
    /// something in it or below it matches, and goes when nothing does. It used
    /// to thin out only the projects, so "Tasks" still listed every folder of a
    /// project that had one task somewhere.
    var visibleTree: [TreeItem] {
        sidebarFilter == .all ? tree : tree.compactMap(pruned)
    }

    /// The folder you are in stays, and the way to it, even once nothing in it
    /// matches any more: reading the last unread file would otherwise take the
    /// folder out from under the selection, and the sidebar would no longer say
    /// where you are. Once you go elsewhere, it goes.
    private func pruned(_ item: TreeItem) -> TreeItem? {
        var item = item
        let children = item.children?.compactMap(pruned) ?? []
        item.children = children.isEmpty ? nil : children
        let passes = item.id == selection || !children.isEmpty
            || passesSidebarFilter(projectID: item.projectID, path: item.path)
        return passes ? item : nil
    }

    /// Whether anything at this folder or below it is what the filter asks for,
    /// whether the folder is open or not. Not `hasUnread`: that one moves the dot
    /// down into an open folder, and a filter must not change its mind about a
    /// folder because it was opened.
    func passesSidebarFilter(projectID: UUID, path: String) -> Bool {
        let paths: [String]
        switch sidebarFilter {
        case .all: return true
        case .unread: paths = signals.unreadPaths[projectID] ?? []
        case .open: paths = signals.openTaskPaths[projectID] ?? []
        }
        if path.isEmpty { return !paths.isEmpty }
        return paths.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    /// The folder's files, under the same filter. The picked file stays even once
    /// it no longer matches: reading it is what takes it out, and a row that
    /// vanished under the pointer the moment it was read would be a row you
    /// could not look at twice.
    var visibleFiles: [FileListItem] {
        switch sidebarFilter {
        case .all: files
        case .unread: files.filter { $0.unreadCount > 0 || $0.node.id == selectedFile }
        case .open: files.filter { $0.openTaskCount > 0 || $0.node.id == selectedFile }
        }
    }

    var visibleSubfolders: [Node] {
        subfolders.filter { passesSidebarFilter(projectID: $0.projectID, path: $0.relativePath) }
    }

    // MARK: - Actions

    func engine(for projectID: UUID) -> ProjectEngine? { engines[projectID] }

    /// The project the composer would write into, or `nil` when the view spans
    /// several. Picking a file in a cross-project list settles it, which is what
    /// makes it possible to answer a task from the task list.
    /// The window's title: the project you are in. The app's own name said
    /// nothing a Mac does not already say in the menu bar, and in the Window menu
    /// and Mission Control it could not tell two windows apart. Over the feed
    /// and the tasks, which span projects, it stays the app's name; the column
    /// under it already says which list it is.
    var windowTitle: String {
        let projectID: UUID? = switch selection {
        case .project(let id): id
        case .node(let id): (try? store.node(id: id))?.projectID
        case .activity, .openTasks: nil
        }
        return projectID.flatMap { id in projects.first { $0.id == id }?.name } ?? Brand.name
    }

    var currentProjectID: UUID? {
        // While searching, the column beside the results is about the result
        // picked, and so is anything written into it.
        if isSearching { return searchPick?.entry.projectID }
        if let selectedFile, let node = try? store.node(id: selectedFile) { return node.projectID }
        return switch selection {
        case .project(let id): id
        case .node(let id): (try? store.node(id: id))?.projectID
        // Picking a line out of one of the cross-project lists settles it the same
        // way picking a file does — which is what makes it possible to answer a
        // task, or something somebody wrote this morning, without going there
        // first. Nothing picked, no project: a note dropped into whichever project
        // happened to sort first is worse than no note.
        case .openTasks, .activity: selectedEntry?.entry.projectID
        }
    }

    var selectedFileNode: Node? {
        guard let file = isSearching ? searchPickFile : selectedFile else { return nil }
        return try? store.node(id: file)
    }

    /// The line the conversation column is about, beside a list that spans
    /// projects: the feed, the tasks, or the search results.
    var contextEntry: TimelineItem? { isSearching ? searchPick : selectedEntry }

    /// Reveals a file in place: points the sidebar at the folder that holds it and
    /// selects it in the list, so the surrounding context comes along.
    /// A folder named by its path, from a line that only carries the path. Falls
    /// back to the project when the folder has gone since.
    func showFolder(projectID: UUID, relativePath: String) {
        if let folder = try? store.node(projectID: projectID, relativePath: relativePath) {
            selection = .node(folder.id)
        } else {
            selection = .project(projectID)
        }
    }

    func focus(node: Node) {
        guard !node.isDirectory else {
            selection = .node(node.id)
            return
        }
        let parent = node.parentPath ?? ""
        if parent.isEmpty {
            selection = .project(node.projectID)
        } else if let folder = try? store.node(projectID: node.projectID, relativePath: parent) {
            selection = .node(folder.id)
        } else {
            selection = .project(node.projectID)
        }
        selectedFile = node.id
    }

    /// Everything still inside its coalescing window, across the current project.
    var pendingChanges: [PendingChange] {
        guard let projectID = currentProjectID else { return [] }
        return engineStatus[projectID]?.pending ?? []
    }

    /// Whether what is written into this project can be kept. A project whose
    /// folder cannot be opened has no engine, and a message sent there used to
    /// vanish: the field emptied, the quick note said "Saved", and nothing was.
    /// Why it is not watched is on the banner and in Settings.
    func isWatching(_ projectID: UUID) -> Bool { engines[projectID] != nil }

    /// False when nothing was kept, so the caller can give the text back.
    @discardableResult
    func post(text: String, projectID: UUID, nodeID: UUID?, isTask: Bool,
              assignee: UUID?, categories: Set<UUID>, replyTo: UUID? = nil) async -> Bool {
        guard let engine = engines[projectID], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        do {
            _ = try await engine.post(text: text, nodeID: nodeID, isTask: isTask,
                                      assignee: assignee, categories: categories, replyTo: replyTo)
            return true
        } catch {
            reportFailure(String(localized: "Your message did not go through"), error)
            return false
        }
    }

    /// Changing an entry after the fact. Every one of these travels as a patch in
    /// the log, so the other Mac applies the same change — and a patch that
    /// arrives late loses to a newer one rather than resurrecting an old wording.
    func edit(_ entry: Entry, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.text else { return }
        await patch(EntryPatchRecord(entryID: entry.id, text: trimmed), in: entry.projectID)
    }

    /// Not a deletion: the record stays in the log, it just stops being shown.
    /// A history that can be rewritten is not a history.
    func retract(_ entry: Entry) async {
        await patch(EntryPatchRecord(entryID: entry.id, isRetracted: true), in: entry.projectID)
    }

    /// Undoing a delete. A retraction is a patch like any other, so taking it
    /// back is the reverse patch, and it reaches the other Macs the same way.
    func unretract(_ entry: Entry) async {
        await patch(EntryPatchRecord(entryID: entry.id, isRetracted: false), in: entry.projectID)
    }

    func assign(_ entry: Entry, to memberID: UUID?) async {
        await patch(EntryPatchRecord(entryID: entry.id, assigneeID: .some(memberID)),
                    in: entry.projectID)
    }

    func setCategories(_ ids: Set<UUID>, on entry: Entry) async {
        await patch(EntryPatchRecord(entryID: entry.id, categoryIDs: Array(ids)),
                    in: entry.projectID)
    }

    func setTaskFlag(_ isTask: Bool, on entry: Entry) async {
        await patch(EntryPatchRecord(entryID: entry.id, isTask: isTask), in: entry.projectID)
    }

    private func patch(_ record: EntryPatchRecord, in projectID: UUID) async {
        guard let engine = engines[projectID] else { return }
        do { try await engine.patch(record) }
        catch { reportFailure(String(localized: "The change did not go through"), error) }
    }

    /// Rewriting or withdrawing is the author's business; who a note is for and
    /// what it is filed under is everyone's.
    func canEdit(_ entry: Entry) -> Bool {
        entry.kind == .message && entry.authorID == identity?.member.id
    }

    func setTask(_ entry: Entry, done: Bool) async {
        guard let engine = engines[entry.projectID] else { return }
        try? await engine.patch(EntryPatchRecord(entryID: entry.id, isDone: done))
    }

    private var pendingRead: Set<UUID> = []
    private var readTask: Task<Void, Never>?

    /// An entry counts as read once it has actually been on screen for a moment —
    /// not when its project was clicked. Scrolling past at speed does not count
    /// either, which is why there is a dwell.
    func noteVisible(_ id: UUID) {
        pendingRead.insert(id)
        readTask?.cancel()
        readTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            let ids = Array(self.pendingRead)
            self.pendingRead.removeAll()
            self.markVisibleRead(ids)
        }
    }

    func quotedText(for entryID: UUID) -> String? {
        guard let entry = try? store.entry(id: entryID), !entry.text.isEmpty else { return nil }
        return entry.text
    }

    func markVisibleRead(_ ids: [UUID]) {
        let ids = ids.filter { !keptUnread.contains($0) }
        guard let viewer = identity?.member.id, !ids.isEmpty else { return }
        try? store.markRead(entryIDs: ids, member: viewer)
    }

    /// Entries put back to unread by hand. The line is still on screen when the
    /// menu closes, and the dwell would read it again straight away; it stays
    /// unread until the list has been about something else.
    private var keptUnread: Set<UUID> = []

    func markUnread(_ items: [TimelineItem]) {
        guard let viewer = identity?.member.id else { return }
        let ids = items.map(\.entry.id)
        keptUnread.formUnion(ids)
        try? store.markUnread(entryIDs: ids, member: viewer)
    }

    /// Whether a line can be put back to unread: read, and not your own, which
    /// is never news to you.
    func canMarkUnread(_ item: TimelineItem) -> Bool {
        !item.isUnread && item.entry.authorID != identity?.member.id
    }

    func markAllRead(project: UUID?) {
        guard let viewer = identity?.member.id else { return }
        try? store.markAllRead(projectID: project, member: viewer)
    }

    func rootURL(for projectID: UUID) -> URL? { access.url(for: projectID) }

    /// Resolves a file dropped from the Finder back to a node we know about,
    /// but only inside a watched project — dropping something from elsewhere is
    /// not an invitation to start watching it.
    func node(forDroppedURL url: URL) -> Node? {
        guard let projectID = currentProjectID, let root = access.url(for: projectID) else { return nil }
        let rootPath = root.path(percentEncoded: false)
        let dropped = url.path(percentEncoded: false)
        guard dropped.hasPrefix(rootPath) else { return nil }
        let relative = String(dropped.dropFirst(rootPath.count)).trimmingPrefix("/")
        return try? store.node(projectID: projectID, relativePath: String(relative))
    }

    func url(for node: Node) -> URL? {
        access.url(for: node.projectID)?.appending(path: node.relativePath)
    }

    func reveal(_ node: Node) {
        guard let url = url(for: node) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ node: Node) {
        guard let url = url(for: node) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Quick Look

    /// The file the preview panel is showing, or nothing. Set from a row, the
    /// menu, or the space bar; cleared by any of them and by the panel itself.
    var quickLookURL: URL?

    /// A file iCloud has not put on this Mac cannot be previewed without pulling
    /// it down first, and a preview is never worth a download the user did not
    /// ask for. The row already says so with a cloud icon; "Open" still works and
    /// is the honest way to ask for the file itself.
    func canQuickLook(_ node: Node) -> Bool {
        guard node.state == .present, !node.isDirectory, let url = url(for: node) else { return false }
        return ThumbnailCache.shared.isMaterialised(url)
    }

    /// Pressed on the file already showing, this puts the panel away — the same
    /// rule the space bar follows in the Finder, and the one the stream button
    /// follows here.
    func toggleQuickLook(_ node: Node) {
        guard canQuickLook(node), let url = url(for: node) else { return }
        quickLookURL = quickLookURL == url ? nil : url
    }

    /// What the space bar and ⌘Y act on: the file picked in the middle column.
    func toggleQuickLookForSelection() {
        guard let node = selectedFileNode else { return }
        toggleQuickLook(node)
    }

    // MARK: - Projects

    func addProject(url: URL) async {
        guard let identity else { return }
        // Offered the project a subfolder belongs to, that project may be one this
        // Mac already watches. Adding it twice would give it two engines writing
        // one history; going there is what was meant. Compared by the path on
        // record, not the open access: a project whose drive is not mounted right
        // now is still this Mac's, and still must not be added a second time.
        func normalised(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        let path = normalised(url)
        if let known = projects.first(where: { project in
            guard let recorded = (try? store.projectLocation(project.id))??.path else { return false }
            return normalised(URL(filePath: recorded, directoryHint: .isDirectory)) == path
        }) {
            selection = .project(known.id)
            return
        }
        do {
            let bookmark = try ProjectAccess.makeBookmark(for: url)
            let project = Project(name: url.lastPathComponent)
            try store.addProject(project, rootPath: url.path(percentEncoded: false), bookmark: bookmark)
            projects = (try? store.projects()) ?? []
            await startEngine(for: project, identity: identity)
            selection = .project(project.id)
            failures.removeAll { $0.text == Self.addFailedText }
            refreshAll()
        } catch {
            reportFailure(Self.addFailedText, error)
        }
    }

    private static var addFailedText: String { String(localized: "The folder could not be added") }

    func removeProject(_ id: UUID) async {
        await stopEngine(for: id)
        try? store.removeProject(id)
        refreshAll()
    }

    /// Put away: not watched, not in the sidebar, not in the feed — and kept, with
    /// its history, to be brought back from Settings. For a job that is done but
    /// may come back, where removing it would mean adding the folder again.
    func setArchived(_ id: UUID, _ archived: Bool) async {
        try? store.setProjectArchived(id, archived)
        if archived {
            await stopEngine(for: id)
        } else if let identity, let project = try? store.projects(includeArchived: true)
            .first(where: { $0.id == id }) {
            await startEngine(for: project, identity: identity)
        }
        refreshAll()
    }

    private func stopEngine(for id: UUID) async {
        if let engine = engines[id] { await engine.stop() }
        engines[id] = nil
        statusTasks[id]?.cancel()
        statusTasks[id] = nil
        engineStatus[id] = nil
        access.release(project: id)
        unreachableProjects[id] = nil
        // Standing inside a project that is no longer listed would leave the
        // window showing a folder the sidebar does not have.
        if currentProjectID == id { selection = .activity }
    }

    func revealFolder(_ item: TreeItem) {
        guard let root = rootURL(for: item.projectID) else { return }
        let url = item.path.isEmpty ? root : root.appending(path: item.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Excluding a folder is the escape hatch for the cases the shipped list does
    /// not cover — a render output folder, a scratch directory, somebody's
    /// enormous raw footage. Its history is kept, it just stops producing new
    /// entries.
    func exclude(path: String, in projectID: UUID) async {
        guard !path.isEmpty else { return }
        var paths = (try? store.excludedPaths(for: projectID)) ?? []
        paths.insert(path)
        try? await engines[projectID]?.setExcluded(paths: paths)
        refreshAll()
    }

    func include(path: String, in projectID: UUID) async {
        var paths = (try? store.excludedPaths(for: projectID)) ?? []
        paths.remove(path)
        try? await engines[projectID]?.setExcluded(paths: paths)
        await engines[projectID]?.rescan()
        refreshAll()
    }

    func excludedPaths(for projectID: UUID) -> [String] {
        ((try? store.excludedPaths(for: projectID)) ?? []).sorted()
    }

    // MARK: - People and categories

    /// Your own name and colour. They travel in the log, so the other Mac picks
    /// the change up on its own — there is nobody to notify.
    func updateSelf(name: String, colorHex: String) async {
        guard var identity else { return }
        identity.member.name = name.trimmingCharacters(in: .whitespaces)
        identity.member.colorHex = colorHex
        self.identity = identity
        persist(identity)
        try? store.upsert(member: identity.member)
        for engine in engines.values { try? await engine.update(member: identity.member) }
        refreshAll()
    }

    func rename(category: MacBenchCore.Category, to name: String) async {
        var updated = category
        updated.name = name.trimmingCharacters(in: .whitespaces)
        guard !updated.name.isEmpty else { return }
        await publish(category: updated)
    }

    /// Categories are never hard-deleted: entries already carry them, and a
    /// tombstone is what the other Mac needs in order to agree that it is gone.
    func delete(category: MacBenchCore.Category) async {
        var updated = category
        updated.isDeleted = true
        filter.categories.remove(category.id)
        await publish(category: updated)
    }

    /// Offered, never imposed. The four are only a starting point for somebody who
    /// does not want to think about it on day one.
    func addSuggestedCategories() async {
        for category in MacBenchCore.Category.builtIns where !categories.contains(where: { $0.id == category.id }) {
            await publish(category: category)
        }
    }

    func add(category name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await publish(category: MacBenchCore.Category(
            name: trimmed, colorHex: MemberPalette.next(after: categories.map(\.colorHex)),
            sortIndex: categories.count))
    }

    private func publish(category: MacBenchCore.Category) async {
        try? store.upsert(category: category)
        for engine in engines.values { try? await engine.publish(categories: [category]) }
        refreshAll()
    }

    func setVerbosity(_ verbosity: Verbosity, for projectID: UUID) {
        try? store.setVerbosity(verbosity, for: projectID)
        refreshDetail()
    }

    func verbosity(for projectID: UUID) -> Verbosity {
        (try? store.verbosity(for: projectID)) ?? .everything
    }

    func rescan(_ projectID: UUID) async {
        await engines[projectID]?.rescan()
    }

    func exportMarkdown(project: Project) -> String? {
        guard let viewer = identity?.member.id else { return nil }
        var filter = TimelineFilter()
        filter.limit = 100_000
        guard let items = try? store.timeline(scope: .project(project.id), filter: filter, viewer: viewer)
        else { return nil }
        return MarkdownExport().render(project: project, items: items)
    }
}
