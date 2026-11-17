import SwiftUI
import QuillCore

/// Signing in to GitHub, picking a repository, and the state of copying drafts there.
struct GitHubSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var code: GitHubDeviceCode?
    @State private var enteringToken = false
    @State private var confirmingSignOut = false
    @State private var folder = ""
    @State private var failure: String?
    @State private var starting = false

    private var github: GitHubBackup { store.github }

    var body: some View {
        Form {
            if let connection = github.connection {
                connected(connection)
            } else {
                signedOut
            }
        }
        .navigationTitle("GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $code) { code in
            NavigationStack { DeviceCodeView(code: code) }.environment(store)
        }
        .sheet(isPresented: $enteringToken) {
            NavigationStack { GitHubTokenView() }.environment(store)
        }
        .onAppear { folder = github.connection?.folder ?? "drafts" }
    }

    @ViewBuilder private var signedOut: some View {
        Section {
            if GitHubBackup.clientID != nil {
                Button {
                    Task { await startSignIn() }
                } label: {
                    HStack {
                        Text("Sign In with GitHub")
                        if starting { Spacer(); ProgressView() }
                    }
                }
                .disabled(starting)
                .accessibilityIdentifier("github.signin")
            }
            Button("Use a Token") { enteringToken = true }
                .accessibilityIdentifier("github.token")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Saving a draft writes it to a repository you choose, as Markdown. Posting still goes to your site.")
                if let failure { Text(failure).foregroundStyle(.red) }
            }
        }
    }

    @ViewBuilder private func connected(_ connection: GitHubBackup.Connection) -> some View {
        Section {
            LabeledContent("Account", value: connection.login)
            if let repository = connection.repository {
                NavigationLink {
                    RepositoryPicker()
                } label: {
                    LabeledContent("Repository") {
                        Label(repository.fullName, systemImage: repository.isPrivate ? "lock.fill" : "globe")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .accessibilityIdentifier("github.repository")
                LabeledContent("Folder") {
                    TextField("Top Level", text: $folder)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { github.setFolder(folder) }
                }
            } else {
                NavigationLink("Choose Repository") { RepositoryPicker() }
                    .accessibilityIdentifier("github.choose")
            }
        } footer: {
            if let repository = connection.repository, !repository.isPrivate {
                Label("This repository is public. Anyone can read these drafts on GitHub.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("github.public")
            }
        }

        if let repository = connection.repository {
            Section {
                Button("Sync Now") { Task { await github.sync() } }
                    .disabled(github.syncing)
                if let url = URL(string: "https://github.com/\(repository.fullName)") {
                    Link("Open on GitHub", destination: url)
                }
            } footer: {
                if github.syncing { Text("Syncing") }
                else if let problem = github.problem { Text(problem).foregroundStyle(.red) }
                else if let synced = github.synced { Text("Updated " + synced.formatted(.relative(presentation: .named))) }
            }
        }

        Section {
            Button("Sign Out of GitHub", role: .destructive) { confirmingSignOut = true }
                .frame(maxWidth: .infinity)
                .confirmationDialog("Sign Out of GitHub", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                    Button("Sign Out", role: .destructive) { github.disconnect() }
                } message: {
                    Text("Drafts stop syncing. Copies already on GitHub stay there.")
                }
        }
        .onChange(of: folder) { _, value in
            // Applied when typing pauses, so each keystroke doesn't move the drafts.
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if folder == value { github.setFolder(value) }
            }
        }
    }

    private func startSignIn() async {
        starting = true; defer { starting = false }
        failure = nil
        do { code = try await github.startSignIn() } catch { failure = error.localizedDescription }
    }
}

/// Shows the code to enter on github.com and waits for approval.
private struct DeviceCodeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let code: GitHubDeviceCode
    @State private var failure: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Enter this code on GitHub")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(code.userCode)
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .accessibilityIdentifier("github.code")
            Button {
                UIPasteboard.general.string = code.userCode
                copied = true
                openURL(code.verificationURL)
            } label: {
                Text("Copy Code and Open GitHub")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .prominentAction()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .sensoryFeedback(.success, trigger: copied)
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            } else {
                ProgressView().opacity(copied ? 1 : 0)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Sign In with GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .task {
            do {
                try await store.github.finishSignIn(code)
                dismiss()
            } catch is CancellationError {
                if !Task.isCancelled { dismiss() } // Declined on GitHub.
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Signs in with a personal access token, for builds without a client ID or for access to a single repository.
private struct GitHubTokenView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var failure: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                SecureField("Token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await signIn() } }
                    .accessibilityIdentifier("github.tokenfield")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A fine-grained token needs read and write access to Contents in the repository you’ll use.")
                    Link("Create a Token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("GitHub Token")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView() } else {
                    Button("Sign In") { Task { await signIn() } }.disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func signIn() async {
        busy = true; defer { busy = false }
        failure = nil
        do { try await store.github.signIn(token: token); dismiss() } catch { failure = error.localizedDescription }
    }
}

/// Repositories the person can write to. A public one is confirmed first, since anyone can read what's in it.
private struct RepositoryPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var repositories: [GitHubRepository]?
    @State private var failure: String?
    @State private var search = ""
    @State private var confirming: GitHubRepository?
    @State private var naming = false
    @State private var newName = "quill-drafts"
    @State private var creating = false

    var body: some View {
        List {
            Section {
                Button {
                    naming = true
                } label: {
                    HStack {
                        Label("New Private Repository", systemImage: "plus")
                        if creating { Spacer(); ProgressView() }
                    }
                }
                .disabled(creating)
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
            if let repositories {
                Section {
                    ForEach(filtered(repositories)) { repository in
                        Button { pick(repository) } label: { row(repository) }
                            .tint(.primary)
                    }
                }
            } else if failure == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Repository")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Use a Public Repository?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { repository in
            Button("Use \(repository.fullName)") { choose(repository) }
        } message: { _ in
            Text("Anyone on GitHub will be able to read your drafts, including ones you never post.")
        }
        .alert("New Private Repository", isPresented: $naming) {
            TextField("Name", text: $newName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await create() } }
        }
    }

    private func row(_ repository: GitHubRepository) -> some View {
        HStack {
            Label(repository.fullName, systemImage: repository.isPrivate ? "lock.fill" : "globe")
            Spacer()
            if !repository.isPrivate { Text("Public").font(.subheadline).foregroundStyle(.orange) }
            if store.github.connection?.repository?.fullName == repository.fullName {
                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
            }
        }
    }

    private func filtered(_ repositories: [GitHubRepository]) -> [GitHubRepository] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? repositories : repositories.filter { $0.fullName.localizedCaseInsensitiveContains(query) }
    }

    private func pick(_ repository: GitHubRepository) {
        if repository.isPrivate { choose(repository) } else { confirming = repository }
    }

    private func choose(_ repository: GitHubRepository) {
        store.github.choose(repository)
        dismiss()
    }

    private func load() async {
        do { repositories = try await store.github.repositories(); failure = nil }
        catch { failure = error.localizedDescription }
    }

    private func create() async {
        creating = true; defer { creating = false }
        do { choose(try await store.github.createRepository(named: newName.trimmingCharacters(in: .whitespaces))) }
        catch { failure = error.localizedDescription }
    }
}
