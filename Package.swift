// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Tether",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Tether", targets: ["TetherApp"]),
        .executable(name: "tether-askpass", targets: ["TetherAskPass"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        // Shared models, paths, settings and persistence. No UI.
        .target(name: "TetherCore"),

        // Round-trip safe ~/.ssh/config parser and editor.
        .target(name: "SSHConfigKit"),

        // Building ssh/scp invocations, ControlMaster multiplexing, askpass bridge, remote commands.
        .target(name: "SSHTransport", dependencies: ["TetherCore"]),

        // tmux control mode (-CC) protocol parser and command encoder.
        .target(name: "TmuxControl"),

        // Local terminal output recording with a global size quota.
        .target(name: "RecordingKit", dependencies: ["TetherCore"]),

        // Live terminal sessions: persistence strategies, reconnect state machine.
        .target(name: "SessionKit", dependencies: [
            "TetherCore", "SSHTransport", "TmuxControl", "RecordingKit",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),

        // Terminal view, theme and keyboard handling.
        .target(name: "TerminalUI", dependencies: [
            "TetherCore", "SessionKit",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),

        // Remote file browsing and scp transfers.
        .target(name: "FileTransferKit", dependencies: [
            "TetherCore", "SSHTransport",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),

        // Remote system metrics, processes, logs and connections.
        .target(name: "MonitorKit", dependencies: ["SSHTransport"]),

        // Search across live terminals and recorded transcripts.
        .target(name: "SearchKit", dependencies: ["TetherCore", "RecordingKit"]),

        // SSH key generation and installation.
        .target(name: "KeySetupKit", dependencies: ["TetherCore", "SSHTransport"]),

        // The macOS application.
        .executableTarget(name: "TetherApp", dependencies: [
            "TetherCore", "SSHConfigKit", "SSHTransport", "TmuxControl", "RecordingKit",
            "SessionKit", "TerminalUI", "FileTransferKit", "MonitorKit", "KeySetupKit", "SearchKit",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),

        // Tiny SSH_ASKPASS helper that forwards prompts to the running app.
        .executableTarget(name: "TetherAskPass"),

        .testTarget(name: "SSHConfigKitTests", dependencies: ["SSHConfigKit"]),
        .testTarget(name: "TmuxControlTests", dependencies: ["TmuxControl"]),
        .testTarget(name: "MonitorKitTests", dependencies: ["MonitorKit"]),
        .testTarget(name: "RecordingKitTests", dependencies: ["RecordingKit", "TetherCore"]),
        .testTarget(name: "SSHTransportTests", dependencies: ["SSHTransport", "TetherCore"]),
        .testTarget(name: "FileTransferKitTests", dependencies: ["FileTransferKit", "SSHTransport", "TetherCore"]),
        .testTarget(name: "SearchKitTests", dependencies: ["SearchKit", "RecordingKit"]),
        .testTarget(name: "SessionKitTests", dependencies: ["SessionKit", "TetherCore"]),
        .testTarget(name: "TerminalUITests", dependencies: ["TerminalUI", "SessionKit", "TetherCore", "SearchKit", "RecordingKit",
                                                            .product(name: "SwiftTerm", package: "SwiftTerm")]),
    ],
    swiftLanguageModes: [.v5]
)
