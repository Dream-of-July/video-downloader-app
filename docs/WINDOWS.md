# Windows 版说明

Windows 版是一个独立的原生实现，位于 `windows/`：

- **VdlCore**（C#，.NET 10）— 从 Swift 版 `VDLCore` + `QueueManager` 逐行为基准移植的核心库：
  yt-dlp 封装、字幕解析/清洗/翻译、ffmpeg 烧录、队列与并发槽位、暂停/取消、设置与 cookies。
  附 144 个单元测试，在 macOS 上即可全量运行。
- **VdlApp**（WPF）— 与 macOS 版同结构、同文案的图形界面：粘贴解析（含多链接批量入队）、
  画质/字幕选择、中文字幕翻译+烧录、队列（每任务独立暂停/取消/重试）、设置（协议选择、
  拉取模型、并发数、烧录上限）、WebView2 站点登录、首次启动自动下载依赖。
- **installer/installer.nsi**（NSIS）— 安装器：双击安装、无需管理员权限（装入
  `%LOCALAPPDATA%\Programs\视频下载器`）、开始菜单/桌面快捷方式、控制面板可卸载。

> ⚠️ **状态：GUI 与安装器未在真实 Windows 机器上运行验证。**
> 全部代码在 macOS 上交叉编译通过、核心逻辑有单测覆盖，但 WPF 界面、进程树挂起
> （NtSuspendProcess）、依赖自动下载、WebView2 登录属于运行时行为，首次真机使用
> 可能需要一轮修正。发现问题带截图/报错回来即可。

## 在 macOS 上构建安装器

依赖（一次性）：`brew install dotnet makensis`

```bash
./build-windows.sh            # 输出 ~/Downloads/视频下载器-Windows-Setup.exe
```

脚本流程：核心库单测（必须全绿）→ `dotnet publish` win-x64 自包含（用户机器无需装
.NET）→ NSIS 打包。

## Windows 用户侧体验

1. 双击 `视频下载器-Windows-Setup.exe` → 选目录 → 安装（无 UAC 弹窗）。
2. 首次启动自动从官方源下载 yt-dlp / ffmpeg（BtbN full 构建，含 libass）/ deno
   到 `%LOCALAPPDATA%\VideoDownloader\bin`（需联网；设置里可重新下载、单独更新 yt-dlp）。
3. 之后与 macOS 版一致：粘贴链接 → 选画质字幕 → 下载/翻译/烧录，多文件任务自动建文件夹。
4. 站点登录走 WebView2（Win 11 自带运行时；缺失时 App 会引导安装）。
5. 卸载：设置 → 应用 → 视频下载器。已下载的依赖与设置保留在
   `%LOCALAPPDATA%\VideoDownloader`，彻底清理需手动删除该目录。

## 已知平台差异

| 能力 | macOS | Windows |
|---|---|---|
| 任务暂停/恢复 | SIGSTOP/SIGCONT 进程树 | NtSuspendProcess/NtResumeProcess 进程树（未真机验证） |
| 取消 | SIGINT → 3s SIGKILL | `Process.Kill` 整树直接终止（无优雅中断，靠 .part 清理兜底） |
| 依赖来源 | Homebrew（手动） | 首启自动下载官方构建 |
| 凭证文件权限 | 0600 | 无 POSIX 权限位，依赖用户目录 ACL |
| 烧录中文字体 | 苹方 | 微软雅黑 |
| 站点登录 | WKWebView | WebView2（需 Edge WebView2 运行时） |

## 旧的 Swift 条件编译适配

`Sources/VDLCore` 里的 `#if os(Windows)` 分支（taskkill、PATH 定位等）仍保留，
理论上可在 Windows 上用 Swift 工具链构建 `vdl-cli` 命令行版，但 GUI 路线已由
`windows/` 的 C# 实现取代，Swift 分支不再继续投入。
