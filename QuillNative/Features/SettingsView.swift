import SwiftUI
import QuillCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var site = ""
    @State private var clientID = SharedStorage.defaults.string(forKey:"clientID") ?? (Bundle.main.object(forInfoDictionaryKey:"QuillIndieAuthClientID") as? String ?? "https://caseyagollan.com/clients/quill-native/")
    @State private var personalToken = ""
    @State private var tokenScope = "create update media draft"
    @State private var confirmRevoke = false
    @State private var formEncoded = SharedStorage.defaults.bool(forKey:"formEncoded")
    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                if let account = store.account {
                    Label(account.me.host ?? account.me.absoluteString,systemImage:"person.crop.circle").font(.headline)
                    LabeledContent("Granted permissions",value:account.scope).font(.caption)
                    Button("Refresh site capabilities") { Task { await store.refresh() } }
                    Button("Revoke token and sign out",role:.destructive) { confirmRevoke = true }
                    Button("Sign out on this device",role:.destructive) { Task { await store.signOut(revoke:false) } }
                } else {
                    Text("Bring your own website.").font(.system(.title2,design:.serif))
                    TextField("Website URL (https://…)",text:$site).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("login.site")
                    TextField("IndieAuth client ID (https://…)",text:$clientID).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("login.clientID")
                    Button { SharedStorage.defaults.set(clientID,forKey:"clientID"); Task { await store.signIn(site:site,clientID:clientID) } } label: { HStack { Text("Login"); if store.busy { Spacer(); ProgressView() } } }.disabled(store.busy || !validSiteURL || !validClientURL).accessibilityIdentifier("login.button")
                }
            } header: { Text("Your website") } footer: { if store.account == nil { Text("Enter full URLs, including https://. Your client ID page must declare quill-native://oauth as a redirect URI.") } }
            if store.account == nil {
                Section {
                    DisclosureGroup("Connect with a personal token") {
                        Text("Create a token on your own site and paste it here. It is stored only in this device’s Keychain.").font(.caption).foregroundStyle(.secondary)
                        SecureField("Micropub access token",text:$personalToken).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("login.token")
                        TextField("Granted scopes",text:$tokenScope).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Connect token") { let token = personalToken; personalToken = ""; Task { await store.connectToken(site:site,token:token,scope:tokenScope) } }.disabled(store.busy || !validSiteURL || personalToken.isEmpty)
                        Link("Manage tokens on caseyagollan.com",destination:URL(string:"https://caseyagollan.com/account")!)
                    }
                }
            }
            if let account = store.account {
                Section("Connection") {
                    LabeledContent("Micropub") { Text(account.micropub.absoluteString).textSelection(.enabled) }
                    LabeledContent("Media") { Text(store.config.mediaEndpoint?.absoluteString ?? "Multipart upload") }
                    if !store.config.postTypes.isEmpty { LabeledContent("Post types",value:store.config.postTypes.joined(separator:", ")) }
                    if !store.config.channels.isEmpty { LabeledContent("Channels",value:store.config.channels.joined(separator:", ")) }
                    if !store.config.targets.isEmpty { LabeledContent("Syndication",value:store.config.targets.map(\.name).joined(separator:", ")) }
                    if let warning = store.configWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                }.font(.footnote)
            }
            Section("Post defaults") {
                Picker("Weight unit",selection:$store.preferences.weightUnit) { Text("Pounds (lb)").tag("lb"); Text("Kilograms (kg)").tag("kg"); Text("Stone (st)").tag("st") }
                Toggle("Send rich content as HTML object",isOn:$store.preferences.htmlContent)
            }
            Section("Compatibility") {
                TextField("Slug field",text:$store.preferences.slugField).autocorrectionDisabled().textInputAutocapitalization(.never)
                Picker("Syndication field",selection:$store.preferences.syndicationField) { Text("mp-syndicate-to").tag("mp-syndicate-to"); Text("syndicate-to (legacy)").tag("syndicate-to") }
                Toggle("Use form encoding for new posts",isOn:$formEncoded).onChange(of:formEncoded) { _,value in SharedStorage.defaults.set(value,forKey:"formEncoded") }
            }
            Section("About") {
                Text("Quill Native").font(.system(.title3,design:.serif))
                Text("An independent native client for the open web. Inspired by Aaron Parecki’s Quill.").font(.footnote).foregroundStyle(.secondary)
                Link("Quill source and documentation",destination:URL(string:"https://github.com/aaronpk/Quill")!)
                Text("Email and MMS publishing are excluded from this native-only app.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
        .onChange(of:store.preferences) { _,value in do { try SharedStorage.write(value,key:"preferences") } catch { store.error = error.localizedDescription } }
        .confirmationDialog("Revoke this app’s token?",isPresented:$confirmRevoke,titleVisibility:.visible) { Button("Revoke and sign out",role:.destructive) { Task { await store.signOut(revoke:true) } } }
    }
    private var validSiteURL: Bool { (try? WebURL.parse(site)) != nil }
    private var validClientURL: Bool { (try? WebURL.parse(clientID))?.scheme == "https" }
}
