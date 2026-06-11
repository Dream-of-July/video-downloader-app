// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VideoDownloader",
    platforms: [.macOS(.v14)],
    targets: [
        // 核心逻辑：链接嗅探 + yt-dlp 封装，可被 App 和 CLI 共用
        .target(name: "VDLCore", path: "Sources/VDLCore"),
        // SwiftUI 图形界面 App
        .executableTarget(
            name: "VideoDownloader",
            dependencies: ["VDLCore"],
            path: "Sources/VideoDownloader"
        ),
        // 命令行测试工具，用于不开 GUI 的端到端验证
        .executableTarget(
            name: "vdl-cli",
            dependencies: ["VDLCore"],
            path: "Sources/vdl-cli"
        ),
    ]
)
