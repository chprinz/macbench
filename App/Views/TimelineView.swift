import SwiftUI
import MacBenchCore

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    /// Passed in rather than read off the model: the same view is the feed in the
    /// middle column and the conversation beside it, and those are two lists.
    let items: [TimelineItem]
    let emptyTitle: LocalizedStringKey
    let emptyHint: LocalizedStringKey
    /// The feed picks a line, and the column beside it shows what was said around
    /// it. A conversation has nothing to pick.
    var selectsRows = false
    /// Whether there may be more before the first line shown, and how to get it.
    var reachesFurther = false
    var showEarlier: @MainActor () -> Void = {}
    /// The first entry that was unread when this stream was opened. Frozen on
    /// purpose: entries are marked read as they scroll past, so without holding
    /// it the "new from here" line would erase itself while you read.
    @State private var unreadAnchor: UUID?
    @State private var hasRestoredPosition = false

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 0) {
                    EmptyStateView(title: emptyTitle, hint: emptyHint)
                    PendingChangesBar()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            if reachesFurther {
                                EarlierMarker(shown: items.count, action: showEarlier)
                            }
                            ForEach(days, id: \.day) { group in
                                Section {
                                    ForEach(group.rows) { row in
                                        rowView(row)
                                    }
                                } header: {
                                    DayHeader(text: Format.dayHeading(group.day))
                                }
                            }
                            PendingChangesBar()
                            Color.clear.frame(height: 8).id(bottomAnchor)
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: items.last?.id) { _, _ in
                        guard hasRestoredPosition else { return }
                        withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                    }
                    .onChange(of: items.count) { _, _ in restorePosition(proxy) }
                    .onChange(of: model.flashingEntry) { _, id in
                        // Picking a line elsewhere brings it into view here. A
                        // result from a search can be months back, and the
                        // column opening at the end left it to be scrolled to.
                        guard let id, items.contains(where: { $0.id == id }) else { return }
                        hasRestoredPosition = true
                        DispatchQueue.main.async {
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                    .onAppear { restorePosition(proxy) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.selection) { _, _ in reset() }
        .onChange(of: model.selectedFile) { _, _ in reset() }
        .onChange(of: model.isSearching) { _, _ in reset() }
    }

    private func reset() {
        unreadAnchor = nil
        hasRestoredPosition = false
    }

    /// Opens the stream where you stopped reading, not at the end. If everything
    /// has been read, the end is where you stopped.
    private func restorePosition(_ proxy: ScrollViewProxy) {
        if unreadAnchor == nil {
            // A row, not an entry: the first unread entry may be folded into a
            // line that carries another one's id.
            unreadAnchor = ChangeDigest.fold(items).first { $0.item.isUnread }?.id
        }
        guard !hasRestoredPosition, !items.isEmpty else { return }
        hasRestoredPosition = true
        let flashing = model.flashingEntry.flatMap { id in items.contains { $0.id == id } ? id : nil }
        DispatchQueue.main.async {
            if let flashing {
                proxy.scrollTo(flashing, anchor: .center)
            } else if let unreadAnchor {
                proxy.scrollTo(unreadAnchor, anchor: .top)
            } else {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    private let bottomAnchor = "timeline-bottom"

    /// Picked rows stay marked; the row the conversation column has just been
    /// pointed at lights up once and fades, so that arriving somewhere is visible
    /// rather than something you have to work out.
    private func background(for item: TimelineItem) -> Color {
        if model.flashingEntry == item.id { return .accentColor.opacity(0.28) }
        if selectsRows, model.selectedEntry?.id == item.id { return .accentColor.opacity(0.12) }
        return .clear
    }



    @ViewBuilder
    private func rowView(_ row: DigestRow) -> some View {
        let item = row.item
        VStack(alignment: .leading, spacing: 0) {
            if item.id == unreadAnchor { NewFromHereMarker() }
            EntryRow(item: item, folded: row.isFolded ? row.members : [],
                     selectable: !selectsRows,
                     showsContextAction: selectsRows,
                     showsPath: selectsRows,
                     projectName: selectsRows
                        ? model.projectLabel(for: item.entry, narrowedTo: model.filter.project)
                        : nil)
                .padding(.horizontal, selectsRows ? 8 : 0)
                .background(background(for: item), in: .rect(cornerRadius: 6))
                .animation(.easeOut(duration: 0.45), value: model.flashingEntry)
        }
        .id(item.id)
        .contentShape(.rect)
        // Before the single click, or the single one swallows it.
        .onTapGesture(count: 2) {
            if selectsRows { model.selectedEntry = item }
            if let node = item.node, !node.isPlaceholder { model.open(node) }
        }
        .onTapGesture { if selectsRows { model.selectedEntry = item } }
        .onAppear {
            // Seeing the line is seeing everything folded into it.
            for member in row.members where member.isUnread { model.noteVisible(member.entry.id) }
        }
    }

    /// Groups the timeline by day, with each file's changes told once a day.
    /// Without this, one afternoon of saving a layout buried a sentence somebody
    /// actually wrote. It used to hide runs of changes instead, behind "12 minor
    /// changes hidden" — which hid exactly what opening the app is for: what
    /// changed.
    private var days: [(day: Date, rows: [DigestRow])] {
        let calendar = Calendar.current
        var result: [(day: Date, rows: [DigestRow])] = []
        for row in ChangeDigest.fold(items, calendar: calendar) {
            let day = calendar.startOfDay(for: row.item.entry.createdAt)
            if result.last?.day == day {
                result[result.count - 1].rows.append(row)
            } else {
                result.append((day: day, rows: [row]))
            }
        }
        return result
    }
}

/// Changes that have happened but are still being gathered.
///
/// Without this the app looks broken for the first twenty minutes: you save a
/// file, nothing appears, and there is no way to tell whether it is working. The
/// waiting is deliberate — this says so.
struct PendingChangesBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.pendingChanges
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(pending.prefix(4)) { change in
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text((change.relativePath as NSString).lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if change.count > 1 {
                            Text("×\(change.count)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text(change.dueAt, style: .relative)
                            .font(.caption2).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                }
                if pending.count > 4 {
                    Text("and \(pending.count - 4) more")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .help("Seen, not yet written. Quiet changes are gathered for twenty minutes so an afternoon of saving becomes one line.")
        }
    }
}

/// Where you stopped reading last time.
private struct NewFromHereMarker: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
            Text("New from here")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.accentColor)
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 6)
    }
}

