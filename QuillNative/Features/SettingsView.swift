import SwiftUI
import QuillCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var confirmingStopSync = false

    var body: some View {
        @Bindable var store = store
        Form {
            if let account = store.account {
                Section {
                    LabeledContent("Site", value: account.me.host ?? account.me.absoluteString)
                        .textSelection(.enabled)
                }
            }
            Section {
                NavigationLink("Post Types") { PostTypesView() }
                Picker("Format", selection: $store.preferences.format) {
                    ForEach(ContentFormat.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.format")
                Picker("Weight Unit", selection: $store.preferences.weightUnit) {
                    Text("Pounds").tag("lb")
                    Text("Kilograms").tag("kg")
                    Text("Stone").tag("st")
                }
                NavigationLink("Advanced") { AdvancedView() }
            }
            Section {
                Toggle("Sync Posts", isOn: Binding(get: { store.syncEnabled == true }, set: { on in
                    if on { store.setSync(true) } else { confirmingStopSync = true }
                }))
                .accessibilityIdentifier("settings.sync")
                if store.syncEnabled == true {
                    Button("Sync Everything Again") { store.syncEverything() }
                        .disabled(store.syncing)
                }
            } footer: {
                if store.syncEnabled == true { Text(syncSummary) }
            }
            Section {
                Link("Source Code", destination: URL(string: "https://github.com/caseyg/quill-native")!)
                Link("Based on Quill", destination: URL(string: "https://github.com/aaronpk/Quill")!)
            } footer: {
                Text(version)
            }
            Section {
                Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("signout")
                    .confirmationDialog("Sign Out", isPresented: $confirmingSignOut) {
                        Button("Sign Out", role: .destructive) { Task { await store.signOut() } }
                    }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // On the form rather than the switch, so turning the switch off reliably presents it.
        .confirmationDialog("Stop Syncing", isPresented: $confirmingStopSync, titleVisibility: .visible) {
            Button("Delete Posts from iPhone", role: .destructive) { store.setSync(false) }
        } message: {
            Text("Posts on your site aren’t affected.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .refreshable { await store.refresh() }
        .onChange(of: store.preferences) { _, value in
            do { try SharedStorage.write(value, key: "preferences") } catch { store.error = error.localizedDescription }
        }
    }

    private var syncSummary: String {
        let count = "\(store.library.posts.count.formatted()) posts on this iPhone"
        if store.syncing { return count + " · Syncing" }
        guard let synced = store.library.synced else { return count }
        return count + " · Updated " + synced.formatted(.relative(presentation: .named))
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "1.0")"
    }
}

/// Post types to offer when posting and to show in the list.
private struct PostTypesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List(PostKind.allCases) { kind in
            Toggle(isOn: shown(kind)) { Label(kind.title, systemImage: kind.symbol) }
                // Keep at least one type, so there is always something to post.
                .disabled(store.preferences.visibleKinds == [kind])
        }
        .navigationTitle("Post Types")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func shown(_ kind: PostKind) -> Binding<Bool> {
        Binding(get: { !store.preferences.hiddenKinds.contains(kind) }, set: { isOn in
            store.preferences.hiddenKinds.removeAll { $0 == kind }
            if !isOn { store.preferences.hiddenKinds.append(kind) }
        })
    }
}

/// Settings most people never change: server details, per-type formats and protocol switches.
private struct AdvancedView: View {
    @Environment(AppStore.self) private var store
    @State private var formEncoded = SharedStorage.defaults.bool(forKey: "formEncoded")

    var body: some View {
        @Bindable var store = store
        Form {
            if let account = store.account {
                Section("Server") {
                    LabeledContent("Micropub", value: account.micropub.absoluteString)
                    if let media = store.config.mediaEndpoint { LabeledContent("Media", value: media.absoluteString) }
                    if !account.scope.isEmpty { LabeledContent("Permissions", value: account.scope) }
                    if !store.config.targets.isEmpty {
                        LabeledContent("Syndication", value: store.config.targets.map(\.name).joined(separator: ", "))
                    }
                }
                .textSelection(.enabled)
            }
            Section("Format by Post Type") {
                ForEach(PostKind.allCases.filter { ContentFormat.supported(by: $0).count > 1 }) { kind in
                    Picker(selection: override(kind)) {
                        Text("Default").tag(ContentFormat?.none)
                        ForEach(ContentFormat.supported(by: kind)) { Text($0.title).tag(Optional($0)) }
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            }
            Section("Compatibility") {
                Toggle("HTML Content Object", isOn: $store.preferences.htmlContent)
                Toggle("Form Encoding", isOn: $formEncoded)
                    .onChange(of: formEncoded) { _, value in SharedStorage.defaults.set(value, forKey: "formEncoded") }
                LabeledContent("Slug Field") {
                    TextField("mp-slug", text: $store.preferences.slugField)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Picker("Syndication Field", selection: $store.preferences.syndicationField) {
                    Text("mp-syndicate-to").tag("mp-syndicate-to")
                    Text("syndicate-to").tag("syndicate-to")
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func override(_ kind: PostKind) -> Binding<ContentFormat?> {
        Binding(get: { store.preferences.formatOverrides[kind] }, set: { store.preferences.formatOverrides[kind] = $0 })
    }
}
