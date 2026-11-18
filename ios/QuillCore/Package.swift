// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "QuillCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "QuillCore", targets: ["QuillCore"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.7.3")],
    targets: [
        .target(name: "QuillCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .testTarget(name: "QuillCoreTests", dependencies: ["QuillCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