private struct DayHeader: View {
    let text: String
    var body: some View {
        HStack {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Rectangle().fill(.separator).frame(height: 1)
        }
        .padding(.vertical, 6)
        .background(.background)
    }
}

struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let item: TimelineItem
    /// The changes this line sums up, when it sums up more than one.
    var folded: [TimelineItem] = []
    /// Off in the feed: selectable text swallows the click that picks the row, so
    /// in the one list where picking a row is the whole point, a click on the
    /// sentence would do nothing. Copying is still on the right-click menu.
    var selectable = true
    /// In the feed: the way to the conversation this line belongs to.
    var showsContextAction = false
    /// In the feed: the file as a path, because the feed spans every folder.
    var showsPath = false
    /// In the feed: which project this line is from, when the feed spans several.
    var projectName: String?
    /// Where nothing above the row says which day it was: in search results,
    /// which are not grouped by day, the date goes next to the name.
    var showsDay = false
    @State private var isHovering = false
    @State private var draft: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(item.isUnread ? Color.accentColor : .clear)
                .frame(width: 2)
                .clipShape(.capsule)

            if item.entry.kind == .message {
                messageBody
            } else {
                systemBody
            }
        }
        .padding(.vertical, item.entry.kind == .message ? 8 : 2)
        .onHover { isHovering = $0 }
        .contextMenu {
            EntryMenu(item: item, folded: folded, draft: $draft, offersStream: showsContextAction)
        }
    }

    /// The time, in a column of its own down the left edge. It used to follow the
    /// name, with the date again under a heading that already said the day, and
    /// every other row began its sentence somewhere else.
    private var timeText: some View {
        Text(isReconstructed
             ? "~" + Format.time(item.entry.createdAt)
             : Format.time(item.entry.createdAt))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: TimeGutter.width, alignment: .leading)
    }

    /// Where the line is, under who and which file, and quieter than both. On
    /// the same line it pushed the file name into "Ers…ch_Zusammenfassung.txt"
    /// and made one grey sentence of name, time, project, folder and file.
    private var whereTag: PathTag? {
        guard showsPath else { return nil }
        let tag = PathTag(projectID: item.entry.projectID, projectName: projectName,
                          node: fileNode, includesFile: false)
        return tag.isEmpty ? nil : tag
    }

    private var messageBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: TimeGutter.spacing) {
                timeText
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AuthorName(member: item.author)
                        .font(.callout.weight(.semibold))
                        .fixedSize()
                    // The file gives way first, and in the middle: the name and
                    // what kind of line this is are shorter and say more.
                    if let node = fileNode {
                        FileTag(node: node)
                            .layoutPriority(-1)
                    }
                    if item.entry.textEditedAt != nil {
                        Text("edited")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    if showsDay {
                        Text(item.entry.createdAt.formatted(.dateTime.day().month(.abbreviated).year()))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                    trailingActions
                }
            }
            if let whereTag {
                whereTag
                    .padding(.leading, TimeGutter.inset - 3)
                    .padding(.top, -2)
            }
            if let replyTo = item.entry.replyToID, let quoted = model.quotedText(for: replyTo) {
                HStack(spacing: 4) {
                    Rectangle().fill(.tertiary).frame(width: 2)
                    Text(quoted)
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(.leading, TimeGutter.inset)
                .padding(.bottom, 1)
            }
            HStack(alignment: .firstTextBaseline, spacing: TimeGutter.spacing) {
                // A task's box stands in the time column, against the text, so the
                // sentence starts where every other sentence starts. In front of
                // the text it indented tasks and nothing else.
                Group {
                    if item.entry.isTask {
                        TaskCheckbox(isDone: item.entry.isDone) { done in
                            Task { await model.setTask(item.entry, done: done) }
                        }
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
                .frame(width: TimeGutter.width, alignment: .trailing)
                messageText
            }
            if !item.categories.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.categories) { category in
                        Text(Format.categoryName(category))
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(hex: category.colorHex).opacity(0.16), in: .capsule)
                    }
                }
                .padding(.leading, TimeGutter.inset)
            }
        }
    }

    @ViewBuilder
    private var messageText: some View {
        if draft != nil {
            // Deliberately not Binding($draft): that projection force-
            // unwraps, and committing the edit sets draft to nil while
            // SwiftUI is still reading through it — which is a crash, not
            // a redraw. This one reads the optional and survives it.
            let editing = Binding(get: { draft ?? "" }, set: { draft = $0 })
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: editing, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onKeyPress(keys: [.escape], phases: .down) { _ in
                        draft = nil
                        return .handled
                    }
                    .onReturnKey(perform: commitEdit)
                HStack(spacing: 8) {
                    Button("Save") { commitEdit() }
                    Button("Cancel") { draft = nil }
                }
                .controlSize(.small)
            }
        } else {
            Text(attributedText)
                .font(.body)
                .modifier(SelectableText(isOn: selectable))
                .strikethrough(item.entry.isDone, color: .secondary)
                .foregroundStyle(item.entry.isDone ? .secondary : .primary)
        }
    }

    /// One quiet line. A change is told as the sentence it is — "Mara hat
    /// Zeitplan.pages angelegt" — with where it happened after it, not inside it:
    /// with the path in place of the file the sentence came apart into "Tom hat
    /// Kunde A › 1. Konzept › … angelegt", and the indented line read as part of
    /// the message above.
    private var systemBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: TimeGutter.spacing) {
            timeText
                .font(.caption2.monospacedDigit())
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: symbolName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                // Laid out to wrap rather than to squeeze: in a 240-point column
                // the sentence has to give way somewhere, and a second line is
                // better than a file called "br…df".
                FlowLayout(spacing: 4) {
                    if let parts = sentenceAroundFile, let node = fileNode {
                        let before = parts.before.trimmingCharacters(in: .whitespaces)
                        let after = parts.after.trimmingCharacters(in: .whitespaces)
                        if !before.isEmpty { Text(before) }
                        FileTag(node: node, shortenedTo: 44)
                        if !after.isEmpty { Text(after) }
                    } else {
                        Text(phrase)
                    }
                    if let whereTag {
                        whereTag
                    }
                }
                Spacer(minLength: 0)
                trailingActions
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(helpText)
    }

    /// For a folded line, when each change happened and whose it was.
    private var helpText: String {
        if !folded.isEmpty {
            return folded.map { member in
                "\(Format.timestamp(member.entry.createdAt))  \(member.author?.name ?? String(localized: "Unknown"))"
            }.joined(separator: "\n")
        }
        var lines: [String] = []
        if isReconstructed {
            lines.append(String(localized: "Found by comparing the folder, because the app was not running. The time is approximate."))
        }
        if item.author == nil {
            lines.append(String(localized: "Could not tell which Mac this change came from. The name is filled in if that Mac's log turns up."))
        }
        return lines.joined(separator: "\n\n")
    }

    private var isReconstructed: Bool { item.entry.event?.backfilled == true }

    private var fileNode: Node? {
        guard let node = item.node, !node.isPlaceholder else { return nil }
        return node
    }

    /// The sentence with the file's name taken out of it, so the name can be the
    /// chip and the rest stays the sentence it was.
    private var sentenceAroundFile: (before: String, after: String)? {
        guard let node = fileNode, let range = phrase.range(of: node.name) else { return nil }
        return (String(phrase[phrase.startIndex..<range.lowerBound]),
                String(phrase[range.upperBound...]))
    }

    /// Everything a row offers, in one place at the outer edge and in the same
    /// order everywhere: what this line is about, then the menu. Visible only
    /// while the pointer is on the row — everything here is on the right-click
    /// menu too.
    @ViewBuilder
    private var trailingActions: some View {
        if draft == nil {
            let isShown = isHovering || isPicked
            RowActions(node: fileNode, showsFileActions: !showsPath) {
                EntryMenu(item: item, folded: folded, draft: $draft, offersStream: showsContextAction)
            }
            .hoverReveal(isShown)
        }
    }

    private var isPicked: Bool { showsContextAction && model.selectedEntry?.id == item.id }

    /// Mentions are already coloured inside the sentence, so saying the name
    /// again would say the same thing twice. A recipient chosen from the menu,
    /// where the text says nothing, is written in front of it as a mention would
    /// be: "@Mara" there is the same sentence as one line under it, and quieter.
    private var prefixesRecipient: Bool {
        guard let assignee = item.assignee else { return false }
        return Mentions.parse(item.entry.text, members: [assignee]).isEmpty
    }

    private var attributedText: AttributedString {
        let text = item.entry.text
        let links = Format.links(in: text).map(\.range)
        let matches = Mentions.parse(text, members: model.members)
            .filter { match in !links.contains { $0.overlaps(match.range) } }
        var result = AttributedString()
        if let assignee = item.assignee, prefixesRecipient {
            var mention = AttributedString("@" + assignee.name.trimmingCharacters(in: .whitespaces))
            mention.foregroundColor = Color(hex: assignee.colorHex)
            mention.font = .body.weight(.medium)
            result += mention + AttributedString(" ")
        }
        var cursor = text.startIndex
        for match in matches {
            result += Format.linked(text[cursor..<match.range.lowerBound])
            var mention = AttributedString(text[match.range])
            mention.foregroundColor = Color(hex: match.member.colorHex)
            mention.font = .body.weight(.medium)
            result += mention
            cursor = match.range.upperBound
        }
        result += Format.linked(text[cursor...])
        return result
    }

    private func commitEdit() {
        guard let text = draft else { return }
        draft = nil
        Task { await model.edit(item.entry, text: text) }
    }

    private var symbolName: String {
        if item.entry.notice == .joined { return "person.crop.circle.badge.plus" }
        return item.entry.event?.type.symbolName ?? "circle"
    }

    private var phrase: String {
        // Somebody joining is built here rather than read out of the entry: the
        // sentence in the log is in the language of whoever joined, and this is
        // the one line in the stream that was written by the other Mac's locale.
        if item.entry.notice == .joined {
            guard let author = item.author else { return item.entry.text }
            return String(localized: "\(author.name) is now in this project")
        }
        guard let event = item.entry.event else { return item.entry.text }
        let name = item.node?.name ?? String(localized: "a file")
        // Without an author the sentence is about the file: "Someone" at the
        // front of every other line said nothing and read like an accusation of
        // nobody. What it cannot say is in the tooltip.
        let action = EventPhrase(event: event, fileName: name, authorIsKnown: item.author != nil).text
        guard let author = item.author else { return action }
        return "\(author.name) \(action)"
    }
}

