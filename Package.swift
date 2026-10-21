// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PhotoReader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PhotoReader", targets: ["PhotoReader"])
    ],
    targets: [
        .executableTarget(
            name: "PhotoReader",
            path: "Sources/PhotoReader"
        )
    ]
)
