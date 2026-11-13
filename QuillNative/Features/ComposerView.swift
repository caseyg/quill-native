import SwiftUI
import PhotosUI
import MapKit
import QuillCore

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft
    @State private var photos: [PhotosPickerItem] = []
    @State private var location = LocationService()
    @State private var sending = false
    @State private var importing = false
    @State private var message: String?
    @State private var confirmSend = false
    @State private var showPreview = false
    @State private var showCamera = false
    @State private var scheduled = false
    @State private var richMode = true
    @State private var context: LinkContext?
    @State private var lookupBusy = false
    @State private var saved = false
    var body: some View {
        Form {
            Section {
                Label(draft.kind.subtitle,systemImage:draft.kind.symbol).font(.subheadline).foregroundStyle(.secondary)
                if let account = draft.accountURL { Text("For \(account.host ?? account.absoluteString)").font(.caption).foregroundStyle(.secondary) }
            }.listRowBackground(Color.clear)
            mainFields
            if [.note,.photo,.reply,.article].contains(draft.kind) { attachmentFields }
            if ![.like,.repost,.weight,.exercise,.itinerary].contains(draft.kind) { locationFields }
            options
            if let message { Section { Label(message,systemImage:"exclamationmark.circle").font(.footnote).foregroundStyle(.red).textSelection(.enabled) } }
            Section {
                Button { do { try Payload.validate(draft); confirmSend = true } catch { message = error.localizedDescription } } label: {
                    HStack { Spacer(); if sending { ProgressView().padding(.trailing,6) }; Text(draft.editURL != nil ? "Update post" : (draft.remoteDraft ? "Send draft to site" : "Publish to your site")).fontWeight(.semibold); Spacer() }
                }.disabled(sending || importing).accessibilityIdentifier("publish")
            } footer: { Text(store.account == nil ? "You can write and save drafts now. Connect your website in Settings to publish." : "Posts are sent directly to your site. Your site controls visibility, scheduling, and syndication.") }
        }
        .navigationTitle(draft.kind.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.cancellationAction) { Button("Save & close") { saveAndClose() }.disabled(sending).accessibilityIdentifier("save.close") }
            ToolbarItem(placement:.primaryAction) { Button { showPreview = true } label: { Image(systemName:"eye") }.accessibilityLabel("Preview") }
        }
        .interactiveDismissDisabled(sending)
        .disabled(sending)
        .onChange(of:draft) { _,value in
            do { try store.save(value); saved = true } catch { message = "Could not save your draft: " + error.localizedDescription }
        }
        .onChange(of:photos) { _,items in Task { await importPhotos(items) } }
        .onChange(of:location.coordinate?.latitude) { _,_ in
            if let c = location.coordinate { draft.location = "geo:\(c.latitude),\(c.longitude)" }
        }
        .confirmationDialog(draft.editURL == nil ? "Send this post to your site?" : "Update this post on your site?",isPresented:$confirmSend,titleVisibility:.visible) {
            Button(draft.remoteDraft ? "Send remote draft" : "Send to site") { Task { await send() } }
        } message: { Text(draft.remoteDraft ? "This requests a remote draft. Your server must support post-status=draft." : "\(store.account?.me.host ?? "Your website") will receive this post\(scheduled ? " with your chosen publication time" : "").") }
        .sheet(isPresented:$showPreview) { NavigationStack { PostPreview(draft:draft).toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { showPreview = false } } } } }
        .sheet(isPresented:$showCamera) { CameraPicker { data in if let data { draft.attachments.append(Attachment(data:data,filename:"camera.jpg",mimeType:"image/jpeg")) }; showCamera = false } }
        .onAppear { scheduled = !draft.published.isEmpty; if draft.kind == .article { draft.isHTML = true } }
    }
    @ViewBuilder private var mainFields: some View {
        switch draft.kind {
        case .like, .repost: targetFields
        case .bookmark:
            targetFields
            Section("Bookmark") { TextField("Title",text:$draft.title); TextField("Why save this?",text:$draft.content,axis:.vertical).lineLimit(3...8) }
        case .reply:
            targetFields
            Section("Your reply") { contentEditor; Picker("RSVP",selection:field("rsvp")) { Text("No RSVP").tag(""); Text("Going").tag("yes"); Text("Not going").tag("no"); Text("Maybe").tag("maybe"); Text("Interested").tag("interested") } }
        case .article:
            Section("Your story") {
                TextField("Title",text:$draft.title).font(.system(.title2,design:.serif))
                Toggle("Rich text editor",isOn:$richMode)
                if richMode { RichEditor(html:$draft.content).frame(minHeight:300) }
                else { TextEditor(text:$draft.content).font(.system(.body,design:.monospaced)).frame(minHeight:280).accessibilityLabel("Article HTML") }
            }
        case .event: eventFields
        case .review:
            Section("What are you reviewing?") { TextField("Item name",text:field("item-name")); TextField("Item URL",text:field("item-url")).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled(); Picker("Rating",selection:field("rating")) { ForEach(1...5,id:\.self) { Text(String(repeating:"★",count:$0)).tag(String($0)) } } }
            Section("Your review") { TextField("Summary",text:field("summary")); contentEditor; Toggle("Content is HTML",isOn:$draft.isHTML) }
        case .itinerary:
            ForEach($draft.legs) { $leg in LegEditor(leg:$leg) }
            Section { Button("Add travel leg",systemImage:"plus") { draft.legs.append(Leg()) }; if draft.legs.count > 1 { Button("Remove last leg",role:.destructive) { draft.legs.removeLast() } } }
        case .code:
            Section("Code snippet") { TextField("Title or filename",text:$draft.title); TextField("Language (swift, php, javascript…)",text:field("language")).textInputAutocapitalization(.never).autocorrectionDisabled(); TextEditor(text:$draft.content).font(.system(.body,design:.monospaced)).frame(minHeight:250).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("Code") }
        case .weight:
            Section("Measurement") { TextField("Weight in \(store.preferences.weightUnit)",text:field("weight")).keyboardType(.decimalPad); Text("Change your preferred unit in Settings.").font(.caption).foregroundStyle(.secondary) }
        case .exercise:
            Section("Workout") { TextField("Activity (running, cycling…)",text:field("activity")); TextField("Duration in minutes",text:field("minutes")).keyboardType(.decimalPad); TextField("Heart rate in bpm (optional)",text:field("heartrate")).keyboardType(.decimalPad) }
        default: Section("Your words") { contentEditor }
        }
    }
    private var contentEditor: some View { TextField(draft.kind == .photo ? "Caption" : "Write something…",text:$draft.content,axis:.vertical).lineLimit(6...18).accessibilityIdentifier("composer.content") }
    private var targetFields: some View {
        Section(draft.kind == .reply ? "Reply to" : "Link") {
            TextField("https://…",text:$draft.target).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("composer.target")
            Button { Task { await loadContext() } } label: { HStack { Text("Look up link"); if lookupBusy { Spacer(); ProgressView() } } }.disabled(lookupBusy || draft.target.isEmpty)
            if let context { VStack(alignment:.leading,spacing:6) { Text(context.title).font(.headline); if !context.description.isEmpty { Text(context.description).font(.caption).foregroundStyle(.secondary) } } }
        }
    }
    private var attachmentFields: some View {
        Section("Photos") {
            ForEach($draft.attachments) { $attachment in
                HStack(alignment:.top) {
                    if let image = UIImage(data:attachment.data) { Image(uiImage:image).resizable().scaledToFill().frame(width:64,height:64).clipShape(RoundedRectangle(cornerRadius:8)).accessibilityHidden(true) }
                    VStack(alignment:.leading) { Text(attachment.filename).font(.caption).lineLimit(1); TextField("Describe this photo",text:$attachment.alt,axis:.vertical).font(.subheadline) }
                    Button(role:.destructive) { draft.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName:"xmark.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove photo")
                }
            }
            if store.config.mediaEndpoint != nil {
                Button("Use latest uploaded photo",systemImage:"clock.arrow.circlepath") { Task { await latestPhoto() } }
            }
            PhotosPicker(selection:$photos,maxSelectionCount:10,matching:.images) { Label(importing ? "Importing…" : "Choose photos",systemImage:"photo.on.rectangle") }.disabled(importing)
            if UIImagePickerController.isSourceTypeAvailable(.camera) { Button("Take a photo",systemImage:"camera") { showCamera = true } }
            TextField("Or a photo URL (https://…)",text:field("photo-url")).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
    private var eventFields: some View {
        Group {
            Section("Event") {
                TextField("Event name",text:$draft.title)
                ISODateField(title:"Starts",value:field("start"))
                Toggle("Include end time",isOn:Binding(get:{!(draft.fields["end"] ?? "").isEmpty},set:{ draft.fields["end"] = $0 ? ISO8601DateFormatter().string(from:Date().addingTimeInterval(3600)) : "" }))
                if !(draft.fields["end"] ?? "").isEmpty { ISODateField(title:"Ends",value:field("end")) }
                contentEditor
                Picker("Content format",selection:field("p3k-content-type")) { Text("Plain text").tag(""); Text("Markdown").tag("text/markdown") }
            }
            Section { DisclosureGroup("Place details") {
                TextField("Place name",text:field("place-name")); TextField("Street address",text:field("place-street-address")); TextField("City",text:field("place-locality")); TextField("Region",text:field("place-region")); TextField("Country",text:field("place-country-name")); TextField("Place website",text:field("place-url")).keyboardType(.URL)
            }; DisclosureGroup("Presentation & conference") {
                TextField("Slides URL",text:field("slides")).keyboardType(.URL); TextField("Slides embed HTML",text:field("slides-embed"),axis:.vertical); TextField("Video URL",text:field("video-link")).keyboardType(.URL); TextField("Video embed HTML",text:field("video-embed"),axis:.vertical); TextField("Conference name",text:field("conference-name")); TextField("Conference URL",text:field("conference-url")).keyboardType(.URL)
            } }
        }
    }
    private var locationFields: some View {
        Section {
            DisclosureGroup("Location") {
                TextField("Place, URL, or geo:latitude,longitude",text:$draft.location).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button { location.request() } label: { HStack { Label("Use current location",systemImage:"location"); if location.loading { Spacer(); ProgressView() } } }.disabled(location.loading)
                if let error = location.error { Text(error).font(.caption).foregroundStyle(.red) }
                if let c = location.coordinate { Map(initialPosition:.region(MKCoordinateRegion(center:c,span:MKCoordinateSpan(latitudeDelta:0.02,longitudeDelta:0.02)))) { Marker("Post location",coordinate:c) }.frame(height:160).clipShape(RoundedRectangle(cornerRadius:12)) }
            }
        }
    }
    private var options: some View {
        Section("Post options") {
            TextField("Tags, separated by commas",text:$draft.tags).accessibilityLabel("Tags")
            DisclosureGroup("Publishing details") {
                TextField("URL slug (optional)",text:$draft.slug).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Send as remote draft",isOn:$draft.remoteDraft)
                Toggle("Set publication date",isOn:$scheduled).onChange(of:scheduled) { _,value in draft.setPublicationDateEnabled(value) }
                if scheduled { ISODateField(title:"Publish date",value:$draft.published); Text("Future dates request scheduling on your site. The site must support it.").font(.caption).foregroundStyle(.secondary) }
                if !store.config.visibility.isEmpty { Picker("Visibility",selection:$draft.visibility) { Text("Site default").tag(""); ForEach(store.config.visibility,id:\.self) { Text($0.capitalized).tag($0) } }.onChange(of:draft.visibility) { _,value in if !value.isEmpty && value != "public" { draft.syndication = [] } } }
                if !store.config.channels.isEmpty { Picker("Channel",selection:$draft.channel) { Text("Site default").tag(""); ForEach(store.config.channels,id:\.self) { Text($0).tag($0) } } }
            }
            if !store.config.targets.isEmpty && (draft.visibility.isEmpty || draft.visibility == "public") {
                DisclosureGroup("Syndication") { ForEach(store.config.targets) { target in Toggle(target.name,isOn:Binding(get:{draft.syndication.contains(target.uid)},set:{ if $0 { if !draft.syndication.contains(target.uid) { draft.syndication.append(target.uid) } } else { draft.syndication.removeAll { $0 == target.uid } } })) } }
            }
        }
    }
    private func field(_ name: String) -> Binding<String> { Binding(get:{draft.fields[name] ?? ""},set:{draft.fields[name] = $0}) }
    private func saveAndClose() { do { try store.save(draft); dismiss() } catch { message = "Your draft could not be saved. " + error.localizedDescription } }
    private func send() async { sending = true; message = nil; defer { sending = false }; do { try await store.publish(draft); dismiss() } catch { message = error.localizedDescription; if let latest = store.drafts.first(where:{$0.id == draft.id}) { draft = latest } } }
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        importing = true; defer { importing = false; photos = [] }
        do {
            for item in items {
                guard let data = try await item.loadTransferable(type:Data.self), let image = UIImage(data:data), let normalized = image.jpegData(compressionQuality:0.9) else { throw QuillError("This photo could not be read.") }
                let attachment = Attachment(data:normalized,filename:"photo-\(UUID().uuidString.prefix(8)).jpg",mimeType:"image/jpeg")
                draft.attachments.append(attachment)
            }
        } catch { message = error.localizedDescription }
    }
    private func latestPhoto() async {
        guard let client = store.client, let media = store.config.mediaEndpoint else { return }
        do {
            guard let item = try await client.latestMedia(at:media) else { message = "No recent uploaded photo was found."; return }
            draft.fields["photo-url"] = item.url.absoluteString
            if let published = item.published { draft.published = published; scheduled = true }
            if let location = item.location { draft.location = location }
        } catch { message = error.localizedDescription }
    }
    private func loadContext() async {
        lookupBusy = true; defer { lookupBusy = false }
        do { context = try await LinkContext.fetch(WebURL.parse(draft.target)); if draft.kind == .bookmark && draft.title.isEmpty { draft.title = context?.title ?? "" } } catch { message = "Could not look up the link. You can still enter it manually. " + error.localizedDescription }
    }
}

