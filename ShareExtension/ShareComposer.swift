import SwiftUI
import PhotosUI
import QuillCore

/// A full post editor for whatever was shared: link, title, description, note, photos, tags and the site's options.
struct ShareComposer: View {
    @Bindable var model: ShareModel
    @State private var picked: [PhotosPickerItem] = []
    @State private var tagInput = ""
    @State private var describing: Attachment.ID?
    @State private var descriptionText = ""
    @FocusState private var focus: Field?

    private enum Field { case target, title, summary, content, tags, slug }

    var body: some View {
        NavigationStack {
            Form {
                if let failure = model.failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .onTapGesture { withAnimation(.snappy) { model.failure = nil } }
                            .accessibilityIdentifier("share.error")
                    }
                }
                if model.account == nil {
                    Section { Label("Sign in to Quill to publish.", systemImage: "person.crop.circle.badge.exclamationmark").font(.footnote).foregroundStyle(.secondary) }
                }
                if model.loading {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                } else {
                    if model.draft.kind.hasLink { linkSection }
                    if model.draft.kind.hasWords { wordsSection }
                    if model.draft.kind.hasWords { photoSection }
                    tagSection
                    detailSection
                    if showsSyndication { syndicationSection }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(model.draft.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Picker("Post Type", selection: kind) {
                    ForEach(ShareModel.kinds) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: model.cancel)
                        .accessibilityIdentifier("share.close")
                }
                if focus != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { focus = nil }
                    }
                }
            }
            // The actions step aside while typing, so they never sit over the field being edited.
            .safeAreaInset(edge: .bottom, spacing: 0) { if focus == nil { actions.transition(.opacity) } }
            .animation(.snappy, value: focus == nil)
        }
        .disabled(model.busy != nil || model.outcome != nil)
        .animation(.snappy, value: model.draft.kind)
        .animation(.snappy, value: model.failure)
        .animation(.snappy, value: model.link)
        .animation(.snappy, value: model.config.channels)
        .animation(.snappy, value: model.draft.attachments.count)
        .onChange(of: picked) { _, items in Task { await importPhotos(items) } }
        .task(id: model.draft.target) {
            guard !model.loading else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { await model.lookUp() }
        }
        .alert("Description", isPresented: Binding(get: { describing != nil }, set: { if !$0 { describing = nil } })) {
            TextField("Description", text: $descriptionText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let index = model.draft.attachments.firstIndex(where: { $0.id == describing }) { model.draft.attachments[index].alt = descriptionText }
            }
        }
        .sensoryFeedback(.error, trigger: model.failures)
        .sensoryFeedback(.selection, trigger: model.draft.kind)
        .sensoryFeedback(.success, trigger: model.outcome) { _, new in new != nil }
    }

    // MARK: Sections

    private var linkSection: some View {
        Section {
            if let image = model.linkImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .clipped()
                    .listRowInsets(EdgeInsets())
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                Image(systemName: model.draft.kind.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("URL", text: $model.draft.target)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.secondary)
                    .focused($focus, equals: .target)
                    .accessibilityIdentifier("share.target")
            }
            if model.draft.kind == .reply {
                Picker("RSVP", selection: field("rsvp")) {
                    Text("None").tag("")
                    Text("Going").tag("yes")
                    Text("Not Going").tag("no")
                    Text("Maybe").tag("maybe")
                    Text("Interested").tag("interested")
                }
            }
        }
    }

    @ViewBuilder private var wordsSection: some View {
        if model.draft.kind == .bookmark {
            Section {
                TextField("Title", text: $model.draft.title, axis: .vertical)
                    .font(.headline)
                    .focused($focus, equals: .title)
                    .accessibilityIdentifier("share.title")
                TextField("Description", text: field("summary"), axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focus, equals: .summary)
                    .accessibilityIdentifier("share.summary")
            }
        }
        Section {
            TextField(prompt, text: $model.draft.content, axis: .vertical)
                .lineLimit(3...12)
                .focused($focus, equals: .content)
                .accessibilityIdentifier("share.content")
        }
    }

    private var photoSection: some View {
        Section {
            if !model.draft.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(model.draft.attachments) { attachment in thumbnail(attachment) }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            if model.draft.kind == .bookmark, let image = model.link?.image {
                Toggle("Include Preview Image", isOn: Binding(
                    get: { model.draft.fields["photo-url"] == image.absoluteString },
                    set: { model.draft.fields["photo-url"] = $0 ? image.absoluteString : "" }
                ))
            }
            PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) {
                Label("Add Photos", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("share.photos")
        }
    }

    /// One row that never changes shape, so adding a tag never takes focus away from the field.
    private var tagSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if !model.tags.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(model.tags, id: \.self) { tag in
                            Button { withAnimation(.snappy) { model.removeTag(tag) } } label: {
                                HStack(spacing: 4) {
                                    Text(tag)
                                    Image(systemName: "xmark").font(.caption2.bold()).foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.fill.tertiary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(tag)")
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                }
                TextField("Add Tags", text: $tagInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .tags)
                    .onSubmit { commitTag(tagInput) }
                    .onChange(of: tagInput) { _, value in
                        // Typing a comma finishes a tag; whatever follows it keeps being typed.
                        guard let comma = value.lastIndex(of: ",") else { return }
                        withAnimation(.snappy) { model.addTag(String(value[..<comma])) }
                        tagInput = String(value[value.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                    }
                    .accessibilityIdentifier("share.tags")
                let suggestions = model.suggestions(for: tagInput)
                if !suggestions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { tag in
                                Button { commitTag(tag) } label: {
                                    Label(tag, systemImage: "plus")
                                        .font(.subheadline)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(.fill.quaternary, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Tags")
        }
    }

    private var detailSection: some View {
        Section {
            if !model.config.channels.isEmpty {
                Picker("Channel", selection: $model.draft.channel) {
                    Text("Default").tag("")
                    ForEach(model.config.channels, id: \.self) { Text($0).tag($0) }
                }
            }
            if !model.config.visibility.isEmpty {
                Picker("Visibility", selection: $model.draft.visibility) {
                    Text("Default").tag("")
                    ForEach(model.config.visibility, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .onChange(of: model.draft.visibility) { _, value in
                    if !value.isEmpty && value != "public" { model.draft.syndication = [] }
                }
            }
            LabeledContent("Slug") {
                TextField("Automatic", text: $model.draft.slug)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .slug)
            }
            Toggle("Set Date", isOn: Binding(
                get: { !model.draft.published.isEmpty },
                set: { value in withAnimation(.snappy) { model.draft.setPublicationDateEnabled(value) } }
            ))
            if !model.draft.published.isEmpty {
                DatePicker("Date", selection: published)
            }
        }
    }

    private var syndicationSection: some View {
        Section("Syndication") {
            ForEach(model.config.targets) { target in
                Toggle(target.name, isOn: Binding(get: { model.draft.syndication.contains(target.uid) }, set: { isOn in
                    model.draft.syndication.removeAll { $0 == target.uid }
                    if isOn { model.draft.syndication.append(target.uid) }
                }))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { Task { await model.save() } } label: {
                actionLabel("Save Draft", systemImage: "tray.and.arrow.down", for: .saved)
            }
            .secondaryAction()
            .accessibilityIdentifier("share.save")
            Button { focus = nil; Task { await model.publish() } } label: {
                actionLabel("Publish", systemImage: "arrow.up", for: .published)
            }
            .prominentAction()
            .disabled(!model.canPublish)
            .accessibilityIdentifier("share.publish")
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .disabled(model.loading)
    }

    private func actionLabel(_ title: String, systemImage: String, for outcome: ShareModel.Outcome) -> some View {
        ZStack {
            Label(title, systemImage: systemImage).opacity(model.busy == outcome || model.outcome == outcome ? 0 : 1)
            if model.outcome == outcome { Image(systemName: "checkmark").transition(.scale.combined(with: .opacity)) }
            else if model.busy == outcome { ProgressView() }
        }
        .fontWeight(.semibold)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: model.busy)
        .animation(.snappy, value: model.outcome)
    }

    private func thumbnail(_ attachment: Attachment) -> some View {
        Button {
            descriptionText = attachment.alt
            describing = attachment.id
        } label: {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                if let image = model.thumbnails[attachment.id] { Image(uiImage: image).resizable().scaledToFill() }
            }
            .frame(width: 88, height: 88)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .bottomLeading) {
                if !attachment.alt.isEmpty {
                    Text("ALT")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: .rect(cornerRadius: 5))
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attachment.alt.isEmpty ? "Photo" : attachment.alt)
        .accessibilityHint("Edits the description")
        .overlay(alignment: .topTrailing) {
            Button { withAnimation(.snappy) { model.remove(attachment) } } label: {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.6), in: Circle())
                    .padding(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove Photo")
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    // MARK: State

    private var kind: Binding<PostKind> {
        Binding(get: { model.draft.kind }, set: { new in withAnimation(.snappy) { model.setKind(new) } })
    }

    private var prompt: String {
        switch model.draft.kind {
        case .photo: return "Caption"
        case .reply: return "Reply"
        default: return "Note"
        }
    }

    private var showsSyndication: Bool {
        !model.config.targets.isEmpty && (model.draft.visibility.isEmpty || model.draft.visibility == "public")
    }

    private var published: Binding<Date> {
        Binding(get: { ISO8601DateFormatter().date(from: model.draft.published) ?? Date() }, set: { date in
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            model.draft.published = formatter.string(from: date)
        })
    }

    private func field(_ name: String) -> Binding<String> {
        Binding(get: { model.draft.fields[name] ?? "" }, set: { model.draft.fields[name] = $0 })
    }

    private func commitTag(_ value: String) {
        withAnimation(.snappy) { model.addTag(value) }
        tagInput = ""
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        defer { picked = [] }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { model.fail("A photo couldn’t be read."); continue }
            withAnimation(.snappy) { model.addPhoto(data) }
        }
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
