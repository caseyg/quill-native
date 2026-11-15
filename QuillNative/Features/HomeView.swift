import SwiftUI
import QuillCore

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    let zoom: Namespace.ID
    @State private var search = ""
    @State private var askingForURL = false
    @State private var editURL = ""
    @State private var deleting: Post?

    private var drafts: [Draft] {
        store.drafts.filter { search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search) }
    }
    private var posts: [Post] {
        let hidden = Set(store.preferences.hiddenKinds)
        return store.library.search(search).filter { !hidden.contains($0.kind) }
    }

    var body: some View {
        List {
            if !drafts.isEmpty {
                Section("Drafts") {
                    ForEach(drafts) { draft in
                        Button { store.open(draft) } label: {
                            PostRow(symbol: draft.kind.symbol, title: draft.displayTitle, date: draft.modified, photo: draft.attachments.first.map { Thumbnail.local($0.data) })
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
                Section("Posts") {
                    ForEach(posts) { post in
                        Button { open(post) } label: {
                            PostRow(symbol: post.kind.symbol, title: post.displayTitle, date: post.published, status: post.isDraft ? "Draft" : post.citeName.flatMap { $0 == post.displayTitle || post.displayTitle.hasPrefix($0) ? nil : $0 }, photo: post.photo.map(Thumbnail.remote), loading: store.opening == post.id)
                        }
                        .task(id: post.id) { await store.describe(post) }
                        .zoomSource(post.id, in: zoom)
                        .swipeActions {
                            Button { deleting = post } label: { Label("Delete", systemImage: "trash") }.tint(.red)
                            if post.kind.isEditable {
                                Button { Task { await store.edit(post) } } label: { Label("Edit", systemImage: "pencil") }.tint(.accentColor)
                            }
                            Button { openURL(post.url) } label: { Label("See on Web", systemImage: "globe") }.tint(.gray)
                        }
                        .contextMenu {
                            if post.kind.isEditable {
                                Button { Task { await store.edit(post) } } label: { Label("Edit", systemImage: "pencil") }
                            }
                            Button { openURL(post.url) } label: { Label("See on Web", systemImage: "globe") }
                            ShareLink(item: post.url) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button { UIPasteboard.general.url = post.url } label: { Label("Copy Link", systemImage: "link") }
                            Divider()
                            Button(role: .destructive) { deleting = post } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .animation(.snappy, value: store.drafts.map(\.id))
        .animation(.snappy, value: store.library.posts.map(\.id))
        .overlay {
            if store.drafts.isEmpty && store.library.posts.isEmpty {
                if store.syncing { ProgressView() } // Until the first page arrives.
                else { ContentUnavailableView("No Posts", systemImage: "square.and.pencil") }
            } else if drafts.isEmpty && posts.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let progress = store.syncProgress, progress.count > 0 { SyncBar(progress: progress).transition(.opacity) }
        }
        .animation(.snappy, value: store.syncProgress == nil)
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
        .confirmationDialog("Delete Post", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { post in
            Button("Delete", role: .destructive) { Task { await store.delete(post) } }
        } message: { post in
            Text(post.displayTitle)
        }
        .sensoryFeedback(.success, trigger: store.receipts.count) { old, new in new > old }
    }

    /// Editable posts open in the composer. Others open on the site.
    private func open(_ post: Post) {
        if post.kind.isEditable { Task { await store.edit(post) } } else { openURL(post.url) }
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
            ForEach(store.preferences.visibleKinds) { kind in
                Button { store.compose(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
            }
            Divider()
            Button { askingForURL = true } label: { Label("Edit Post…", systemImage: "pencil.line") }
        } label: {
            Label("New Post", systemImage: "square.and.pencil")
        } primaryAction: {
            store.compose(store.preferences.visibleKinds.first ?? .note)
        }
        .accessibilityIdentifier("compose")
    }
}

/// A slim bar while posts download, so the list stays usable.
private struct SyncBar: View {
    let progress: AppStore.SyncProgress

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).animation(.snappy, value: fraction)
                count
            } else {
                // A first sync can't know how many posts there are, only how many have arrived.
                ProgressView().controlSize(.mini)
                count
                Spacer(minLength: 0)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing \(progress.count) posts")
    }

    private var count: some View {
        Text("\(progress.count) Posts").monospacedDigit().contentTransition(.numericText())
    }
}

enum Thumbnail {
    case local(Data)
    case remote(URL)
}

private struct PostRow: View {
    let symbol: String
    let title: String
    let date: Date?
    var status: String?
    var photo: Thumbnail?
    var loading = false

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
                    if let status { Text(status) }
                    if status != nil && date != nil { Text("·") }
                    if let date { Text(date, format: .relative(presentation: .named)) }
                }
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
            if loading {
                ProgressView()
            } else if let photo {
                PhotoView(photo: photo)
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct PhotoView: View {
    let photo: Thumbnail
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            switch photo {
            case .remote(let url):
                AsyncImage(url: url, transaction: Transaction(animation: .snappy)) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            case .local:
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
        }
        .task {
            guard case .local(let data) = photo else { return }
            image = await Task.detached { UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 144, height: 144)) }.value
        }
    }
}
