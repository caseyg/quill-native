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
    @State private var syndicating: Post?

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
                            PostRow(symbol: draft.kind.symbol, title: draft.displayTitle, date: draft.modified, photo: draft.attachments.first { !$0.isAudio }.map { Thumbnail.local($0.data) })
                        }
                        .zoomSource(draft.id.uuidString, in: zoom)
                        .swipeActions {
                            Button(role: .destructive) { store.remove(draft) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            if let url = store.github.webURL(for: draft) {
                                Button { openURL(url) } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                                Divider()
                            }
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
                            ForEach(post.syndicatedCopies) { copy in
                                Button { openURL(copy.url) } label: { Label("Open on \(copy.service)", systemImage: "arrow.up.right.square") }
                            }
                            if !store.syndicationTargets(for: post).isEmpty {
                                Button { syndicating = post } label: { Label("Syndicate…", systemImage: "paperplane") }
                            }
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
                else if store.syncEnabled == true { ContentUnavailableView("No Posts", systemImage: "square.and.pencil") }
                else {
                    ContentUnavailableView {
                        Label("No Posts", systemImage: "square.and.pencil")
                    } description: {
                        Text("Sync to browse, search and edit your posts here.")
                    } actions: {
                        Button("Sync Posts") { store.setSync(true) }.prominentAction()
                    }
                }
            } else if drafts.isEmpty && posts.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .navigationTitle(store.account?.me.host ?? "Posts")
        .syncStatus(store.syncProgress)
        .searchable(text: $search)
        .refreshable { store.reloadDrafts(); await store.refresh(asking: true) }
        .alert("Sync Your Posts?", isPresented: Binding(get: { store.askingToSync }, set: { store.askingToSync = $0 })) {
            Button("Not Now", role: .cancel) { if store.syncEnabled == nil { store.setSync(false) } }
            Button("Sync") { store.setSync(true) }
        } message: {
            Text("Keep a copy on this iPhone to browse, search and edit your posts.")
        }
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
        .sensoryFeedback(.success, trigger: store.syndicated)
        .sheet(item: $syndicating) { post in SyndicateSheet(post: post) }
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
            Button { store.composeVoiceNote() } label: { Label("Voice Note", systemImage: "mic") }
            Button { askingForURL = true } label: { Label("Edit Post…", systemImage: "pencil.line") }
        } label: {
            Label("New Post", systemImage: "square.and.pencil")
        } primaryAction: {
            store.compose(store.preferences.visibleKinds.first ?? .note)
        }
        .accessibilityIdentifier("compose")
    }
}

extension View {
    /// Sync progress under the title, where it stays put while the list scrolls. A slim bar before iOS 26.
    @ViewBuilder func syncStatus(_ progress: AppStore.SyncProgress?) -> some View {
        if #available(iOS 26.0, *) {
            navigationSubtitle(progress.map(SyncBar.text) ?? "")
        } else {
            safeAreaInset(edge: .top, spacing: 0) {
                if let progress, progress.count > 0 { SyncBar(progress: progress).transition(.opacity) }
            }
            .animation(.snappy, value: progress == nil)
        }
    }
}

/// A slim bar while posts download, so the list stays usable.
private struct SyncBar: View {
    let progress: AppStore.SyncProgress

    static func text(_ progress: AppStore.SyncProgress) -> String {
        if let fraction = progress.fraction { return "Syncing \(fraction.formatted(.percent.precision(.fractionLength(0))))" }
        return progress.count == 0 ? "Syncing" : "Syncing \(progress.count.formatted()) Posts"
    }

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).animation(.snappy, value: fraction)
            } else {
                ProgressView().controlSize(.mini)
                Spacer(minLength: 0)
            }
            Text("\(progress.count) Posts").monospacedDigit().contentTransition(.numericText())
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SyncBar.text(progress))
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