/// The column of times down the left edge of a stream. As wide as the widest
/// time this locale writes, so that whatever the hour, every sentence starts at
/// the same place.
enum TimeGutter {
    static let spacing: CGFloat = 8

    static let width: CGFloat = {
        let size = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        var parts = DateComponents()
        parts.hour = 22
        parts.minute = 58
        let widest = Calendar.current.date(from: parts).map { "~" + Format.time($0) } ?? "~00:00"
        return ceil((widest as NSString).size(withAttributes: [.font: font]).width) + 2
    }()

    /// Where the text of a row starts, for the lines under the first.
    static var inset: CGFloat { width + spacing }
}

/// The box that ticks a task off, in the stream and in the task list alike.
/// Drawn rather than the system checkbox, whose dark fill all but disappeared on
/// a dark window: a task read as a sentence with a smudge in front of it.
struct TaskCheckbox: View {
    let isDone: Bool
    let set: (Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        Button { set(!isDone) } label: {
            Image(systemName: isDone ? "checkmark.square.fill" : "square")
                .font(.body)
                .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isDone ? "Mark as Open" : "Mark as Done")
        .accessibilityRepresentation {
            Toggle(isDone ? "Mark as Open" : "Mark as Done",
                   isOn: Binding(get: { isDone }, set: { set($0) }))
        }
    }
}

