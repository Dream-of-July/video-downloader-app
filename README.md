# 视频下载器

macOS 原生 App（SwiftUI），类似 Downie：粘贴视频链接 → 解析出清晰度与字幕选项 → 选择后下载到 `~/Downloads`。

## 工作方式

1. **解析链接**：yt-dlp 原生支持的链接（YouTube、Vimeo、B 站、直链 mp4 等）直接解析；不支持的网页会自动嗅探页面里内嵌的视频（og:video、`<video>` 标签、YouTube/Vimeo iframe、`data-videoid` 等），列出候选让你选。
2. **选择**：清晰度按档位列出（含估算大小），字幕区分真实字幕与自动生成字幕。
3. **下载**：调用系统里的 yt-dlp + ffmpeg 完成下载、合并与字幕转换（srt）。

## 依赖

仅依赖已通过 Homebrew 安装的命令行工具，无任何第三方 Swift 包：

- `yt-dlp`（建议 ≥ 2026.06.09，旧版可能被 YouTube 风控拦截）
- `ffmpeg` / `ffprobe`

## 构建安装

```sh
./build.sh
```

编译产物放在 `~/Library/Caches/vdl-build`（本项目位于 iCloud 同步的 `~/Documents` 下，构建产物留在项目内会破坏 codesign），App 安装到 `~/Applications/视频下载器.app`。

## 命令行测试工具

不开 GUI 也能验证全流程：

```sh
swift run --scratch-path ~/Library/Caches/vdl-build vdl-cli resolve <url>
swift run --scratch-path ~/Library/Caches/vdl-build vdl-cli analyze <url>
swift run --scratch-path ~/Library/Caches/vdl-build vdl-cli download <url> --video-id <id> --format <formatID> [--subs en] [--auto-subs zh-Hans] [--dest 路径]
```

## 字幕翻译 API

设置页支持两种接口协议，模型名可以先留空；填好服务地址和凭证后，点「拉取模型」从服务端 `/v1/models` 取真实可用列表，再从「选择模型」里选（拉不到时也可手动填写）：

- `Anthropic-compatible`：用于 Anthropic 官方 API、公司 Claude 网关，以及公司网关把 Anthropic 协议映射到 DeepSeek 等模型的场景。
- `OpenAI-compatible`：用于 OpenAI Responses API。服务地址填 `https://api.openai.com`，凭证填 OpenAI API key。

CLI 也可以临时覆盖：

```sh
swift run --scratch-path ~/Library/Caches/vdl-build vdl-cli ping-llm --provider anthropic --base "$ANTHROPIC_BASE_URL" --model claude-haiku-4-5 --token "$ANTHROPIC_AUTH_TOKEN"
swift run --scratch-path ~/Library/Caches/vdl-build vdl-cli ping-llm --provider anthropic --base "$ANTHROPIC_BASE_URL" --model deepseek-v4-flash --token "$ANTHROPIC_AUTH_TOKEN"
swift run --scratch-path ~/Library/Caches/vdl-build vdl-cli ping-llm --provider openai --base https://api.openai.com --model gpt-5.4 --token "$OPENAI_API_KEY"
```

## 目录结构

- `Sources/VDLCore/` — 核心：契约类型（`Models.swift`）、yt-dlp 封装（`Engine.swift`）、页面嗅探（`PageSniffer.swift`）
- `Sources/VideoDownloader/` — SwiftUI 界面
- `Sources/vdl-cli/` — 命令行测试工具

## 已知限制

- 首次写入 `~/Downloads` 时 macOS 会弹一次系统授权询问，允许即可。
- 仅下载你有权访问的公开视频；不绕过任何 DRM 或付费墙。
- 任天堂 `assets.nintendo.com` 直链视频只有原画一档（其 CDN 已禁用转码变体）。
