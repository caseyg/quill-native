import SwiftUI
import QuillCore

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    let zoom: Namespace.ID
    @State private var search = ""
    @State private var askingForURL = false
    @State private var editURL = ""

    private var drafts: [Draft] {
        store.drafts.filter { search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search) }
    }
    private var posts: [Receipt] {
        store.receipts.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if !drafts.isEmpty {
                Section("Drafts") {
                    ForEach(drafts) { draft in
                        Button { store.open(draft) } label: {
                            PostRow(symbol: draft.kind.symbol, title: draft.displayTitle, date: draft.modified)
                        }
                        .zoomSource(draft.id.uuidString, in: zoom)
                        .swipeActions {
                            Button(role: .destructive) { store.remove(draft) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button(role: .destructive) { store.remove(draft) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            if !posts.isEmpty {
                Section("Posted") {
                    ForEach(posts) { post in
                        Button { openURL(post.url) } label: {
                            PostRow(symbol: post.kind.symbol, title: post.title, date: post.date, status: post.status == "Published" ? nil : post.status)
                        }
                        .swipeActions {
                            ShareLink(item: post.url) { Label("Share", systemImage: "square.and.arrow.up") }.tint(.accentColor)
                        }
                        .contextMenu {
                            ShareLink(item: post.url) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button { UIPasteboard.general.url = post.url } label: { Label("Copy Link", systemImage: "link") }
                            if [.like, .repost, .code].contains(post.kind) {
                                Button { Task { await store.edit(post.url.absoluteString) } } label: { Label("Edit", systemImage: "pencil") }
                            }
                            Divider()
                            Button(role: .destructive) { store.forget(post) } label: { Label("Remove from List", systemImage: "minus.circle") }
                        }
                    }
                }
            }
        }
        .animation(.snappy, value: store.drafts.map(\.id))
        .animation(.snappy, value: store.receipts.map(\.id))
        .overlay {
            if store.drafts.isEmpty && store.receipts.isEmpty {
                ContentUnavailableView("No Posts", systemImage: "square.and.pencil")
            } else if drafts.isEmpty && posts.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .navigationTitle(store.account?.me.host ?? "Posts")
        .searchable(text: $search)
        .refreshable { store.reloadDrafts(); await store.refresh() }
        .toolbar { toolbar }
        .alert("Edit Post", isPresented: $askingForURL) {
            TextField("URL", text: $editURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { editURL = "" }
            Button("Edit") { let url = editURL; editURL = ""; Task { await store.edit(url) } }
        }
        .sensoryFeedback(.success, trigger: store.receipts.count) { old, new in new > old }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape") { store.showSettings = true }
                .accessibilityIdentifier("settings")
        }
        if #available(iOS 26.0, *) {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { composeButton }
                .matchedTransitionSource(id: AppStore.composeSource, in: zoom)
        } else {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                composeButton.zoomSource(AppStore.composeSource, in: zoom)
            }
        }
    }

    /// Tap for a note. Touch and hold for every other kind of post.
    private var composeButton: some View {
        Menu {
            ForEach(PostKind.allCases) { kind in
                Button { store.compose(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
            }
            Divider()
            Button { askingForURL = true } label: { Label("Edit Post…", systemImage: "pencil.line") }
        } label: {
            Label("New Post", systemImage: "square.and.pencil")
        } primaryAction: {
            store.compose(.note)
        }
        .accessibilityIdentifier("compose")
    }
}

private struct PostRow: View {
    let symbol: String
    let title: String
    let date: Date
    var status: String?

    var body: some View {
        // Explicit Colors: inside a List Button, hierarchical .primary resolves to the tint.
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2).foregroundStyle(Color.primary)
                HStack(spacing: 4) {
                    if let status { Text(status); Text("·") }
                    Text(date, format: .relative(presentation: .named))
                }
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
