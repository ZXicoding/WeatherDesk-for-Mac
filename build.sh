#!/bin/bash
# 天气桌面 for Mac —— 原生 AppKit 构建脚本
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd .. && pwd)"
APP="$ROOT/天气桌面.app"
BUILD="$(mktemp -d /tmp/weatherdesk-build.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

FRAMEWORKS=(-framework AppKit -framework CoreLocation -framework ServiceManagement -framework QuartzCore -framework CoreGraphics -framework Network)

echo "▸ 编译 Swift 源码"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  "${FRAMEWORKS[@]}" \
  -o "$APP/Contents/MacOS/WeatherDesk" \
  Sources/*.swift

echo "▸ 生成应用图标"
mkdir -p "$BUILD/AppIcon.iconset"
swiftc -O -swift-version 5 -parse-as-library -o "$BUILD/iconmaker" tools/IconMaker.swift
"$BUILD/iconmaker" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ 打包实景照片与生态带照片包"
cp Resources/photos/*.jpg "$APP/Contents/Resources/"
cp Resources/图片来源.txt "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/biomes"
cp -R Resources/biomes "$APP/Contents/Resources/"
echo "   $(find Resources/biomes -name '*.jpg' | wc -l | tr -d ' ') 张生态带照片"

echo "▸ 签名（优先用稳定的开发者证书，避免 ad-hoc 身份漂移）"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development:.*\)".*/\1/p' | head -1)"
# 无图形会话时，证书签名可能一直卡在「允许访问钥匙串」授权弹窗。
# 加 25 秒超时，超时即回退 ad-hoc，保证构建不会挂死。
sign_with_timeout() {
  python3 - "$1" "$2" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(
        ["codesign", "--force", "--deep", "--sign", sys.argv[1], sys.argv[2]],
        timeout=25).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
}
SIGNED=0
if [[ -n "$IDENTITY" ]]; then
  echo "   使用：$IDENTITY"
  if sign_with_timeout "$IDENTITY" "$APP"; then
    SIGNED=1
  else
    echo "   ⚠ 开发者证书签名失败或等待钥匙串授权超时，回退 ad-hoc"
  fi
else
  echo "   ⚠ 未找到开发者证书，使用 ad-hoc"
fi
if [[ "$SIGNED" != "1" ]]; then
  codesign --force --deep --sign - "$APP" || true
fi
# 从 zip 解压安装包会带 com.apple.quarantine，不清除会被 Gatekeeper 判为「已损坏」
xattr -cr "$APP" 2>/dev/null || true
codesign -dv "$APP" 2>&1 | grep -E "Signature|TeamIdentifier" || true

if [[ "${1:-}" == "--verify" ]]; then
  echo "▸ 数据层自检"
  swiftc -O -swift-version 5 \
    -target arm64-apple-macos13.0 \
    "${FRAMEWORKS[@]}" \
    -o "$BUILD/verify" \
    Sources/Settings.swift Sources/WeatherModel.swift Sources/WeatherService.swift \
    Sources/StarCatalog.swift Sources/Astronomy.swift Sources/LiveCamCatalog.swift \
    Sources/SceneClock.swift \
    tools/verify.swift
  "$BUILD/verify"
fi

if [[ "${1:-}" == "--preview" ]]; then
  echo "▸ 生成九格效果预览图"
  cp tools/preview.swift "$BUILD/main.swift"
  cp Sources/Settings.swift Sources/WeatherModel.swift \
     Sources/TextureFactory.swift Sources/SkyView.swift Sources/SkyStars.swift \
     Sources/EcoScene.swift Sources/LiveCam.swift Sources/LiveCamCatalog.swift \
     Sources/StarCatalog.swift Sources/Astronomy.swift Sources/SceneClock.swift "$BUILD/"
  swiftc -O -swift-version 5 \
    -target arm64-apple-macos13.0 \
    "${FRAMEWORKS[@]}" \
    -o "$BUILD/preview" \
    "$BUILD"/*.swift
  "$BUILD/preview" "$ROOT/天气桌面-效果预览.png"
fi

echo "✓ 完成：$APP"
