import SwiftUI
import QuillCore

@main
struct QuillNativeApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Theme.tint)
                .preferredColorScheme(debugColorScheme)
                .onOpenURL { store.reloadDrafts(); store.handle($0) }
                .task {
                    await store.refresh()
                    consumeIntent()
                    #if DEBUG
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("--run-note-intent") {
                        let intent = ComposeNoteIntent()
                        intent.text = "Intent handoff with preserved text"
                        _ = try? await intent.perform()
                    }
                    if let index = args.firstIndex(of: "--route"), args.indices.contains(index + 1), let url = URL(string: args[index + 1]) {
                        store.handle(url)
                    }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.reloadDrafts(); consumeIntent() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .quillRoute)) { _ in consumeIntent() }
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
        guard let value = SharedStorage.defaults.string(forKey: "pendingRoute"), let url = URL(string: value) else { return }
        SharedStorage.defaults.removeObject(forKey: "pendingRoute")
        store.reloadDrafts()
        store.handle(url)
    }
}

extension Notification.Name { static let quillRoute = Notification.Name("QuillRoute") }

enum Theme {
    /// The one accent colour, matched to the app icon. Everything else is system colour.
    static let tint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.82, green: 0.69, blue: 0.86, alpha: 1)
            : UIColor(red: 0.32, green: 0.20, blue: 0.34, alpha: 1)
    })
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Namespace private var zoom

    var body: some View {
        @Bindable var store = store
        Group {
            if store.account == nil {
                SignInView().transition(.opacity)
            } else {
                NavigationStack { HomeView(zoom: zoom) }.transition(.opacity)
            }
        }
        .animation(.smooth, value: store.account == nil)
        .sheet(item: $store.composer) { draft in
            NavigationStack { ComposerView(draft: draft) }
                .environment(store)
                .zoomTransition(from: store.composerSource, in: zoom)
        }
        .sheet(isPresented: $store.showSettings) {
            NavigationStack { SettingsView() }.environment(store)
        }
        .alert(store.error ?? "", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}
