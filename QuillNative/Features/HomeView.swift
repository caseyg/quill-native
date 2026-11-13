import SwiftUI
import QuillCore

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @ScaledMetric private var iconSize = 24
    @ScaledMetric(relativeTo:.largeTitle) private var headingSize = 40
    private let columns = [GridItem(.adaptive(minimum:150),spacing:12)]
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:28) {
                HStack {
                    Label("QUILL",systemImage:"pencil.tip").font(.system(.caption,design:.rounded,weight:.bold)).tracking(3)
                    Spacer()
                    HStack(spacing:6) { Circle().fill(store.account == nil ? Color.secondary : .green).frame(width:6,height:6); Text(store.account?.me.host ?? "Not connected").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                VStack(alignment:.leading,spacing:12) {
                    Text("A little space\nfor your words.").font(.system(size:headingSize,weight:.regular,design:.serif)).tracking(-1).fixedSize(horizontal:false,vertical:true)
                    Text("Publish to your own corner of the web.").foregroundStyle(.secondary).font(.subheadline)
                }
                Button { store.compose(.note) } label: {
                    VStack(alignment:.leading,spacing:24) {
                        HStack { Image(systemName:"square.and.pencil").font(.title2); Spacer(); Image(systemName:"arrow.up.right") }
                        VStack(alignment:.leading,spacing:6) { Text("What’s on your mind?").font(.system(.title2,design:.serif)); Text("Start a note").font(.subheadline).opacity(0.8) }
                    }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(Theme.brand,in:RoundedRectangle(cornerRadius:22)).foregroundStyle(.white)
                }.buttonStyle(.plain).accessibilityIdentifier("compose.note")
                VStack(alignment:.leading,spacing:14) {
                    HStack { Text("MAKE SOMETHING").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary); Spacer(); Text("12 more ways").font(.caption).foregroundStyle(.tertiary) }
                    LazyVGrid(columns:columns,spacing:12) {
                        ForEach(PostKind.allCases.filter { $0 != .note }) { kind in
                            Button { store.compose(kind) } label: {
                                VStack(alignment:.leading,spacing:12) {
                                    Image(systemName:kind.symbol).font(.system(size:iconSize,weight:.regular)).foregroundStyle(Theme.accent)
                                    VStack(alignment:.leading,spacing:4) { Text(kind.title).font(.headline).foregroundStyle(.primary); Text(kind.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                                }.frame(maxWidth:.infinity,minHeight:100,alignment:.leading).padding(18).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:18))
                            }.buttonStyle(.plain).accessibilityIdentifier("compose." + kind.rawValue)
                        }
                    }
                }
                if store.account == nil {
                    Button { store.tab = 3 } label: { Label("Connect your website to publish",systemImage:"link").font(.subheadline).frame(maxWidth:.infinity).padding() }.buttonStyle(.bordered)
                }
                Text("Your website. Your voice. Your words to keep.").font(.footnote).foregroundStyle(.tertiary).frame(maxWidth:.infinity).padding(.vertical,8)
            }.padding(22).frame(maxWidth:760)
        }.background(Theme.paper).toolbar(.hidden,for:.navigationBar)
    }
}
