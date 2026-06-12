#!/bin/zsh
# 编译并安装 视频下载器.app 到 ~/Applications。
# 注意：本项目位于 iCloud 同步的 ~/Documents 下，构建产物若留在项目内会破坏 codesign，
# 因此 scratch path 与 .app 全部放在 iCloud 之外。
set -euo pipefail

PROJ_DIR="${0:a:h}"
SCRATCH="$HOME/Library/Caches/vdl-build"
APP_NAME="视频下载器"
APP="$HOME/Applications/$APP_NAME.app"
ICON_DOC="$PROJ_DIR/$APP_NAME.icon"
ICON_OUT="$SCRATCH/icon-compiled"

echo "==> swift build (release, scratch: $SCRATCH)"
swift build -c release --package-path "$PROJ_DIR" --scratch-path "$SCRATCH"

BIN="$(swift build -c release --package-path "$PROJ_DIR" --scratch-path "$SCRATCH" --show-bin-path)/VideoDownloader"

# Icon Composer 的 .icon 文档每次构建现编译：Assets.car（Tahoe 分层 Liquid Glass）
# + .icns（旧系统/访达列表回退）。actool 不可用时跳过（无图标，不阻塞构建）。
ICON_READY=0
if [[ -d "$ICON_DOC" ]] && xcrun --find actool >/dev/null 2>&1; then
    echo "==> actool 编译图标 $ICON_DOC"
    rm -rf "$ICON_OUT" && mkdir -p "$ICON_OUT"
    if xcrun actool "$ICON_DOC" --compile "$ICON_OUT" \
        --output-format human-readable-text --notices --warnings \
        --platform macosx --minimum-deployment-target 14.0 \
        --app-icon "$APP_NAME" \
        --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null 2>&1; then
        ICON_READY=1
    else
        echo "    （actool 编译失败，跳过图标）"
    fi
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VideoDownloader"
if [[ "$ICON_READY" == 1 ]]; then
    cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/"
    cp "$ICON_OUT/$APP_NAME.icns" "$APP/Contents/Resources/"
fi

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
    <key>CFBundleIconFile</key>               <string>视频下载器</string>
    <key>CFBundleIconName</key>               <string>视频下载器</string>
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
