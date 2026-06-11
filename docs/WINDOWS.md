# Windows 适配说明

本项目核心层（`VDLCore`）与命令行工具（`vdl-cli`）已做 Windows 条件编译适配；
SwiftUI 图形界面（`VideoDownloader`）依赖 AppKit/WebKit，**仅 macOS 可用**，
Windows 上 SPM 会自动跳过该 target（见 `Package.swift`）。

> ⚠️ **状态：未在真实 Windows 机器上验证。** 本适配在 macOS 上完成（条件编译分支
> 无法在 mac 上编译验证），首次在 Windows 构建时可能需要少量修正。
> 下方「已知差异」如实列出了平台能力差距。

## 构建步骤

1. 安装 Swift for Windows 工具链（https://swift.org/install/windows/ ，
   含 Visual Studio Build Tools 依赖，按官方指引走完）。
2. 安装运行依赖并确保在 PATH 里（推荐 winget 或 scoop）：

   ```powershell
   winget install yt-dlp.yt-dlp
   winget install Gyan.FFmpeg          # full 构建，自带 libass（烧录字幕必需）
   winget install DenoLand.Deno        # yt-dlp 解 YouTube n-challenge 需要 JS 运行时
   ```

3. 构建 CLI：

   ```powershell
   swift build -c release --target vdl-cli
   ```

4. 使用方式与 macOS 相同（见 README 的 vdl-cli 用法）：
   `resolve` / `analyze` / `download` / `translate` / `clean-srt` / `burn` / `ping-llm`。

## 已知平台差异

| 能力 | macOS | Windows |
|---|---|---|
| 图形界面 / 队列 / 站点登录（WKWebView） | ✅ | ❌ 仅 CLI |
| 任务暂停/恢复（SIGSTOP/SIGCONT 进程树） | ✅ | ❌ 不支持（占位 no-op）；翻译阶段的暂停闸门仍有效 |
| 取消（终止进程树） | SIGINT → 3s SIGKILL | `taskkill /T /F`（无优雅中断，直接终止） |
| 二进制定位 | Homebrew 目录优先 | 沿 PATH 找 `*.exe`（`VDL_YTDLP_PATH` 等环境变量仍可覆盖） |
| 凭证文件权限（settings.json / cookies.txt 0600） | ✅ | ❌ 无 POSIX 权限位，仅依赖用户目录 ACL；多人共用机器请自行加固（如 EFS/DPAPI） |
| 烧录中文字体 | 苹方（PingFang SC） | 微软雅黑（Microsoft YaHei） |
| 停滞看门狗 / 并发翻译 / 字幕清洗 | ✅ | ✅（纯 Foundation 实现） |

## 适配实现位置

- `Sources/VDLCore/TaskControl.swift` — 信号常量占位 + `signalTree` 的 taskkill 分支
- `Sources/VDLCore/Engine.swift` — `locateBinary` / `subprocessEnvironment` 的 PATH 分支、进程终止抽象
- `Sources/VDLCore/Burner.swift` — ffmpeg 定位与中文字体的平台分支
- `Sources/VDLCore/Settings.swift`、`CookieFile.swift` — 文件权限属性的平台守卫
- `Package.swift` — Windows 上排除 GUI target
