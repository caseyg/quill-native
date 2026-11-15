import SwiftUI
import PhotosUI
import QuillCore

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft
    @State private var saved: Draft?
    @State private var appeared = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var location = LocationService()
    @State private var rich = RichTextController()
    @State private var sending = false
    @State private var finished = false
    @State private var importing = false
    @State private var failure: String?
    @State private var failures = 0
    @State private var link: LinkContext?
    @State private var showDetails = false
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var htmlSource = false
    @State private var describing: Attachment.ID?
    @State private var descriptionText = ""
    @State private var addingLink = false
    @State private var linkText = ""
    @FocusState private var focus: Field?

    private enum Field { case target, title, content }

    var body: some View {
        content
            .disabled(sending)
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .navigationTitle(draft.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                if draft.editURL == nil {
                    Picker("Post Type", selection: kind) {
                        ForEach(store.preferences.visibleKinds.contains(draft.kind) ? store.preferences.visibleKinds : PostKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .disabled(sending)
                        .accessibilityIdentifier("close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await send() } } label: {
                        if sending { ProgressView() } else { Label(sendTitle, systemImage: "arrow.up").fontWeight(.semibold) }
                    }
                    .disabled(draft.isBlank || sending || importing)
                    .accessibilityIdentifier("publish")
                }
            }
            .interactiveDismissDisabled(sending)
            .photosPicker(isPresented: $showPhotos, selection: $picked, maxSelectionCount: 10, matching: .images)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in
                    if let data { attach(data, name: "camera") }
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showDetails) {
                NavigationStack { ComposerDetails(draft: $draft, htmlSource: $htmlSource) }
                    .environment(store)
                    .presentationDetents([.medium, .large])
            }
            .alert("Description", isPresented: Binding(get: { describing != nil }, set: { if !$0 { describing = nil } })) {
                TextField("Description", text: $descriptionText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let index = draft.attachments.firstIndex(where: { $0.id == describing }) { draft.attachments[index].alt = descriptionText }
                }
            }
            .alert("Link", isPresented: $addingLink) {
                TextField("URL", text: $linkText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Add") { if let url = try? WebURL.site(linkText) { rich.link(url) } }
            }
            .task(id: draft) {
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { persist() }
            }
            .task(id: draft.target) { await lookUpLink() }
            .onChange(of: picked) { _, items in Task { await importPhotos(items) } }
            .onChange(of: location.coordinate?.latitude) { _, _ in
                if let c = location.coordinate { withAnimation(.snappy) { draft.location = "geo:\(c.latitude),\(c.longitude)" } }
            }
            .onChange(of: location.error) { _, message in if let message { fail(message) } }
            .onAppear {
                guard !appeared else { return }
                appeared = true
                // A post just fetched for editing is only kept as a draft once it changes.
                saved = store.drafts.first { $0.id == draft.id } ?? (draft.editURL != nil ? draft : nil)
                // Existing HTML opens as source, so formatting the editor can't show is kept.
                if draft.editURL != nil && draft.isHTML && saved == draft { htmlSource = true }
                focus = draft.kind.hasTarget && draft.target.isEmpty ? .target : .content
            }
            .onDisappear(perform: persist)
            .sensoryFeedback(.error, trigger: failures)
            .sensoryFeedback(.selection, trigger: draft.kind)
            .sensoryFeedback(.selection, trigger: draft.syndication)
            .sensoryFeedback(.impact(weight: .light), trigger: draft.attachments.count)
    }

    // MARK: Layout

    @ViewBuilder private var content: some View {
        switch draft.kind {
        case .event, .review, .itinerary, .weight, .exercise:
            Form {
                if failure != nil { Section { failureBanner.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) } }
                StructuredFields(draft: $draft, weightUnit: store.preferences.weightUnit)
                if showsSyndication {
                    Section("Syndication") {
                        ForEach(store.config.targets) { target in Toggle(target.name, isOn: syndicates(target)) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        case .article, .code:
            VStack(alignment: .leading, spacing: 0) {
                failureBanner.padding(.horizontal, 20).padding(.top, 12)
                TextField(draft.kind == .code ? "Filename" : "Title", text: $draft.title, axis: .vertical)
                    .font(.title2.bold())
                    .focused($focus, equals: .title)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .accessibilityIdentifier("composer.title")
                if draft.kind == .code {
                    TextField("Language", text: field("language"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                }
                if draft.kind == .article && draft.isHTML && !htmlSource {
                    RichEditor(html: $draft.content, controller: rich)
                } else {
                    TextEditor(text: $draft.content)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 15)
                        .padding(.top, 4)
                        .focused($focus, equals: .content)
                        .accessibilityLabel(draft.kind == .code ? "Code" : (draft.isHTML ? "HTML" : (draft.fields["p3k-content-type"] == "text/markdown" ? "Markdown" : "Text")))
                        .accessibilityIdentifier("composer.content")
                }
                photoStrip.padding(.horizontal, 20).padding(.vertical, 8)
            }
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    failureBanner
                    if draft.kind.hasTarget { targetField }
                    if draft.kind == .bookmark {
                        TextField("Title", text: $draft.title, axis: .vertical)
                            .font(.title3.weight(.semibold))
                            .focused($focus, equals: .title)
                    }
                    if draft.kind.hasText {
                        TextField(draft.kind.prompt, text: $draft.content, axis: .vertical)
                            .lineLimit(3...)
                            .focused($focus, equals: .content)
                            .accessibilityIdentifier("composer.content")
                    }
                    photoStrip
                    chips
                    if showsSyndication { syndicationChips }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                Color.clear.contentShape(Rectangle()).onTapGesture { focus = draft.kind.hasText ? .content : .target }
            }
        }
    }

    @ViewBuilder private var failureBanner: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.red.opacity(0.1), in: .rect(cornerRadius: 12))
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { withAnimation(.snappy) { self.failure = nil } }
                .accessibilityIdentifier("composer.error")
        }
    }

    private var targetField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: draft.kind.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("URL", text: $draft.target)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .target)
                    .accessibilityIdentifier("composer.target")
                if draft.target.isEmpty {
                    PasteButton(payloadType: String.self) { values in
                        draft.target = values.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(.fill.tertiary, in: .rect(cornerRadius: 14))
            .animation(.snappy, value: draft.target.isEmpty)
            if let link {
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    if !link.description.isEmpty { Text(link.description).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: 14))
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var photoStrip: some View {
        if !draft.attachments.isEmpty || importing {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(draft.attachments) { attachment in
                        PhotoThumbnail(attachment: attachment) {
                            descriptionText = attachment.alt
                            describing = attachment.id
                        } remove: {
                            withAnimation(.snappy) { draft.attachments.removeAll { $0.id == attachment.id } }
                        }
                    }
                    if importing { ProgressView().frame(width: 96, height: 96) }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    /// What has been set in Details, at a glance.
    @ViewBuilder private var chips: some View {
        let items = summary
        if !items.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.text) { item in
                        Button { showDetails = true } label: {
                            Label(item.text, systemImage: item.symbol)
                                .font(.footnote)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.fill.tertiary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private var syndicationChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(store.config.targets) { target in
                    let isOn = draft.syndication.contains(target.uid)
                    Button { withAnimation(.snappy(duration: 0.2)) { syndicates(target).wrappedValue.toggle() } } label: {
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
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            if draft.kind == .article && draft.isHTML && !htmlSource {
                barButton("Bold", "bold") { rich.bold() }
                barButton("Italic", "italic") { rich.italic() }
                barButton("Heading", "textformat.size") { rich.heading() }
                barButton("Link", "link") { linkText = ""; addingLink = true }
            }
            if draft.kind.takesPhotos && draft.editURL == nil {
                barButton("Photo Library", "photo.on.rectangle") { showPhotos = true }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    barButton("Take Photo", "camera") { showCamera = true }
                }
            }
            if draft.kind.takesLocation && draft.editURL == nil {
                Button(action: toggleLocation) {
                    ZStack {
                        if location.loading { ProgressView() }
                        else { Image(systemName: draft.location.isEmpty ? "location" : "location.fill").contentTransition(.symbolEffect(.replace)) }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(draft.location.isEmpty ? "Add Location" : "Remove Location")
            }
            barButton("Details", "ellipsis") { showDetails = true }.accessibilityIdentifier("details")
        }
        .font(.body.weight(.medium))
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .floatingBar()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .disabled(sending)
        .animation(.snappy, value: draft.kind)
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }

    // MARK: State

    private var kind: Binding<PostKind> {
        Binding(get: { draft.kind }, set: { new in withAnimation(.snappy) { draft.prepare(for: new, markdown: store.preferences.markdown) } })
    }

    private var sendTitle: String {
        draft.editURL != nil ? "Update" : (draft.remoteDraft ? "Save Draft" : "Post")
    }

    private var showsSyndication: Bool {
        // Updates change text only, so syndication is offered when posting.
        draft.editURL == nil && !store.config.targets.isEmpty && (draft.visibility.isEmpty || draft.visibility == "public")
    }

    private var summary: [(symbol: String, text: String)] {
        var items: [(String, String)] = []
        if !draft.location.isEmpty { items.append(("location.fill", draft.location.hasPrefix("geo:") ? "Current Location" : draft.location)) }
        if !draft.tags.isEmpty { items.append(("number", draft.tags)) }
        if let date = ISO8601DateFormatter().date(from: draft.published) { items.append(("calendar", date.formatted(date: .abbreviated, time: .shortened))) }
        if draft.remoteDraft { items.append(("doc", "Draft")) }
        if let rsvp = draft.fields["rsvp"], !rsvp.isEmpty { items.append(("checkmark.circle", "RSVP \(rsvp.capitalized)")) }
        if !draft.visibility.isEmpty && draft.visibility != "public" { items.append(("eye.slash", draft.visibility.capitalized)) }
        return items.map { (symbol: $0.0, text: $0.1) }
    }

    private func field(_ name: String) -> Binding<String> {
        Binding(get: { draft.fields[name] ?? "" }, set: { draft.fields[name] = $0 })
    }

    private func syndicates(_ target: SyndicationTarget) -> Binding<Bool> {
        Binding(get: { draft.syndication.contains(target.uid) }, set: { isOn in
            draft.syndication.removeAll { $0 == target.uid }
            if isOn { draft.syndication.append(target.uid) }
        })
    }

    private func fail(_ message: String) {
        withAnimation(.snappy) { failure = message }
        failures += 1
    }

    // MARK: Actions

    /// Keeps the draft on this device, or clears it away when there is nothing in it.
    private func persist() {
        guard !finished, draft != saved else { return }
        if draft.isBlank {
            if store.drafts.contains(where: { $0.id == draft.id }) { store.remove(draft) }
        } else {
            do { try store.save(draft) } catch { fail(error.localizedDescription) }
        }
        saved = draft
    }

    private func send() async {
        focus = nil
        do { try Payload.validate(draft) } catch { return fail(error.localizedDescription) }
        withAnimation(.snappy) { failure = nil }
        sending = true; defer { sending = false }
        do {
            try await store.publish(draft)
            finished = true
            dismiss()
        } catch {
            if let latest = store.drafts.first(where: { $0.id == draft.id }) { draft = latest; saved = latest }
            fail(error.localizedDescription)
        }
    }

    private func attach(_ data: Data, name: String) {
        let attachment = Attachment(data: data, filename: "\(name)-\(UUID().uuidString.prefix(8)).jpg", mimeType: "image/jpeg")
        withAnimation(.snappy) { draft.attachments.append(attachment) }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        withAnimation(.snappy) { importing = true }
        defer { withAnimation(.snappy) { importing = false }; picked = [] }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
                fail("A photo couldn’t be read.")
                continue
            }
            attach(jpeg, name: "photo")
        }
    }

    private func toggleLocation() {
        if draft.location.isEmpty {
            location.request()
        } else {
            location.coordinate = nil
            withAnimation(.snappy) { draft.location = "" }
        }
    }

    private func lookUpLink() async {
        guard draft.kind.hasTarget, let url = try? WebURL.parse(draft.target) else {
            withAnimation(.snappy) { link = nil }
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let found = try? await LinkContext.fetch(url), !Task.isCancelled else { return }
        withAnimation(.snappy) { link = found }
        if draft.kind == .bookmark && draft.title.isEmpty { draft.title = found.title }
    }
}

private struct PhotoThumbnail: View {
    let attachment: Attachment
    let describe: () -> Void
    let remove: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: describe) {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .frame(width: 96, height: 96)
            .clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .bottomLeading) {
                if !attachment.alt.isEmpty {
                    Text("ALT")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: .rect(cornerRadius: 5))
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attachment.alt.isEmpty ? "Photo" : attachment.alt)
        .accessibilityHint("Edits the description")
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.6), in: Circle())
                    .frame(width: 40, height: 40, alignment: .topTrailing)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove Photo")
        }
        .contextMenu {
            Button(action: describe) { Label("Description", systemImage: "text.below.photo") }
            Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
        }
        .animation(.snappy, value: attachment.alt.isEmpty)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .task(id: attachment.id) {
            let data = attachment.data
            image = await Task.detached { UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 288, height: 288)) }.value
        }
    }
}

extension PostKind {
    var hasTarget: Bool { [.reply, .bookmark, .like, .repost].contains(self) }
    var hasText: Bool { [.note, .photo, .reply, .bookmark].contains(self) }
    var takesPhotos: Bool { [.note, .photo, .reply, .article].contains(self) }
    var takesLocation: Bool { ![.like, .repost, .weight, .exercise, .itinerary].contains(self) }
    var prompt: String {
        switch self {
        case .photo: return "Caption"
        case .reply: return "Reply"
        case .bookmark: return "Comment"
        default: return "Note"
        }
    }
}
