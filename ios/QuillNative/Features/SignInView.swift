import SwiftUI
import QuillCore

struct SignInView: View {
    @Environment(AppStore.self) private var store
    @State private var site = ""
    @State private var token = ""
    @State private var usesToken = false
    @State private var failure: String?
    @State private var attempts = 0
    @FocusState private var focus: Field?

    private enum Field { case site, token }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "pencil.tip")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Quill").font(.largeTitle.bold())
                }
                .padding(.top, 72)

                VStack(spacing: 12) {
                    VStack(spacing: 0) {
                        TextField("yourdomain.com", text: $site)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(usesToken ? .next : .go)
                            .focused($focus, equals: .site)
                            .onSubmit { if usesToken { focus = .token } else { signIn() } }
                            .accessibilityLabel("Website")
                            .accessibilityIdentifier("login.site")
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                        if usesToken {
                            Divider().padding(.leading, 16)
                            SecureField("Access token", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.go)
                                .focused($focus, equals: .token)
                                .onSubmit(signIn)
                                .accessibilityIdentifier("login.token")
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                    .modifier(Shake(animatableData: CGFloat(attempts)))

                    if let failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .transition(.opacity)
                            .accessibilityIdentifier("login.error")
                    }

                    Button(action: signIn) {
                        ZStack {
                            Text("Sign In").opacity(store.busy ? 0 : 1)
                            if store.busy { ProgressView() }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .prominentAction()
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("login.button")
                    .padding(.top, 4)

                    Button(usesToken ? "Sign In with IndieAuth" : "Use an Access Token") {
                        withAnimation(.snappy) { usesToken.toggle(); failure = nil }
                        focus = usesToken ? .token : .site
                    }
                    .font(.subheadline)
                    .padding(.top, 8)
                    .accessibilityIdentifier("login.mode")
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground))
        .sensoryFeedback(.error, trigger: attempts)
        .disabled(store.busy)
    }

    private var canSubmit: Bool {
        (try? WebURL.site(site)) != nil && (!usesToken || !token.isEmpty) && !store.busy
    }

    private func signIn() {
        guard canSubmit else { return }
        focus = nil
        withAnimation { failure = nil }
        Task {
            do {
                if usesToken { try await store.signIn(site: site, token: token) }
                else { try await store.signIn(site: site) }
            } catch is CancellationError {
            } catch {
                withAnimation(.default) { failure = error.localizedDescription; attempts += 1 }
            }
        }
    }
}
