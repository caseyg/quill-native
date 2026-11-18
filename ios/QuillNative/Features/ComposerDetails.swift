import SwiftUI
import MapKit
import QuillCore

/// Everything about a post that is not its words: tags, timing, visibility, place.
struct ComposerDetails: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: Draft
    @Binding var htmlSource: Bool
    @State private var dated = false
    @State private var loadingLatest = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Tags") {
                    TextField("one, two", text: $draft.tags)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("details.tags")
                }
                LabeledContent("Slug") {
                    TextField("Automatic", text: $draft.slug)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if draft.kind == .reply {
                    Picker("RSVP", selection: field("rsvp")) {
                        Text("None").tag("")
                        Text("Going").tag("yes")
                        Text("Not Going").tag("no")
                        Text("Maybe").tag("maybe")
                        Text("Interested").tag("interested")
                    }
                }
            }
            Section {
                Toggle("Set Date", isOn: $dated.animation(.snappy))
                    .onChange(of: dated) { _, value in draft.setPublicationDateEnabled(value) }
                if dated { ISODateField(title: "Date", value: $draft.published) }
                if draft.editURL == nil { Toggle("Post as Draft", isOn: $draft.remoteDraft) }
                if !store.config.visibility.isEmpty {
                    Picker("Visibility", selection: $draft.visibility) {
                        Text("Default").tag("")
                        ForEach(store.config.visibility, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .onChange(of: draft.visibility) { _, value in
                        if !value.isEmpty && value != "public" { draft.syndication = [] }
                    }
                }
                if !store.config.channels.isEmpty {
                    Picker("Channel", selection: $draft.channel) {
                        Text("Default").tag("")
                        ForEach(store.config.channels, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            if draft.kind.takesLocation {
                Section {
                    LabeledContent("Location") {
                        TextField("None", text: $draft.location)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if let coordinate {
                        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))) {
                            Marker("", coordinate: coordinate)
                        }
                        .frame(height: 160)
                        .listRowInsets(EdgeInsets())
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            }
            if draft.kind.takesPhotos {
                Section {
                    LabeledContent("Photo URL") {
                        TextField("None", text: field("photo-url"))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if store.config.mediaEndpoint != nil {
                        Button { Task { await useLatestUpload() } } label: {
                            HStack {
                                Text("Use Latest Upload")
                                Spacer()
                                if loadingLatest { ProgressView() }
                            }
                        }
                        .disabled(loadingLatest)
                    }
                }
            }
            Section {
                if ContentFormat.supported(by: draft.kind).count > 1 {
                    Picker("Format", selection: $draft.format) {
                        ForEach(ContentFormat.supported(by: draft.kind)) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("details.format")
                }
                if draft.kind == .article && draft.isHTML { Toggle("Edit as HTML", isOn: $htmlSource) }
                NavigationLink("Request") { RequestView(draft: draft, preferences: store.preferences) }
                    .accessibilityIdentifier("details.request")
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear { dated = !draft.published.isEmpty }
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard draft.location.hasPrefix("geo:") else { return nil }
        let parts = draft.location.dropFirst(4).split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        let value = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
        return CLLocationCoordinate2DIsValid(value) ? value : nil
    }

    private func field(_ name: String) -> Binding<String> {
        Binding(get: { draft.fields[name] ?? "" }, set: { draft.fields[name] = $0 })
    }

    private func useLatestUpload() async {
        guard let client = store.client, let media = store.config.mediaEndpoint else { return }
        loadingLatest = true; defer { loadingLatest = false }
        do {
            guard let item = try await client.latestMedia(at: media) else { store.error = "No recent upload found."; return }
            draft.fields["photo-url"] = item.url.absoluteString
            if let published = item.published { draft.published = published; dated = true }
            if let location = item.location { draft.location = location }
        } catch { store.error = error.localizedDescription }
    }
}

/// The exact Micropub request this post will send.
private struct RequestView: View {
    let draft: Draft
    let preferences: Preferences

    var body: some View {
        ScrollView {
            Text(text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("request.body")
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var text: String {
        do {
            let value = try draft.editURL == nil ? Payload.create(draft, preferences: preferences) : Payload.update(draft, preferences: preferences)
            let object = try JSONSerialization.jsonObject(with: value.encoded())
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        } catch {
            return error.localizedDescription
        }
    }
}

/// A date and the time zone it is written in, kept as an ISO 8601 string.
struct ISODateField: View {
    let title: String
    @Binding var value: String
    @State private var zone = TimeZone.current.identifier

    var body: some View {
        Group {
            DatePicker(title, selection: Binding(get: { ISO8601DateFormatter().date(from: value) ?? Date() }, set: { write($0) }))
                .environment(\.timeZone, TimeZone(identifier: zone) ?? .current)
            Picker("Time Zone", selection: $zone) {
                ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + [zone])).sorted(), id: \.self) {
                    Text($0.replacingOccurrences(of: "_", with: " ")).tag($0)
                }
            }
            .pickerStyle(.navigationLink)
        }
        .onAppear {
            if value.isEmpty { value = ISO8601DateFormatter().string(from: Date()) }
            else if value.hasSuffix("Z") { zone = "GMT" }
            else {
                let suffix = String(value.suffix(6))
                if suffix.range(of: #"^[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil { zone = "GMT" + suffix.replacingOccurrences(of: ":", with: "") }
            }
        }
        .onChange(of: zone) { _, _ in
            if let date = ISO8601DateFormatter().date(from: value) { write(date) }
        }
    }

    private func write(_ date: Date) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: zone)
        value = formatter.string(from: date)
    }
}
