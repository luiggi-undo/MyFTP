// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyFTP",
    platforms: [
        .macOS("27.0") // macOS Golden Gate
    ],
    products: [
        .executable(name: "MyFTP", targets: ["MyFTP"]),
        .library(name: "FTPKit", targets: ["FTPKit"]),
    ],
    targets: [
        .target(name: "FTPKit"),
        .executableTarget(
            name: "MyFTP",
            dependencies: ["FTPKit"]
        ),
        .testTarget(
            name: "FTPKitTests",
            dependencies: ["FTPKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
