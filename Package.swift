// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BiliDesktop", platforms: [.macOS(.v13)], products: [.executable(name: "BiliDesktop", targets: ["BiliDesktop"])], targets: [.executableTarget(name: "BiliDesktop", resources: [.copy("Resources")])])