/// Sends a published post to more networks, with one text for all of them or one for each.
private struct SyndicateSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let post: Post
    @State private var chosen: Set<String> = []
    /// One text for every network while linked.
    @State private var linked = true
    @State private var texts: [String: String] = [:]
    @State private var sending = false

    private var targets: [SyndicationTarget] { store.syndicationTargets(for: post) }
    private var picked: [SyndicationTarget] { targets.filter { chosen.contains($0.uid) } }
    /// Chosen targets on networks Quill can write for. Others use the server's own text.
    private struct Destination: Identifiable {
        var target: SyndicationTarget
        var service: SocialService
        var id: String { target.uid }
    }
    private var social: [Destination] { picked.compactMap { t in SocialService(t).map { Destination(target: t, service: $0) } } }
    private var shared: Bool { linked && social.count > 1 }
    private var editors: [Destination] { shared ? Array(social.prefix(1)) : social }
    private var over: Bool { social.contains { SocialText.count(texts[$0.target.uid] ?? "", for: $0.service) > $0.service.limit } }
    private var empty: Bool { social.contains { (texts[$0.target.uid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(post.displayTitle).font(.headline).lineLimit(2)
                    chips
                    ForEach(editors) { editor in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(shared ? social.map { $0.target.name }.joined(separator: " & ") : editor.target.name)
                                Spacer()
                                counts(for: shared ? social : [editor])
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            MentionEditor(text: binding(editor.target.uid), service: editor.service, follows: store.follows.accounts)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Syndicate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { send() }
                        .disabled(sending || picked.isEmpty || over || empty)
                }
                if social.count > 1 {
                    ToolbarItem(placement: .bottomBar) {
                        Button(linked ? "Edit Separately" : "Use One Text", systemImage: linked ? "link" : "link.badge.plus") { toggleLinked() }
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .animation(.snappy, value: chosen)
            .animation(.snappy, value: linked)
        }
        .onAppear(perform: start)
        .task { await store.refreshFollows(for: SocialService.allCases) }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(targets) { target in
                    let isOn = chosen.contains(target.uid)
                    Button {
                        if isOn { chosen.remove(target.uid) } else { chosen.insert(target.uid); fill(target) }
                    } label: {
                        Label(target.name, systemImage: isOn ? "checkmark" : "plus")
                            .font(.subheadline.weight(.medium))
                            .contentTransition(.symbolEffect(.replace))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(isOn ? Color(uiColor: .systemBackground) : Color.primary)
                            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: chosen)
    }

    /// A shared text shows the count of the network it is closest to outgrowing.
    private func counts(for list: [Destination]) -> some View {
        let tightest = list.max { a, b in
            Double(SocialText.count(texts[a.target.uid] ?? "", for: a.service)) / Double(a.service.limit)
                < Double(SocialText.count(texts[b.target.uid] ?? "", for: b.service)) / Double(b.service.limit)
        }
        let count = tightest.map { SocialText.count(texts[$0.target.uid] ?? "", for: $0.service) } ?? 0
        let limit = tightest?.service.limit ?? 0
        return Text("\(count)/\(limit)")
            .monospacedDigit()
            .foregroundStyle(count > limit ? Color.red : Color.secondary)
            .contentTransition(.numericText())
    }

    private func binding(_ uid: String) -> Binding<String> {
        Binding(get: { texts[uid] ?? "" }, set: { value in
            texts[uid] = value
            if shared { for item in social { texts[item.target.uid] = value } }
        })
    }

    /// Every target starts chosen, with the shorter network's text shared by all.
    private func start() {
        guard chosen.isEmpty else { return }
        chosen = Set(targets.map(\.uid))
        let first = targets.compactMap { SocialService($0) }.min { $0.limit < $1.limit } ?? .bluesky
        let text = SocialText.defaultText(title: post.name, text: post.text, url: post.url, service: first)
        for target in targets where SocialService(target) != nil { texts[target.uid] = text }
    }

    private func fill(_ target: SyndicationTarget) {
        guard let service = SocialService(target) else { return }
        if linked, let other = social.first(where: { $0.target.uid != target.uid }) { texts[target.uid] = texts[other.target.uid]; return }
        if (texts[target.uid] ?? "").isEmpty { texts[target.uid] = SocialText.defaultText(title: post.name, text: post.text, url: post.url, service: service) }
    }

    private func toggleLinked() {
        linked.toggle()
        if linked, let first = social.first { for item in social { texts[item.target.uid] = texts[first.target.uid] } }
    }

    private func send() {
        sending = true
        let written = Dictionary(uniqueKeysWithValues: social.map { ($0.target.uid, texts[$0.target.uid] ?? "") })
        Task {
            if await store.syndicate(post, to: picked, texts: written) { dismiss() }
            sending = false
        }
    }
}

/// A text editor that suggests followed accounts while an @mention is typed.
private struct MentionEditor: View {
    @Binding var text: String
    let service: SocialService
    let follows: [FollowedAccount]
    /// Where the cursor is, as an offset, so it survives edits to the text. The end before iOS 18.
    @State private var cursor: Int?
    @State private var request: Int?

    private var mention: (range: Range<String.Index>, query: String)? {
        let offset = min(cursor ?? text.count, text.count)
        return SocialText.mentionQuery(text, cursor: text.index(text.startIndex, offsetBy: offset))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            editor
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.fill.quaternary, in: .rect(cornerRadius: 12))
            if let mention {
                let matches = SocialText.suggestions(mention.query, in: follows, service: service)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(matches, id: \.handle) { account in
                            Button { insert(account, at: mention.range) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(account.name).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
                                    Text("@" + account.handle).font(.caption).foregroundStyle(Color.secondary)
                                }
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                        if matches.isEmpty && !mention.query.isEmpty {
                            Text(follows.contains { $0.service == service } ? "No matches. Type the full handle." : "Type the full handle.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: mention?.query)
    }

    @ViewBuilder private var editor: some View {
        if #available(iOS 18.0, *) {
            SelectingEditor(text: $text, cursor: $cursor, request: $request)
        } else {
            TextEditor(text: $text)
        }
    }

    private func insert(_ account: FollowedAccount, at range: Range<String.Index>) {
        let result = SocialText.insert(account, into: text, replacing: range)
        text = result.text
        cursor = result.cursor
        request = result.cursor
    }
}

@available(iOS 18.0, *)
private struct SelectingEditor: View {
    @Binding var text: String
    @Binding var cursor: Int?
    /// A cursor position to move to, after a mention is inserted.
    @Binding var request: Int?
    @State private var selection: TextSelection?

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .onChange(of: selection) {
                guard case .selection(let range)? = selection?.indices, range.upperBound <= text.endIndex else { cursor = nil; return }
                cursor = text.distance(from: text.startIndex, to: range.upperBound)
            }
            .onChange(of: request) {
                guard let request else { return }
                selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: min(request, text.count)))
                self.request = nil
            }
    }
}
