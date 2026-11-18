#!/usr/bin/env bash
# Build a release configuration and wrap it in an installable DMG.
#
#   ./scripts/make-dmg.sh
#
# Output: dist/DogSC-Dev-<version>-<arch>.dmg
#
# The bundle keeps the development identity ("DogSC Dev", cn.laogou.dogsc.dev)
# so it never shares preferences, permissions or the update feed with an
# installed release build.
set -euo pipefail

cd "$(dirname "$0")/.."
project_root="$PWD"
app_path="$project_root/.build/local/DogSC Dev.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
arch="$(uname -m)"
dist_dir="$project_root/dist"
dmg_path="$dist_dir/DogSC-Dev-$version-$arch.dmg"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "This script requires macOS." >&2
  exit 1
fi

if [[ -d "$app_path" ]] && pgrep -x DogSC >/dev/null; then
  echo "Quit DogSC before packaging; the build script replaces the app bundle." >&2
  exit 1
fi

echo "==> Building release configuration"
DOGSC_BUILD_CONFIGURATION=release bash build-app.sh

if [[ ! -d "$app_path" ]]; then
  echo "Build finished but $app_path is missing." >&2
  exit 1
fi

echo "==> Verifying bundle"
codesign --verify --deep --strict "$app_path"
lipo -archs "$app_path/Contents/MacOS/DogSC"

staging="$(mktemp -d "${TMPDIR:-/tmp/}dogsc-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
root="$staging/DogSC"
mkdir -p "$root"
ditto "$app_path" "$root/DogSC Dev.app"
ln -s /Applications "$root/Applications"

cat > "$root/安装说明.txt" <<'GUIDE'
DogSC（Intel / x86_64 预览版）安装说明
=====================================

一、安装
  1. 把左边的「DogSC Dev.app」拖到右边的 Applications（应用程序）文件夹。
  2. 首次打开会被系统拦下（开发者未经过 Apple 公证），可任选一种方式放行：
     · 右键点应用图标 → 打开 → 在弹窗里再点「打开」；
     · 或到「系统设置 → 隐私与安全性」，页面下方点「仍要打开」。

二、授权（首次启动会引导）
  · 屏幕录制：必需。录屏内容与音频都依赖它。
  · 辅助功能：必需。用于拖动控制条、区域选择与快捷键。
  · 麦克风：按需，只在要录人声时授权。
  · 摄像头：按需，只在要录摄像头画面时授权。
  授权后需要重启一次应用才会生效。

三、这个版本是什么
  · 为 Intel Mac（x86_64）编译，Apple Silicon 机型不需要用它。
  · 采用开发签名（ad-hoc）。应用不会自动更新，也不会与正式版共享偏好与权限
    （应用标识是 cn.laogou.dogsc.dev，与正式版 cn.laogou.dogsc 相互独立）。
  · 每次重新编译安装包，系统授权可能失效，需要重新勾选一遍（见下）。

四、常见问题
  1. 一直停在「准备好录制」引导页
     这是授权记录与应用签名对不上。打开「终端」执行（三行都要）：
         tccutil reset ScreenCapture cn.laogou.dogsc.dev
         tccutil reset Accessibility cn.laogou.dogsc.dev
         tccutil reset Microphone cn.laogou.dogsc.dev
     然后重启应用，重新按引导勾选。

  2. 应用闪退
     崩溃信息会写到：~/Library/Logs/DogSC/crash.log
     把这个文件提供给开发者即可定位。

  3. 录制条挡住了要录的内容
     拖动录制条最右侧的六个点（光标会变成手形），或者拖动它的空白背景。
     位置会被记住，下次沿用。

  4. 摄像头气泡碍事
     直接拖动它。默认停在屏幕右下角，拖到哪就记到哪。

  5. 系统声音录不到
     确认在「设置 → 录制」里打开了系统音频；Intel 机型请勿同时选择 HEVC
     以外的特殊编码组合，若失败可先改用 H.264 试录一段。

GUIDE

mkdir -p "$dist_dir"
rm -f "$dmg_path"
echo "==> Creating $dmg_path"
hdiutil create \
  -volname "DogSC Dev $version" \
  -srcfolder "$root" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$dmg_path" >/dev/null

echo "==> Verifying DMG"
hdiutil verify "$dmg_path" >/dev/null
printf 'DMG: %s (%s)\n' "$dmg_path" "$(du -h "$dmg_path" | awk '{print $1}')"
