import Foundation

#if !os(Windows)
/// macOS 依赖体检与一键安装支持：缺 yt-dlp/ffmpeg/deno 时 GUI 弹引导，
/// 经 Homebrew 安装；Homebrew 不存在时引导用户先装（绝不静默 curl|bash）。
public enum DependencySetup {

    public struct Component: Identifiable, Equatable {
        /// 展示名 = 二进制名
        public let id: String
        /// brew 公式名
        public let formula: String
        /// 一句话用途
        public let purpose: String
        public let isInstalled: Bool
    }

    /// 三件套体检。ffmpeg 与 Burner 同口径：必须带 subtitles/libass 渲染能力；
    /// JS 运行时 deno/node 任一即可（yt-dlp 解 YouTube n-challenge 需要）。
    public static func check() -> [Component] {
        components(
            ytDlpInstalled: find("yt-dlp") != nil,
            subtitleRendererFfmpegInstalled: FFmpegBurner.locateSubtitleRendererFFmpeg() != nil,
            jsRuntimeInstalled: find("deno") != nil || find("node") != nil
        )
    }

    internal static func components(
        ytDlpInstalled: Bool,
        subtitleRendererFfmpegInstalled: Bool,
        jsRuntimeInstalled: Bool
    ) -> [Component] {
        [
            Component(
                id: "yt-dlp", formula: "yt-dlp",
                purpose: "视频解析与下载",
                isInstalled: ytDlpInstalled
            ),
            Component(
                id: "ffmpeg", formula: "ffmpeg-full",
                purpose: "合并、转码与字幕烧录（需 libass）",
                isInstalled: subtitleRendererFfmpegInstalled
            ),
            Component(
                id: "deno", formula: "deno",
                purpose: "YouTube 下载所需的 JS 运行时",
                isInstalled: jsRuntimeInstalled
            ),
        ]
    }

    public static func missing(from components: [Component]) -> [Component] {
        components.filter { !$0.isInstalled }
    }

    public static func needsSetup(_ components: [Component]) -> Bool {
        !missing(from: components).isEmpty
    }

    public static var missing: [Component] { missing(from: check()) }

    /// Homebrew 可执行路径（Apple Silicon / Intel 双位置）。
    public static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func find(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
#endif