struct ISODateField: View {
    let title: String
    @Binding var value: String
    @State private var zone = TimeZone.current.identifier
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            DatePicker(title,selection:Binding(get:{ ISO8601DateFormatter().date(from:value) ?? Date() },set:{ date in let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier:zone); value = f.string(from:date) })).environment(\.timeZone,TimeZone(identifier:zone) ?? .current)
            Picker("Time zone",selection:$zone) { ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + [zone])).sorted(),id:\.self) { Text($0.replacingOccurrences(of:"_",with:" ")).tag($0) } }.font(.caption)
        }.onAppear {
            if value.isEmpty { value = ISO8601DateFormatter().string(from:Date()) }
            else if value.hasSuffix("Z") { zone = "GMT" }
            else {
                let suffix = String(value.suffix(6))
                if suffix.range(of:#"^[+-]\d{2}:\d{2}$"#,options:.regularExpression) != nil { zone = "GMT" + suffix.replacingOccurrences(of:":",with:"") }
            }
        }
        .onChange(of:zone) { _,_ in if let date = ISO8601DateFormatter().date(from:value) { let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier:zone); value = f.string(from:date) } }
    }
}
struct LegEditor: View {
    @Binding var leg: Leg
    @State private var airportQuery = ""
    @State private var results: [MKMapItem] = []
    @State private var lookupError: String?
    var body: some View {
        Section("Travel leg") {
            Picker("Travel by",selection:$leg.transitType) { Text("Air").tag("air"); Text("Train").tag("train"); Text("Bus").tag("bus"); Text("Boat").tag("boat"); Text("Car").tag("car"); Text("Walk").tag("walk") }
            TextField("Operator",text:$leg.operatorName); TextField("Flight / service number",text:$leg.number)
            TextField("Origin (airport code or place)",text:$leg.origin); TextField("Destination",text:$leg.destination)
            ISODateField(title:"Departs",value:$leg.departure); ISODateField(title:"Arrives",value:$leg.arrival)
            DisclosureGroup("Find an airport or station") {
                TextField("Airport, station or city",text:$airportQuery)
                Button("Search places") { Task { do { let req = MKLocalSearch.Request(); req.naturalLanguageQuery = airportQuery; results = try await MKLocalSearch(request:req).start().mapItems; lookupError = nil } catch { lookupError = error.localizedDescription } } }
                if let lookupError { Text(lookupError).font(.caption).foregroundStyle(.red) }
                ForEach(Array(results.prefix(5).enumerated()),id:\.offset) { _,item in
                    HStack { Text(item.name ?? "Place").font(.caption); Spacer(); Button("Origin") { leg.origin = item.name ?? "" }.buttonStyle(.borderless); Button("Destination") { leg.destination = item.name ?? "" }.buttonStyle(.borderless) }
                }
            }
        }
    }
}
struct PostPreview: View {
    let draft: Draft
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Label(draft.kind.title,systemImage:draft.kind.symbol).font(.caption).foregroundStyle(.secondary)
                if !draft.title.isEmpty { Text(draft.title).font(.system(.largeTitle,design:.serif)) }
                if !draft.target.isEmpty { Text(draft.target).font(.footnote).foregroundStyle(.secondary) }
                if draft.isHTML { HTMLPreview(html:draft.content).frame(minHeight:300) } else { Text(draft.content).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled) }
                ForEach(draft.attachments) { attachment in if let image = UIImage(data:attachment.data) { Image(uiImage:image).resizable().scaledToFit().accessibilityLabel(attachment.alt) } }
                if !draft.tags.isEmpty { Text(draft.tags).font(.caption).foregroundStyle(.secondary) }
                if let data = try? Payload.create(draft).encoded(), let value = String(data:data,encoding:.utf8) { DisclosureGroup("Micropub request") { Text(value).font(.caption.monospaced()).textSelection(.enabled) } }
            }.padding(24).frame(maxWidth:760)
        }.navigationTitle("Preview").navigationBarTitleDisplayMode(.inline)
    }
}
