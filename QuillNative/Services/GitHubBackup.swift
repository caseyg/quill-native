import SwiftUI
import Observation
import QuillCore

/// Keeps a copy of every draft in a GitHub repository the person picks. Separate from posting to their site.
@MainActor @Observable
final class GitHubBackup {
    struct Connection: Codable, Equatable {
        var login: String
        var repository: GitHubRepository?
        var folder = "drafts"
    }

    private(set) var connection: Connection? = SharedStorage.read(Connection.self, key: "github")
    private(set) var syncing = false
    private(set) var synced: Date? = SharedStorage.defaults.object(forKey: "githubSynced") as? Date
    /// The last failure, shown in Settings. Drafts stay on the device and are tried again on the next save.
    private(set) var problem: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var again = false

    private static let keychainAccount = "github:token"

    /// The OAuth app's public client ID, from `QUILL_GITHUB_CLIENT_ID`. Without one, only a token can be used.
    static let clientID: String? = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "QuillGitHubClientID") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }()

    var isOn: Bool { connection?.repository != nil }

    private var client: GitHubClient? {
        (try? Keychain.token(for: GitHubBackup.keychainAccount)).map(GitHubClient.init(token:))
    }

    // MARK: Signing in

    func startSignIn() async throws -> GitHubDeviceCode {
        guard let clientID = GitHubBackup.clientID else { throw QuillError("This build has no GitHub client ID. Use a token instead.") }
        return try await GitHubDeviceFlow.start(clientID: clientID)
    }

    func finishSignIn(_ code: GitHubDeviceCode) async throws {
        guard let clientID = GitHubBackup.clientID else { return }
        try await signIn(token: try await GitHubDeviceFlow.token(clientID: clientID, code: code))
    }

    func signIn(token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw QuillError("Enter a token.") }
        let login = try await GitHubClient(token: token).login()
        try Keychain.save(token, for: GitHubBackup.keychainAccount)
        save(Connection(login: login))
        problem = nil
    }

    /// Forgets the sign-in and the repository. Files already in the repository stay there.
    func disconnect() {
        pending?.cancel(); pending = nil
        try? Keychain.delete(GitHubBackup.keychainAccount)
        SharedStorage.defaults.removeObject(forKey: "github")
        SharedStorage.defaults.removeObject(forKey: "githubMirror")
        SharedStorage.defaults.removeObject(forKey: "githubSynced")
        connection = nil; synced = nil; problem = nil
    }

    // MARK: Repository

    func repositories() async throws -> [GitHubRepository] {
        guard let client else { throw QuillError("Sign in to GitHub first.") }
        return try await client.repositories()
    }

    func createRepository(named name: String) async throws -> GitHubRepository {
        guard let client else { throw QuillError("Sign in to GitHub first.") }
        return try await client.createPrivateRepository(named: name)
    }

    /// Starts copying every draft to this repository.
    func choose(_ repository: GitHubRepository) {
        guard var connection else { return }
        connection.repository = repository
        save(connection)
        problem = nil
        schedule(after: .zero)
    }

    func setFolder(_ folder: String) {
        guard var connection else { return }
        let folder = DraftMirror.normalize(folder)
        guard folder != connection.folder else { return }
        connection.folder = folder
        save(connection)
        schedule(after: .zero)
    }

    private func save(_ connection: Connection) {
        self.connection = connection
        try? SharedStorage.write(connection, key: "github")
    }

    // MARK: Syncing

    /// Sends draft changes shortly, so several saves in a row become one pass.
    func schedule(after delay: Duration = .seconds(1)) {
        guard isOn else { return }
        if syncing { again = true; return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        guard let connection, let repository = connection.repository, let client, !syncing else { return }
        syncing = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "GitHub drafts")
        defer {
            syncing = false
            UIApplication.shared.endBackgroundTask(background)
            if again { again = false; schedule() }
        }
        var mirror = SharedStorage.read(DraftMirror.self, key: "githubMirror") ?? DraftMirror(repository: repository.fullName, folder: connection.folder)
        // Another repository or folder starts over. What is in the old one stays there.
        if mirror.repository != repository.fullName || mirror.folder != DraftMirror.normalize(connection.folder) {
            mirror = DraftMirror(repository: repository.fullName, folder: connection.folder)
        }
        do {
            let steps = mirror.plan(try SharedStorage.drafts.load())
            if !steps.isEmpty {
                // A repository made public since it was chosen should say so in Settings.
                let current = try await client.repository(repository.fullName)
                if current != repository, self.connection?.repository == repository { var updated = connection; updated.repository = current; save(updated) }
            }
            for step in steps {
                for write in step.writes {
                    try stillWriting(to: mirror)
                    let sha = try await client.put(write.path, write.data, message: "Save draft: \(step.title)",
                                                   sha: mirror.drafts[step.id.uuidString]?.files[write.path], in: mirror.repository)
                    try stillWriting(to: mirror)
                    mirror.wrote(write.path, sha: sha, for: step.id)
                    store(mirror)
                }
                for removal in step.removals {
                    try stillWriting(to: mirror)
                    try await client.delete(removal.path, message: "Remove draft: \(step.title)", sha: removal.sha, in: mirror.repository)
                    try stillWriting(to: mirror)
                    mirror.removed(removal.path, for: step.id)
                    store(mirror)
                }
                mirror.finished(step)
                store(mirror)
            }
            problem = nil
            synced = Date(); SharedStorage.defaults.set(synced, forKey: "githubSynced")
        } catch is CancellationError {
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Stops a pass when the person disconnects or picks another repository or folder while it runs.
    private func stillWriting(to mirror: DraftMirror) throws {
        try Task.checkCancellation()
        guard let connection, connection.repository?.fullName == mirror.repository, DraftMirror.normalize(connection.folder) == mirror.folder else { throw CancellationError() }
    }

    private func store(_ mirror: DraftMirror) { try? SharedStorage.write(mirror, key: "githubMirror") }
}
