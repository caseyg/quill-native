import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
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
    @State private var recordingVoice = false
    @State private var htmlSource = false
    @State private var describing: Attachment?
    @State private var dragging: Attachment.ID?
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
            .sheet(isPresented: $recordingVoice) {
                VoiceNoteSheet { text, audio in insertVoiceNote(text, audio: audio) }
                    .presentationDetents([.medium, .large])
            }
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
            .sheet(item: $describing) { attachment in
                PhotoDescriptionEditor(attachment: attachment) { text in
                    if let index = draft.attachments.firstIndex(where: { $0.id == attachment.id }) { draft.attachments[index].alt = text }
                }
                .presentationDetents([.medium, .large])
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
                if store.startsVoiceNote { store.startsVoiceNote = false; recordingVoice = true }
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
                    let photos = draft.attachments.filter { !$0.isAudio }
                    ForEach(draft.attachments) { attachment in
                        if attachment.isAudio {
                            AudioTile { withAnimation(.snappy) { draft.attachments.removeAll { $0.id == attachment.id } } }
                        } else {
                            let position = photos.firstIndex { $0.id == attachment.id } ?? 0
                            PhotoThumbnail(
                                attachment: attachment,
                                number: position + 1,
                                canMoveBack: position > 0,
                                canMoveForward: position < photos.count - 1,
                                describe: { describing = attachment },
                                move: { step in movePhoto(attachment.id, by: step) },
                                remove: { withAnimation(.snappy) { draft.attachments.removeAll { $0.id == attachment.id } } }
                            )
                            .opacity(dragging == attachment.id ? 0.4 : 1)
                            .onDrag {
                                dragging = attachment.id
                                return NSItemProvider(object: attachment.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: PhotoDropDelegate(target: attachment.id, attachments: $draft.attachments, dragging: $dragging))
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
            if draft.kind.takesVoice {
                barButton("Voice Note", "mic") { focus = nil; recordingVoice = true }
                    .accessibilityIdentifier("voice")
            }
            if canAddPhotos {
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
        Binding(get: { draft.kind }, set: { new in withAnimation(.snappy) { draft.prepare(for: new, preferences: store.preferences) } })
    }

    private var sendTitle: String {
        draft.editURL != nil ? "Update" : (draft.remoteDraft ? "Save Draft" : "Post")
    }

    /// A published post takes new photos only where they are a `photo` property and can be uploaded first.
    private var canAddPhotos: Bool {
        guard draft.kind.takesPhotos else { return false }
        return draft.editURL == nil || (draft.kind.hasPhotoProperty && store.config.mediaEndpoint != nil)
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

    /// Adds a transcript after what is already written, as a paragraph of its own.
    private func insertVoiceNote(_ text: String, audio: Attachment?) {
        withAnimation(.snappy) {
            if !text.isEmpty {
                if draft.isHTML {
                    let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                    draft.content += "<p>\(escaped)</p>"
                } else {
                    let current = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.content = current.isEmpty ? text : current + "\n\n" + text
                }
            }
            if let audio, draft.editURL == nil { draft.attachments.append(audio) }
        }
        focus = .content
    }

    /// Moves a photo past its neighbouring photo, stepping over any voice note between them.
    private func movePhoto(_ id: Attachment.ID, by step: Int) {
        let photoIndices = draft.attachments.indices.filter { !draft.attachments[$0].isAudio }
        guard let position = photoIndices.firstIndex(where: { draft.attachments[$0].id == id }),
              photoIndices.indices.contains(position + step) else { return }
        withAnimation(.snappy) { draft.attachments.swapAt(photoIndices[position], photoIndices[position + step]) }
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
    let number: Int
    let canMoveBack: Bool
    let canMoveForward: Bool
    let describe: () -> Void
    let move: (Int) -> Void
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
        .accessibilityLabel(attachment.alt.isEmpty ? "Photo \(number)" : "Photo \(number): \(attachment.alt)")
        .accessibilityHint("Edits the description")
        .accessibilityIdentifier("photo.\(number)")
        .accessibilityActions {
            if canMoveBack { Button("Move Earlier") { move(-1) } }
            if canMoveForward { Button("Move Later") { move(1) } }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.6), in: Circle())
                    // The tap area stays in the corner, so a tap on the photo opens its description.
                    .frame(width: 38, height: 38, alignment: .topTrailing)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove Photo \(number)")
        }
        .contextMenu {
            Button(action: describe) { Label(attachment.alt.isEmpty ? "Add Description" : "Edit Description", systemImage: "text.below.photo") }
            if canMoveBack { Button { move(-1) } label: { Label("Move Earlier", systemImage: "arrow.left") } }
            if canMoveForward { Button { move(1) } label: { Label("Move Later", systemImage: "arrow.right") } }
            Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
        }
        .animation(.snappy, value: attachment.alt.isEmpty)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .task(id: attachment.id) { image = await attachment.thumbnail(side: 288) }
    }
}

/// Moves the dragged photo into each spot it passes over, so the strip reorders as the finger moves.
private struct PhotoDropDelegate: DropDelegate {
    let target: Attachment.ID
    @Binding var attachments: [Attachment]
    @Binding var dragging: Attachment.ID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = attachments.firstIndex(where: { $0.id == dragging }),
              let to = attachments.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.snappy) { attachments.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropExited(info: DropInfo) {}
}

/// A photo's description, written as a paragraph rather than squeezed into one line.
private struct PhotoDescriptionEditor: View {
    let attachment: Attachment
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var image: UIImage?
    @FocusState private var focused: Bool

    init(attachment: Attachment, save: @escaping (String) -> Void) {
        self.attachment = attachment
        self.save = save
        _text = State(initialValue: attachment.alt)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        Color(uiColor: .tertiarySystemFill)
                        if let image { Image(uiImage: image).resizable().scaledToFit() }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityHidden(true)
                    TextField("Describe what’s in the photo for people who can’t see it.", text: $text, axis: .vertical)
                        .lineLimit(5...)
                        .focused($focused)
                        .padding(12)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
                        .accessibilityLabel("Description")
                        .accessibilityIdentifier("description.text")
                    Text("\(text.count) characters")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("description.save")
                }
            }
        }
        .interactiveDismissDisabled(text != attachment.alt)
        .onAppear { focused = true }
        .task(id: attachment.id) { image = await attachment.thumbnail(side: 900) }
    }
}

extension Attachment {
    /// A small image of the photo, from its bytes or, for a published photo, from its URL.
    func thumbnail(side: CGFloat) async -> UIImage? {
        var data = self.data
        if data.isEmpty, let url = remoteURL {
            guard let (downloaded, _) = try? await URLSession.shared.data(from: url) else { return nil }
            data = downloaded
        }
        let bytes = data
        return await Task.detached {
            guard let image = UIImage(data: bytes), image.size.width > 0, image.size.height > 0 else { return nil }
            let scale = min(1, side / max(image.size.width, image.size.height))
            return image.preparingThumbnail(of: CGSize(width: image.size.width * scale, height: image.size.height * scale))
        }.value
    }
}

extension PostKind {
    var hasTarget: Bool { [.reply, .bookmark, .like, .repost].contains(self) }
    var hasText: Bool { [.note, .photo, .reply, .bookmark].contains(self) }
    var takesPhotos: Bool { [.note, .photo, .reply, .article].contains(self) }
    var takesVoice: Bool { [.note, .photo, .reply, .bookmark, .article].contains(self) }
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
