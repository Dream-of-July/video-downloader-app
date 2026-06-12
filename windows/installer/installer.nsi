; 视频下载器 Windows 安装器（NSIS，在 macOS 上用 brew 的 makensis 交叉构建）
; 设计目标：双击即装、无需管理员权限（装到当前用户目录）、开始菜单/桌面快捷方式、可卸载。
; 构建参数（由 build-windows.sh 传入）：
;   /DPUBLISH_DIR=<dotnet publish 输出目录>  /DOUTFILE=<安装器输出路径>  /DAPPVERSION=<版本>

Unicode true
!include "MUI2.nsh"
!include "FileFunc.nsh"

!ifndef APPVERSION
  !define APPVERSION "1.0.0"
!endif

!define APPNAME "视频下载器"
!define EXENAME "VideoDownloader.exe"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\VideoDownloader"

Name "${APPNAME}"
OutFile "${OUTFILE}"
; 每用户安装，免 UAC 弹窗（与“允许用户直接安装”的诉求一致）
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
SetCompressor /SOLID lzma

!define MUI_ICON "${__FILEDIR__}\..\assets\app.ico"
!define MUI_UNICON "${__FILEDIR__}\..\assets\app.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXENAME}"
!define MUI_FINISHPAGE_RUN_TEXT "立即运行 ${APPNAME}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "安装"
  SetOutPath "$INSTDIR"
  File /r "${PUBLISH_DIR}\*"

  ; 快捷方式
  CreateShortCut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\${EXENAME}"
  CreateShortCut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\${EXENAME}"

  ; 卸载信息（当前用户注册表，控制面板可见）
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${APPVERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\${EXENAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "本地个人工具"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
  ; EstimatedSize 单位 KB
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINSTKEY}" "EstimatedSize" "$0"
SectionEnd

Section "Uninstall"
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  Delete "$DESKTOP\${APPNAME}.lnk"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "${UNINSTKEY}"
  ; 注意：刻意保留 %LOCALAPPDATA%\VideoDownloader（下载的 yt-dlp/ffmpeg 与设置），
  ; 重装无需重新下载依赖；用户想彻底清理可手动删除该目录。
SectionEnd
