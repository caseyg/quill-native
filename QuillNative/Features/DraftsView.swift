import SwiftUI
import QuillCore

struct DraftsView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    var filtered: [Draft] { store.drafts.filter { search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        List {
            Section { Text("Saved on this device. Pick up where you left off.").font(.subheadline).foregroundStyle(.secondary).listRowBackground(Color.clear) }
            ForEach(filtered) { draft in
                Button { store.composer = draft } label: {
                    HStack(spacing:16) {
                        Image(systemName:draft.kind.symbol).font(.title3).foregroundStyle(Theme.ink).frame(width:28)
                        VStack(alignment:.leading,spacing:5) { Text(draft.displayTitle).font(.headline).lineLimit(2).foregroundStyle(.primary); Text("\(draft.kind.title) · \(draft.modified.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical,8)
                }.swipeActions { Button("Delete",role:.destructive) { store.remove(draft) } }
            }
        }.overlay { if store.drafts.isEmpty { ContentUnavailableView("Room for a first draft",systemImage:"tray",description:Text("Your notes and unfinished posts will be waiting here.")) } }
            .navigationTitle("Drafts").searchable(text:$search).refreshable { store.reloadDrafts() }
            .toolbar { Button { store.compose(.note) } label: { Image(systemName:"square.and.pencil") }.accessibilityLabel("New note") }
    }
}
struct ActivityView: View {
    @Environment(AppStore.self) private var store
    @State private var editURL = ""
    @State private var sharing: Receipt?
    var body: some View {
        List {
            Section("Edit a post") {
                TextField("https://your.site/post",text:$editURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("edit.url")
                Button("Load post") { Task { await store.edit(editURL) } }.disabled(store.busy || editURL.isEmpty)
                Text("Load a like, repost, or code snippet from your site.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = store.publishMessage { Section { Label(message,systemImage:"checkmark.circle.fill").font(.subheadline).foregroundStyle(.green).textSelection(.enabled) } }
            Section("Publication receipts on this device") {
                ForEach(store.receipts) { receipt in
                    VStack(alignment:.leading,spacing:8) {
                        Label(receipt.title,systemImage:receipt.kind.symbol).font(.headline)
                        Text(receipt.status + " · " + receipt.date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                        Link(receipt.url.absoluteString,destination:receipt.url).font(.footnote).lineLimit(2).buttonStyle(.borderless)
                        Button { sharing = receipt } label: { Label("Share link",systemImage:"square.and.arrow.up").font(.caption) }.buttonStyle(.borderless)
                    }.padding(.vertical,8)
                }
                if store.receipts.isEmpty { Text("Your publication links will appear here after you send a post.").foregroundStyle(.secondary) }
            }
        }.navigationTitle("Activity").sheet(item:$sharing) { receipt in ActivityShareSheet(url:receipt.url).presentationDetents([.medium,.large]) }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems:[url],applicationActivities:nil) }
    func updateUIViewController(_ controller: UIActivityViewController,context: Context) {}
}
