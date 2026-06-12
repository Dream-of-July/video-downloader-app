// swift-tools-version: 5.10
import PackageDescription

// GUI（SwiftUI/AppKit/WebKit）仅 macOS；Windows 上只构建核心库与 CLI。
var packageTargets: [Target] = [
    // 核心逻辑：链接嗅探 + yt-dlp 封装 + 翻译 + 烧录，可被 App 和 CLI 共用
    .target(name: "VDLCore", path: "Sources/VDLCore"),
    // 命令行工具：跨平台（macOS / Windows），不开 GUI 也能走全流程
    .executableTarget(
        name: "vdl-cli",
        dependencies: ["VDLCore"],
        path: "Sources/vdl-cli"
    ),
    .testTarget(
        name: "VDLCoreTests",
        dependencies: ["VDLCore"],
        path: "Tests/VDLCoreTests"
    ),
]

#if !os(Windows)
packageTargets.append(
    // SwiftUI 图形界面 App（仅 macOS）
    .executableTarget(
        name: "VideoDownloader",
        dependencies: ["VDLCore"],
        path: "Sources/VideoDownloader"
    )
)
#endif

let package = Package(
    name: "VideoDownloader",
    platforms: [.macOS(.v14)],
    targets: packageTargets
)
