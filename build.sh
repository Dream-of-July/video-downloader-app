#!/bin/zsh
# 编译并安装 视频下载器.app 到 ~/Applications。
# 注意：本项目位于 iCloud 同步的 ~/Documents 下，构建产物若留在项目内会破坏 codesign，
# 因此 scratch path 与 .app 全部放在 iCloud 之外。
set -euo pipefail

PROJ_DIR="${0:a:h}"
SCRATCH="$HOME/Library/Caches/vdl-build"
APP_NAME="视频下载器"
APP="$HOME/Applications/$APP_NAME.app"

echo "==> swift build (release, scratch: $SCRATCH)"
swift build -c release --package-path "$PROJ_DIR" --scratch-path "$SCRATCH"

BIN="$(swift build -c release --package-path "$PROJ_DIR" --scratch-path "$SCRATCH" --show-bin-path)/VideoDownloader"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VideoDownloader"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>zh_CN</string>
    <key>CFBundleExecutable</key>             <string>VideoDownloader</string>
    <key>CFBundleIdentifier</key>             <string>local.henryxian.video-downloader</string>
    <key>CFBundleName</key>                   <string>视频下载器</string>
    <key>CFBundleDisplayName</key>            <string>视频下载器</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>1.0</string>
    <key>CFBundleVersion</key>                <string>1</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>LSApplicationCategoryType</key>      <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>NSHumanReadableCopyright</key>       <string>本地个人工具</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP"

echo "==> 完成：$APP"
