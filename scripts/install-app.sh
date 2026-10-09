#!/bin/bash
# 快速更新已安装的应用：只替换主程序、版本信息、界面文案和墙纸切换脚本，其余组件沿用已安装版本。
# 始终使用固定签名身份重签（与 build-app.sh 相同），让辅助功能、文件夹访问等授权在更新后保留。
# 用法：bash scripts/install-app.sh [/Applications/WallpaperUI.app]
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-/Applications/WallpaperUI.app}"
[[ -d "$app/Contents/MacOS" ]] || { echo "未找到已安装的应用：$app（首次安装请使用 build-app.sh）" >&2; exit 1; }

SIGN_ID="${WALLPAPERUI_SIGN_ID:-BA0E30F77944C311DA0454BD80AA9F3B5890505D}"
available_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ "$SIGN_ID" =~ ^[[:xdigit:]]{40}$ ]]; then
    identity_present=$(grep -Fic -- "$SIGN_ID" <<< "$available_identities" || true)
else
    identity_present=$(grep -Fc -- "\"$SIGN_ID\"" <<< "$available_identities" || true)
fi
# Ad-hoc would make macOS treat every update as a new app and drop its permissions.
if [[ "$identity_present" -ne 1 ]]; then
    echo "签名身份 \"$SIGN_ID\" 不可用；为避免授权丢失，未安装。" >&2
    exit 1
fi

swift build -c release --product WallpaperUI
if pgrep -f "$app/Contents/MacOS/WallpaperUI" >/dev/null; then
    osascript -e "tell application \"$app\" to quit"
    for _ in $(seq 1 20); do pgrep -f "$app/Contents/MacOS/WallpaperUI" >/dev/null || break; sleep 1; done
    if pgrep -f "$app/Contents/MacOS/WallpaperUI" >/dev/null; then
        echo "应用仍在退出（可能正在恢复原壁纸），请稍后重试。" >&2
        exit 1
    fi
fi
cp .build/release/WallpaperUI "$app/Contents/MacOS/WallpaperUI"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app/Contents/Resources/"
cp 工具/快速墙纸/wallpaper-switch.py "$app/Contents/Resources/WallpaperSwitch/wallpaper-switch.py"
codesign --force --sign "$SIGN_ID" --identifier local.wallpaper.library "$app"
codesign --verify --deep --strict "$app"
requirement="$(codesign -d -r- "$app" 2>&1 | grep 'designated =>')"
[[ "$requirement" == *'identifier "local.wallpaper.library"'* && "$requirement" == *'certificate root'* ]] || {
    echo "签名要求异常：$requirement" >&2; exit 1; }
printf 'Installed: %s\n%s\n' "$app" "$requirement"
