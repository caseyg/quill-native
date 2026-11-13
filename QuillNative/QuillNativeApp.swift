import SwiftUI
import QuillCore

@main
struct QuillNativeApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).tint(Theme.ink).preferredColorScheme(debugColorScheme)
                .onOpenURL { store.reloadDrafts(); store.handle($0) }
                .task {
                    await store.refresh(); consumeIntent()
                    #if DEBUG
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("--run-note-intent") { let intent = ComposeNoteIntent(); intent.text = "Intent handoff with preserved text"; _ = try? await intent.perform() }
                    if let index = args.firstIndex(of:"--route"), args.indices.contains(index+1), let url = URL(string:args[index+1]) { store.handle(url) }
                    #endif
                }
                .onChange(of:scenePhase) { _,phase in if phase == .active { store.reloadDrafts(); consumeIntent() } }
                .onReceive(NotificationCenter.default.publisher(for:.quillRoute)) { _ in consumeIntent() }
        }
    }
    private var debugColorScheme: ColorScheme? {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : nil
        #else
        return nil
        #endif
    }
    private func consumeIntent() {
        if let value = SharedStorage.defaults.string(forKey:"pendingRoute"), let url = URL(string:value) {
            SharedStorage.defaults.removeObject(forKey:"pendingRoute"); store.reloadDrafts(); store.handle(url)
        }
    }
}
extension Notification.Name { static let quillRoute = Notification.Name("QuillRoute") }
enum Theme {
    static let brand = Color(red:0.32,green:0.20,blue:0.34)
    static let ink = Color(uiColor:UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(red:0.82,green:0.69,blue:0.86,alpha:1) : UIColor(red:0.32,green:0.20,blue:0.34,alpha:1) })
    static let paper = Color(uiColor:.systemGroupedBackground)
    static let accent = Color(uiColor:UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(red:0.86,green:0.63,blue:0.53,alpha:1) : UIColor(red:0.67,green:0.33,blue:0.23,alpha:1) })
}
struct RootView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        TabView(selection:$store.tab) {
            NavigationStack { HomeView() }.tabItem { Label("Compose",systemImage:"square.and.pencil") }.tag(0)
            NavigationStack { DraftsView() }.tabItem { Label("Drafts",systemImage:"tray") }.tag(1)
            NavigationStack { ActivityView() }.tabItem { Label("Activity",systemImage:"clock.arrow.circlepath") }.tag(2)
            NavigationStack { SettingsView() }.tabItem { Label("Settings",systemImage:"gearshape") }.tag(3)
        }
        .sheet(item:$store.composer) { draft in NavigationStack { ComposerView(draft:draft) }.environment(store) }
        .alert("Something needs attention",isPresented:Binding(get:{store.error != nil},set:{if !$0 { store.error = nil }})) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}
