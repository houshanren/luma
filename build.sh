#!/bin/sh
set -eu
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Luma.app"
EXEC="Luma"

swift build -c "$CONFIG" --product PhotosClone
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/PhotosClone"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f Resources/PrivacyInfo.xcprivacy ]; then
    cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
fi
# 网盘产品图标（阿里云盘 / 百度网盘 / 夸克网盘 / 115）。
if [ -d Resources/CloudIcons ]; then
    mkdir -p "$APP/Contents/Resources/CloudIcons"
    cp Resources/CloudIcons/*.png "$APP/Contents/Resources/CloudIcons/"
fi
# 内置女优 / 片商资料库（SQLite）：详情页与标题识别直接读它，不再联网搜索。
if [ -d Resources/Catalog ]; then
    mkdir -p "$APP/Contents/Resources/Catalog"
    cp Resources/Catalog/*.sqlite "$APP/Contents/Resources/Catalog/"
fi
# 只内置轻量小模型（YOLO、地点库）。SigLIP2 由用户在设置里按需下载，
# 避免安装包无谓增加 370MB；开发期 `swift run` 仍会回退读取仓库里的完整模型。
if [ -d Resources/Models ]; then
    mkdir -p "$APP/Contents/Resources/Models"
    for item in Resources/Models/*; do
        case "$(basename "$item")" in
            SigLIP2) continue ;;
        esac
        cp -R "$item" "$APP/Contents/Resources/Models/"
    done
fi
chmod +x "$APP/Contents/MacOS/$EXEC"

# MKV / AVI 等容器系统无法解码，App 内置静态 ffmpeg / ffprobe 负责转封装与抽帧。
# ffmpeg 使用带 libzimg（zscale + tonemap）的静态包：HDR 源转码时能做色调映射，
# 不再依赖用户自行安装 Homebrew ffmpeg。首次构建下载到 Vendor/ffmpeg 并复用（不提交仓库）。
FFMPEG_DIR="Vendor/ffmpeg"
mkdir -p "$FFMPEG_DIR"
case "$(uname -m)" in
    arm64)
        FFMPEG_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/snapshot/ffmpeg.zip"
        FFPROBE_URL="https://registry.npmjs.org/@ffprobe-installer/darwin-arm64/-/darwin-arm64-5.0.1.tgz"
        ;;
    *)
        FFMPEG_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/snapshot/ffmpeg.zip"
        FFPROBE_URL="https://registry.npmjs.org/@ffprobe-installer/darwin-x64/-/darwin-x64-5.1.0.tgz"
        ;;
esac
fetch_ffmpeg() {
    dest="$FFMPEG_DIR/ffmpeg"
    if [ -x "$dest" ]; then
        # 旧静态包不含 zscale：检测到缺滤镜就重新下载，避免发布不具备 HDR 映射能力的包。
        if "$dest" -hide_banner -filters 2>/dev/null | grep -q "zscale"; then return 0; fi
        echo "内置 ffmpeg 缺少 zscale，重新下载…"
        rm -f "$dest"
    fi
    echo "下载内置 ffmpeg …"
    work="$(mktemp -d)"
    if ! curl -fsSL --retry 3 --max-time 900 -o "$work/ffmpeg.zip" "$FFMPEG_URL"; then
        echo "警告：下载 ffmpeg 失败，本次构建不内置（运行时回退系统 ffmpeg）"
        rm -rf "$work"
        return 0
    fi
    unzip -q -o "$work/ffmpeg.zip" -d "$work"
    if [ ! -f "$work/ffmpeg" ]; then
        echo "警告：压缩包内未找到 ffmpeg"
        rm -rf "$work"
        return 0
    fi
    cp "$work/ffmpeg" "$dest"
    chmod +x "$dest"
    rm -rf "$work"
    if ! "$dest" -hide_banner -filters 2>/dev/null | grep -q "zscale"; then
        echo "警告：内置 ffmpeg 不含 zscale，HDR 色调映射将不可用"
    fi
}
fetch_probe() {
    dest="$FFMPEG_DIR/ffprobe"
    if [ -x "$dest" ]; then return 0; fi
    echo "下载内置 ffprobe …"
    work="$(mktemp -d)"
    if ! curl -fsSL --retry 3 --max-time 600 -o "$work/pkg.tgz" "$FFPROBE_URL"; then
        echo "警告：下载 ffprobe 失败，本次构建不内置（运行时回退系统 ffprobe）"
        rm -rf "$work"
        return 0
    fi
    tar -xzf "$work/pkg.tgz" -C "$work"
    cp "$work/package/ffprobe" "$dest"
    chmod +x "$dest"
    rm -rf "$work"
}
fetch_ffmpeg
fetch_probe
if [ -x "$FFMPEG_DIR/ffmpeg" ] && [ -x "$FFMPEG_DIR/ffprobe" ]; then
    mkdir -p "$APP/Contents/Resources/bin"
    cp "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" "$APP/Contents/Resources/bin/"
    chmod +x "$APP/Contents/Resources/bin/ffmpeg" "$APP/Contents/Resources/bin/ffprobe"
fi

# 内置二进制必须先单独签名（hardened runtime 不允许未签名的嵌套可执行文件）。
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
        "$APP/Contents/Resources/bin/ffmpeg" "$APP/Contents/Resources/bin/ffprobe"
else
    codesign --force --sign - "$APP/Contents/Resources/bin/ffmpeg" >/dev/null 2>&1 || true
    codesign --force --sign - "$APP/Contents/Resources/bin/ffprobe" >/dev/null 2>&1 || true
fi

# 固定的本地开发签名身份。
# ad-hoc 签名的身份等于二进制哈希，每次重编译都会变，钥匙串会把新包当成另一个 App
# 反复要求授权；用一张一次生成的自签名证书签名，钥匙串的「始终允许」才能长期有效。
LOCAL_SIGN_IDENTITY="Luma Local Dev"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/LumaDev.keychain-db"
SIGNING_PASS_FILE="$HOME/.luma-signing/pass"

ensure_local_signing() {
    OPENSSL="$(command -v openssl || true)"
    [ -n "$OPENSSL" ] || return 1
    mkdir -p "$HOME/.luma-signing" && chmod 700 "$HOME/.luma-signing"
    if [ ! -f "$SIGNING_PASS_FILE" ]; then
        "$OPENSSL" rand -hex 16 > "$SIGNING_PASS_FILE" || return 1
        chmod 600 "$SIGNING_PASS_FILE"
    fi
    PASS="$(cat "$SIGNING_PASS_FILE")"
    if [ ! -f "$SIGNING_KEYCHAIN" ]; then
        security create-keychain -p "$PASS" "$SIGNING_KEYCHAIN" || return 1
        security unlock-keychain -p "$PASS" "$SIGNING_KEYCHAIN" || return 1
        TMP="$(mktemp -d)"
        cat > "$TMP/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $LOCAL_SIGN_IDENTITY
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
        "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/req.cnf" \
            -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1 \
            || { rm -rf "$TMP"; return 1; }
        if ! "$OPENSSL" pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
                -out "$TMP/id.p12" -passout "pass:$PASS" >/dev/null 2>&1; then
            "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
                -out "$TMP/id.p12" -passout "pass:$PASS" >/dev/null 2>&1 \
                || { rm -rf "$TMP"; return 1; }
        fi
        security import "$TMP/id.p12" -k "$SIGNING_KEYCHAIN" -P "$PASS" \
            -T /usr/bin/codesign >/dev/null || { rm -rf "$TMP"; return 1; }
        security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" \
            "$SIGNING_KEYCHAIN" >/dev/null
        rm -rf "$TMP"
    fi
    security unlock-keychain -p "$PASS" "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || return 1

    # codesign 只从钥匙串搜索列表里找身份：缺了就补上（逐行去掉缩进与引号，保留路径里的空格）。
    if ! security list-keychains -d user | grep -q "LumaDev.keychain-db"; then
        OLD_IFS=$IFS
        IFS='
'
        set --
        for kc in $(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/^"//' -e 's/"$//'); do
            set -- "$@" "$kc"
        done
        IFS=$OLD_IFS
        security list-keychains -d user -s "$@" "$SIGNING_KEYCHAIN"
    fi
    security find-identity -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null \
        | grep -q "$LOCAL_SIGN_IDENTITY"
}

# 有开发者证书时使用 hardened runtime + entitlements；否则用固定本地身份签名。
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp \
        --entitlements Resources/Luma.entitlements \
        --sign "$CODESIGN_IDENTITY" "$APP"
elif ensure_local_signing; then
    codesign --force --deep --sign "$LOCAL_SIGN_IDENTITY" "$APP"
    echo "已用固定本地身份签名（${LOCAL_SIGN_IDENTITY}）：重新编译不再重复弹钥匙串授权"
else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

# 可选：打包 zip。PACKAGE=1 ./build.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 0)"
ZIP="Luma-${VERSION}-macOS.zip"
if [ "${PACKAGE:-0}" = "1" ]; then
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "已打包 $ZIP"
fi

# 可选：公证。需要开发者账号与 app-specific password：
# APPLE_ID=... TEAM_ID=... APP_PASSWORD=... NOTARIZE=1 CODESIGN_IDENTITY="Developer ID Application: ..." ./build.sh
if [ "${NOTARIZE:-0}" = "1" ]; then
    : "${APPLE_ID:?NOTARIZE=1 需要 APPLE_ID}"
    : "${TEAM_ID:?NOTARIZE=1 需要 TEAM_ID}"
    : "${APP_PASSWORD:?NOTARIZE=1 需要 APP_PASSWORD（app-specific password）}"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" \
        --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
    xcrun stapler staple "$APP"
    echo "已公证并装订 $APP"
fi

echo "已生成 $APP"
