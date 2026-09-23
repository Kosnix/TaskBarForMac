// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TaskbarReplacement",
    defaultLocalization: "fr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TaskbarReplacement", targets: ["TaskbarReplacement"])
    ],
    targets: [
        .executableTarget(
            name: "TaskbarReplacement",
            path: "Sources",
            resources: [
                .copy("Resources/Themes"),
                .process("Resources/fr.lproj"),
                .process("Resources/en.lproj"),
                .process("Resources/es.lproj"),
                .process("Resources/ru.lproj")
            ]
        )
    ]
)
