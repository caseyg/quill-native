import AppIntents
import Foundation
import QuillCore

enum ComposeKind: String, AppEnum {
    case note, bookmark
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Post type"
    static let caseDisplayRepresentations: [ComposeKind:DisplayRepresentation] = [.note:"Note",.bookmark:"Bookmark"]
}
struct DraftEntity: AppEntity {
    let id: String
    let title: String
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Draft"
    static let defaultQuery = DraftQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title:"\(title)") }
}
struct DraftQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DraftEntity] { try all().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [DraftEntity] { Array(try all().prefix(10)) }
    func entities(matching string: String) async throws -> [DraftEntity] { try all().filter { $0.title.localizedCaseInsensitiveContains(string) } }
    private func all() throws -> [DraftEntity] { try SharedStorage.drafts.load().map { DraftEntity(id:$0.id.uuidString,title:$0.displayTitle) } }
}
private func routeToDraft(_ draft: Draft) throws {
    try SharedStorage.drafts.save(draft)
    SharedStorage.defaults.set("quill-native://draft?id=" + draft.id.uuidString,forKey:"pendingRoute")
    NotificationCenter.default.post(name:.quillRoute,object:nil)
}
struct ComposeNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Opens a new note.")
    static let openAppWhenRun = true
    @Parameter(title:"Text") var text: String?
    @MainActor func perform() async throws -> some IntentResult {
        var draft = Draft(kind:.note); draft.content = text ?? ""; draft.accountURL = SharedStorage.read(Account.self,key:"account")?.me
        try routeToDraft(draft); return .result()
    }
}
struct BookmarkURLIntent: AppIntent {
    static let title: LocalizedStringResource = "New Bookmark"
    static let description = IntentDescription("Opens a new bookmark.")
    static let openAppWhenRun = true
    @Parameter(title:"URL") var url: URL
    @MainActor func perform() async throws -> some IntentResult {
        _ = try WebURL.parse(url.absoluteString)
        var draft = Draft(kind:.bookmark); draft.target = url.absoluteString; draft.accountURL = SharedStorage.read(Account.self,key:"account")?.me
        try routeToDraft(draft); return .result()
    }
}
struct ResumeDraftIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Draft"
    static let openAppWhenRun = true
    @Parameter(title:"Draft") var draft: DraftEntity
    @MainActor func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString:draft.id), try SharedStorage.drafts.load().contains(where:{$0.id == id}) else { throw QuillError("This draft no longer exists.") }
        SharedStorage.defaults.set("quill-native://draft?id=" + id.uuidString,forKey:"pendingRoute")
        NotificationCenter.default.post(name:.quillRoute,object:nil); return .result()
    }
}
struct QuillShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent:ComposeNoteIntent(),phrases:["Write a note in \(.applicationName)","Compose with \(.applicationName)"],shortTitle:"New Note",systemImageName:"square.and.pencil")
        AppShortcut(intent:BookmarkURLIntent(),phrases:["Save a bookmark in \(.applicationName)"],shortTitle:"New Bookmark",systemImageName:"bookmark")
        AppShortcut(intent:ResumeDraftIntent(),phrases:["Resume a draft in \(.applicationName)"],shortTitle:"Open Draft",systemImageName:"tray")
    }
}