/// The author's name in their colour. The colour used to sit in a dot in front of
/// the name, which is where Mail and Messages put "unread", and a dot that never
/// went away read as a line nobody could ever mark as read.
struct AuthorName: View {
    let member: Member?
    var body: some View {
        Text(member?.name ?? String(localized: "Unknown"))
            .foregroundStyle(member.map { AnyShapeStyle(Color(hex: $0.colorHex)) } ?? AnyShapeStyle(.secondary))
    }
}

struct EntryMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let item: TimelineItem
    /// The changes the line sums up, when it sums up more than one.
    var folded: [TimelineItem] = []
    @Binding var draft: String?
    /// In the lists beside the stream column: the way to this line's conversation.
    var offersStream = false

    var body: some View {
        if offersStream {
            StreamMenuButton(isShowingThis: model.selectedEntry?.id == item.id && model.isStreamVisible) {
                model.selectedEntry = item
            }
            Divider()
        }
        if item.entry.kind == .message {
            Button("Reply") {
                // Go to the file it was about, not just to the project. The
                // composer attaches to whatever is selected, so jumping to the
                // project detached the answer from the thing being discussed —
                // and left the reply sitting at the top level of an unrelated view.
                switch model.selection {
                case .openTasks, .activity:
                    // Beside these lists the column is already that conversation,
                    // so there is nowhere to go.
                    model.selectedEntry = item
                case .project, .node:
                    if let node = item.node, !node.isPlaceholder {
                        model.focus(node: node)
                    } else {
                        model.selection = .project(item.entry.projectID)
                    }
                }
                model.replyTarget = item
            }
            if model.canEdit(item.entry) {
                Button("Edit") { draft = item.entry.text }
            }
            Divider()

            Button(item.entry.isTask
                   ? String(localized: "Not a task") : String(localized: "Make it a task")) {
                Task { await model.setTaskFlag(!item.entry.isTask, on: item.entry) }
            }
            if item.entry.isTask {
                Button(item.entry.isDone
                       ? String(localized: "Mark as Open") : String(localized: "Mark as Done")) {
                    Task { await model.setTask(item.entry, done: !item.entry.isDone) }
                }
            }

            Menu("For") {
                Button("Nobody in particular") {
                    Task { await model.assign(item.entry, to: nil) }
                }
                ForEach(model.members) { member in
                    Button(member.name) {
                        Task { await model.assign(item.entry, to: member.id) }
                    }
                }
            }
            if !model.categories.isEmpty {
                Menu("Categories") {
                    ForEach(model.categories) { category in
                        Button {
                            var ids = item.entry.categoryIDs
                            if ids.contains(category.id) { ids.remove(category.id) }
                            else { ids.insert(category.id) }
                            Task { await model.setCategories(ids, on: item.entry) }
                        } label: {
                            HStack {
                                Text(Format.categoryName(category))
                                if item.entry.categoryIDs.contains(category.id) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            Divider()
        }

        if let node = item.node, !node.isPlaceholder {
            Button("Show in Finder") { model.reveal(node) }
            Button("Open") { model.open(node) }
            if model.canOpenInMarkEdit(node) {
                Button("Open in MarkEdit") { model.openInMarkEdit(node) }
            }
            Button("Go to File") { model.focus(node: node) }
            Divider()
        }

        if model.canMarkUnread(item) {
            Button("Mark as Unread") {
                model.markUnread(folded.isEmpty ? [item] : folded)
            }
        }
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.entry.text, forType: .string)
        }
        if model.canEdit(item.entry) {
            Button("Delete", role: .destructive) {
                let entry = item.entry
                Task { await model.retract(entry) }
                // Gone from every list the moment it is deleted, so the one way
                // back is Edit ▸ Undo, where a Mac user looks for it.
                undoManager?.registerUndo(withTarget: model) { model in
                    Task { @MainActor in await model.unretract(entry) }
                }
                undoManager?.setActionName(String(localized: "Delete"))
            }
        }
    }
}

/// The two selectability values are different types, so the choice cannot be made
/// with a ternary inside the modifier.
private struct SelectableText: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}

struct EmptyStateView: View {
    let title: LocalizedStringKey
    let hint: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.title3.weight(.medium)).foregroundStyle(.secondary)
            Text(hint).font(.callout).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Where a list stops going back. It used to stop without a word, and a
/// project's first weeks looked like weeks in which nothing had happened.
private struct EarlierMarker: View {
    let shown: Int
    let action: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Only the latest \(shown) entries are shown.")
                .font(.caption).foregroundStyle(.tertiary)
            Button("Show earlier", action: action)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
