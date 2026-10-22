#!/bin/bash
# 构建脚本 - 仅使用无证书 ad-hoc 签名，不使用开发者身份或公证

set -euo pipefail

cd "$(dirname "$0")"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/swift-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-/tmp/swift-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

APP_NAME="Mac-TaskManager"
TARGET_NAME="MacTaskManager"
FAN_HELPER_NAME="MacFanHelper"
SYSTEM_HELPER_NAME="MacSystemHelper"
RELEASE_VERSION="$(<VERSION)"
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
    echo "❌ VERSION 文件必须使用 semver 格式，例如 1.0.0 或 1.0.0-beta.2。"
    exit 1
fi
APP_VERSION="${RELEASE_VERSION%%-*}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-$(<BUILD_NUMBER)}"
if [[ ! "$APP_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ BUILD_NUMBER 必须为递增的正整数。" >&2
    exit 1
fi
UPDATE_PUBLIC_KEY="$(<updates/public-key.txt)"

build_app_bundle() {
    local target_arch="${1:-arm64}"
    local app_dir="${2:-./$APP_NAME.app}"

    echo "🔨 正在编译 $APP_NAME ($target_arch)..."

    if ! swift build -c release --arch "$target_arch" --product "$APP_NAME" ||
       ! swift build -c release --arch "$target_arch" --product "$FAN_HELPER_NAME" ||
       ! swift build -c release --arch "$target_arch" --product "$SYSTEM_HELPER_NAME"; then
        cat <<EOF
❌ 编译失败。

当前 xcode-select:
   $(xcode-select -p)

如果错误里出现 SwiftUIMacros，请安装完整 Xcode，或切换到完整 Xcode 工具链:
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

EOF
        exit 1
    fi

    local bin_path
    local helper_path
    bin_path="$(swift build -c release --arch "$target_arch" --show-bin-path)/$APP_NAME"
    helper_path="$(swift build -c release --arch "$target_arch" --show-bin-path)/$FAN_HELPER_NAME"
    # A standalone binary cannot locate the embedded updater framework.
    cat > "./$APP_NAME" <<'LAUNCHER'
#!/bin/bash
exec /usr/bin/open "$(cd "$(dirname "$0")" && pwd)/Mac-TaskManager.app" --args "$@"
LAUNCHER
    chmod 755 "./$APP_NAME"

    rm -rf "$app_dir"
    mkdir -p \
        "$app_dir/Contents/MacOS" \
        "$app_dir/Contents/Resources" \
        "$app_dir/Contents/Frameworks"
    cp "$bin_path" "$app_dir/Contents/MacOS/$APP_NAME"
    cp "$helper_path" "$app_dir/Contents/Resources/$FAN_HELPER_NAME"
    cp "$(dirname "$helper_path")/$SYSTEM_HELPER_NAME" "$app_dir/Contents/Resources/$SYSTEM_HELPER_NAME"
    chmod 755 "$app_dir/Contents/Resources/$FAN_HELPER_NAME"
    chmod 755 "$app_dir/Contents/Resources/$SYSTEM_HELPER_NAME"
    cp assets/app-icon.svg "$app_dir/Contents/Resources/app-icon.svg"
    cp assets/app-icon.png "$app_dir/Contents/Resources/app-icon.png"
    cp THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
    cp licenses/Sparkle-LICENSE "$app_dir/Contents/Resources/Sparkle-LICENSE"
    local sparkle_source=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    local sparkle_framework="$app_dir/Contents/Frameworks/Sparkle.framework"
    ditto "$sparkle_source" "$sparkle_framework"

    cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Mac-TaskManager</string>
    <key>CFBundleExecutable</key>
    <string>Mac-TaskManager</string>
    <key>CFBundleIconFile</key>
    <string>app-icon.png</string>
    <key>CFBundleIdentifier</key>
    <string>local.Mac-TaskManager</string>
    <key>CFBundleName</key>
    <string>Mac-TaskManager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://github.com/Flashhhhhhzj/mac-task-manager/releases/latest/download/appcast-arm64.xml</string>
    <key>SUPublicEDKey</key>
    <string>$UPDATE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUSendProfileInfo</key>
    <false/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>SURequireSignedFeed</key>
    <true/>
</dict>
</plist>
EOF

    plutil -lint "$app_dir/Contents/Info.plist"

    # 从内到外封装，所有可执行文件均使用本机 ad-hoc 签名。
    codesign --force --sign - --timestamp=none "$sparkle_framework/Versions/B/Autoupdate"
    codesign --force --sign - --timestamp=none "$sparkle_framework/Versions/B/Updater.app"
    codesign --force --sign - --timestamp=none "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --sign - --timestamp=none "$sparkle_framework/Versions/B/XPCServices/Installer.xpc"
    codesign --force --sign - --timestamp=none "$sparkle_framework"
    codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/$FAN_HELPER_NAME"
    codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/$SYSTEM_HELPER_NAME"
    codesign --force --sign - --timestamp=none "$app_dir"
    codesign --verify --deep --strict --verbose=2 "$app_dir"

    echo "✅ [$target_arch] 编译与打包完成（ad-hoc 签名，无开发者证书）: $app_dir"
    echo "ℹ️ 首次打开应用后，点击“启用完整功能”并完成系统管理员授权即可配置风扇与系统管理服务。"
}

create_dmg_package() {
    local app_dir="$1"
    local dmg_path="$2"

    local dist_dir
    dist_dir="$(dirname "$dmg_path")"
    mkdir -p "$dist_dir"
    local volume_name="$APP_NAME-Layout-$$"

    local work_dir
    work_dir="$(mktemp -d "$dist_dir/.dmg-work.XXXXXX")"
    local dmg_root="$work_dir/root"
    local writable_dmg="$work_dir/writable.dmg"
    local mountpoint
    local volume_device
    local attach_output
    mkdir -p "$dmg_root/.background"
    cp -R "$app_dir" "$dmg_root/$APP_NAME.app"
    ln -s /Applications "$dmg_root/Applications"
    cp assets/dmg-background.png "$dmg_root/.background/dmg-background.png"

    rm -f "$dmg_path"
    hdiutil create \
        -volname "$volume_name" \
        -srcfolder "$dmg_root" \
        -fs HFS+ \
        -ov \
        -format UDRW \
        "$writable_dmg"

    attach_output="$(hdiutil attach \
        -readwrite \
        -noverify \
        -noautoopen \
        "$writable_dmg")"
    volume_device="$(printf '%s\n' "$attach_output" | awk '$2 == "Apple_HFS" { print $1; exit }')"
    mountpoint="$(printf '%s\n' "$attach_output" | awk '$2 == "Apple_HFS" { $1 = ""; $2 = ""; sub(/^[[:space:]]+/, ""); print; exit }')"
    if [ -z "$volume_device" ] || [ -z "$mountpoint" ]; then
        echo "❌ 无法找到刚挂载的 DMG 卷。" >&2
        rm -rf "$work_dir"
        return 1
    fi

    if ! osascript - "$volume_name" "$mountpoint" <<'APPLESCRIPT'
on run argv
    set diskName to item 1 of argv
    set mountDir to item 2 of argv
    tell application "Finder"
    set dmgDisk to disk (diskName as string)
    open dmgDisk
    set xOrigin to 100
    set yOrigin to 100
    set windowWidth to 560
    set windowHeight to 400
    set dmgWindow to container window of dmgDisk
    set current view of dmgWindow to icon view
    set toolbar visible of dmgWindow to false
    set statusbar visible of dmgWindow to false
    set pathbar visible of dmgWindow to false
    set bounds of dmgWindow to {xOrigin, yOrigin, xOrigin + windowWidth, yOrigin + windowHeight}
    set viewOptions to icon view options of dmgWindow
    set icon size of viewOptions to 96
    set text size of viewOptions to 12
    set arrangement of viewOptions to not arranged
    set background picture of viewOptions to file ".background:dmg-background.png" of dmgDisk
    set position of item "Mac-TaskManager.app" of dmgWindow to {150, 170}
    set position of item "Applications" of dmgWindow to {410, 170}
    close dmgWindow
    open dmgDisk
    delay 1
    set dmgWindow to container window of dmgDisk
    set statusbar visible of dmgWindow to false
    set pathbar visible of dmgWindow to false
    set bounds of dmgWindow to {xOrigin, yOrigin, xOrigin + windowWidth - 10, yOrigin + windowHeight - 10}
    delay 1
    set statusbar visible of dmgWindow to false
    set pathbar visible of dmgWindow to false
    set bounds of dmgWindow to {xOrigin, yOrigin, xOrigin + windowWidth, yOrigin + windowHeight}
    delay 3
    end tell
set dsStore to quoted form of (mountDir & "/.DS_Store")
repeat 10 times
    if (do shell script "test -s " & dsStore & "; echo $?") is "0" then return
    delay 1
end repeat
error "Finder did not create the DMG layout metadata."
end run
APPLESCRIPT
    then
        hdiutil detach "$volume_device" -quiet || true
        rm -rf "$work_dir"
        return 1
    fi

    diskutil rename "$volume_device" "$APP_NAME"
    hdiutil detach "$volume_device" -quiet
    hdiutil convert "$writable_dmg" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -ov \
        -o "$dmg_path"
    rm -rf "$work_dir"

    scripts/verify-macos-dmg-finder-layout.sh "$dmg_path"

    echo "💿 DMG（内含 ad-hoc App，未公证）: $dmg_path"
}

rm -rf ./MacSystemMonitor ./MacSystemMonitor.app ./MacTaskManager ./MacTaskManager.app

if [ "${1:-}" = "dmg" ]; then
    ARCH_TARGET="${2:-all}"
    DIST_DIR="./dist"
    mkdir -p "$DIST_DIR"

    if [ "$ARCH_TARGET" = "all" ] || [ "$ARCH_TARGET" = "arm64" ]; then
        build_app_bundle "arm64" "./$APP_NAME.app"
        VERSIONED_ARM64="$DIST_DIR/$APP_NAME-v$RELEASE_VERSION-arm64.dmg"
        create_dmg_package "./$APP_NAME.app" "$VERSIONED_ARM64"
    fi

    if [ "$ARCH_TARGET" = "all" ] || [ "$ARCH_TARGET" = "x64" ] || [ "$ARCH_TARGET" = "x86_64" ]; then
        X64_APP_DIR="./$APP_NAME-x64.app"
        build_app_bundle "x86_64" "$X64_APP_DIR"
        VERSIONED_X64="$DIST_DIR/$APP_NAME-v$RELEASE_VERSION-x64.dmg"
        create_dmg_package "$X64_APP_DIR" "$VERSIONED_X64"
        rm -rf "$X64_APP_DIR"
    fi

    echo ""
    echo "🎉 所有指定架构 DMG 打包完成！"
    exit 0
fi

# 默认构建本机架构
build_app_bundle "arm64" "./$APP_NAME.app"

echo "✅ 编译完成"
echo ""
echo "运行: ./$APP_NAME"
echo "应用: open $APP_NAME.app"
echo ""

if [ "${1:-}" = "run" ]; then
    # Reuse the existing application instance. `open -n` launches multiple
    # copies of the same bundle, which creates competing status-bar items.
    open "./$APP_NAME.app"
fi
