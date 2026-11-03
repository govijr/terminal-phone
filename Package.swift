// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "terminal-phone",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "terminal-phone", targets: ["TerminalPhone"])],
    targets: [
        .target(name: "TerminalMacCore"),
        .target(name: "CPhoneShim"),
        .target(name: "TerminalUI", dependencies: ["CPhoneShim"]),
        .target(name: "TerminalPhoneCore", dependencies: ["TerminalMacCore", "TerminalUI"]),
        .executableTarget(name: "TerminalPhone", dependencies: ["TerminalPhoneCore", "TerminalMacCore", "CPhoneShim"],
                          linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "TerminalPhoneCoreTests", dependencies: ["TerminalPhoneCore"]),
        .testTarget(name: "TerminalPhoneTests", dependencies: ["TerminalPhone", "TerminalPhoneCore"])
    ],
    swiftLanguageModes: [.v5]
)
