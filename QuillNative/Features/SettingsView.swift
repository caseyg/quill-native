import SwiftUI
import QuillCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false

    var body: some View {
        @Bindable var store = store
        Form {
            if let account = store.account {
                Section {
                    LabeledContent("Site", value: account.me.host ?? account.me.absoluteString)
                    LabeledContent("Micropub", value: account.micropub.absoluteString)
                    if let media = store.config.mediaEndpoint { LabeledContent("Media", value: media.absoluteString) }
                    if !account.scope.isEmpty { LabeledContent("Permissions", value: account.scope) }
                    if !store.config.targets.isEmpty {
                        LabeledContent("Syndication", value: store.config.targets.map(\.name).joined(separator: ", "))
                    }
                }
                .textSelection(.enabled)
            }
            Section {
                Picker("Weight Unit", selection: $store.preferences.weightUnit) {
                    Text("Pounds").tag("lb")
                    Text("Kilograms").tag("kg")
                    Text("Stone").tag("st")
                }
                NavigationLink("Compatibility") { CompatibilityView() }
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .refreshable { await store.refresh() }
        .onChange(of: store.preferences) { _, value in
            do { try SharedStorage.write(value, key: "preferences") } catch { store.error = error.localizedDescription }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "1.0")"
    }
}

/// Switches for servers that expect older Micropub conventions.
private struct CompatibilityView: View {
    @Environment(AppStore.self) private var store
    @State private var formEncoded = SharedStorage.defaults.bool(forKey: "formEncoded")

    var body: some View {
        @Bindable var store = store
        Form {
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
        .navigationTitle("Compatibility")
        .navigationBarTitleDisplayMode(.inline)
    }
}
