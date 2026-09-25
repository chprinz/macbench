import SwiftUI
import MacBenchCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // Read once, at launch, and never again while the window is open.
    //
    // This used to be an @AppStorage value written from the same measurement that
    // feeds it back as the ideal width. Dragging the divider then fought itself:
    // every frame of the drag stored a width, which re-applied an ideal width,
    // which moved the divider back.
    @State private var idealSidebarWidth = Layout.sidebarWidth
    /// The middle column's width, which is all the room the search field has.
    @State private var filesWidth: CGFloat = 600

    /// The sidebar's width lives in plain UserDefaults rather than @AppStorage on
    /// purpose: it is written while dragging, and nothing about that should
    /// redraw a view.
    enum Layout {
        static var sidebarWidth: Double { read("layout.sidebarWidth", default: 300) }

        /// The stream's width is a constant, not something to be remembered.
        /// Its divider cannot be dragged - the inspector AppKit builds for it
        /// holds still no matter where it is taken hold of - so the only width
        /// it ever has is this one, and a remembered measurement of it could
        /// only ever narrow it below what is set here.
        static let streamWidth: Double = 340

        static func remember(_ width: CGFloat, as key: String, above minimum: CGFloat) {
            guard width > minimum else { return }
            UserDefaults.standard.set(Double(width.rounded()), forKey: key)
        }

        private static func read(_ key: String, default fallback: Double) -> Double {
            let stored = UserDefaults.standard.double(forKey: key)
            return stored > 0 ? stored : fallback
        }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.identity == nil {
                OnboardingView()
            } else {
                // Where am I, which files, what was said. The stream is an
                // inspector rather than a third column: it comments on the current
                // selection, and it can be put away when you just want the files.
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: idealSidebarWidth, max: 460)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            Layout.remember(width, as: "layout.sidebarWidth", above: 150)
                        }
                } detail: {
                    FilesColumn()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            filesWidth = width
                        }
                        .inspector(isPresented: $model.isStreamVisible) {
                            StreamColumn()
                                // Wide enough to read a sentence in, because
                                // this width is the one it keeps: the divider
                                // does not move, whatever is done to it.
                                .inspectorColumnWidth(min: 280, ideal: Layout.streamWidth, max: 620)
                        }
                        .toolbar {
                            // Principal, not `.searchable`: SwiftUI's search field
                            // lands wherever the split view feels like putting it,
                            // which was on top of the sidebar. This one sits over
                            // the column it searches.
                            ToolbarItem(placement: .principal) {
                                SearchField(text: $model.searchText, room: filesWidth)
                            }
                            ToolbarItem(placement: .primaryAction) {
                                Button {
                                    model.isStreamVisible.toggle()
                                } label: {
                                    // Word and icon: the bubble alone did not say
                                    // what it opens, and was a small target.
                                    Label("Messages", systemImage: "text.bubble")
                                        .labelStyle(.titleAndIcon)
                                        .padding(.horizontal, 4)
                                }
                                // ⌘2 lives on the View menu, beside ⌘1 for the sidebar.
                                .help("Show or hide the messages: the changes and conversation around what is selected")
                            }
                        }
                }
                .overlay(alignment: .top) { BannerStack() }

            }
        }
        .animation(.default, value: model.identity == nil)
    }
}

struct SearchField: View {
    @Binding var text: String
    /// The width of the column it sits over. The toolbar item cannot see it.
    var room: CGFloat
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Search files and messages", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onKeyPress(keys: [.escape], phases: .down) { _ in
                    text = ""
                    isFocused = false
                    return .handled
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
            }
        }
        // No background of its own: the toolbar already puts its items in a
        // capsule, and drawing a second one inside it is what made this look like
        // a grey box someone had dropped in the title bar.
        // A wide minimum here is a minimum for the whole window: the toolbar cannot
        // shrink below its items, and the columns then hang over the edges.
        //
        // An ideal width did not help either. The toolbar gave the field its ideal
        // whatever the column had, so over a narrow column it ran into the
        // messages and pushed their button off the window. It is told what the
        // column leaves beside the title instead.
        .frame(width: min(520, max(140, room - Self.titleRoom)))
    }

    /// The window title and the margins around it, left of the field.
    private static let titleRoom: CGFloat = 190
}

/// Sync problems are shown, never swallowed. "Nothing new" and "we could not
/// read what is new" must not look the same.
struct BannerStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.banners) { banner in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: banner.level == .warning
                          ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(banner.level == .warning ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.text).font(.callout.weight(.medium))
                        if let detail = banner.detail {
                            // Three lines, then the tooltip. A permission error
                            // quotes a path twice and was covering the window it
                            // was warning about.
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(3)
                                .help(detail)
                        }
                    }
                    Spacer(minLength: 0)
                    // A warning you cannot put away stops being a warning and
                    // becomes furniture. It comes back on the next launch while
                    // the condition lasts, and Settings keeps the reason.
                    Button {
                        model.dismiss(banner)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Hide this message. It comes back next time the app starts if the problem is still there.")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: 520)
                .background(.regularMaterial, in: .rect(cornerRadius: 10))
                .shadow(radius: 6, y: 2)
            }
        }
        .padding(.top, 8)
        .animation(.default, value: model.banners)
    }
}
