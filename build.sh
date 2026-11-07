#!/bin/bash
# 天气桌面 for Mac —— 原生 AppKit 构建脚本
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd .. && pwd)"
APP="$ROOT/天气桌面.app"
BUILD="$(mktemp -d /tmp/weatherdesk-build.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

FRAMEWORKS=(-framework AppKit -framework CoreLocation -framework ServiceManagement -framework QuartzCore -framework CoreGraphics)

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

echo "▸ 准备雨声素材（如缺失则离线合成）"
if [ ! -f "Resources/rain-light.wav" ] || [ ! -f "Resources/rain-mid.wav" ] || [ ! -f "Resources/rain-heavy.wav" ]; then
  python3 tools/make_rain_sound.py
fi
cp Resources/rain-light.wav Resources/rain-mid.wav Resources/rain-heavy.wav "$APP/Contents/Resources/"

echo "▸ 打包实景照片"
cp Resources/photos/*.jpg "$APP/Contents/Resources/"

echo "▸ 签名"
codesign --force --deep --sign - "$APP" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

if [[ "${1:-}" == "--verify" ]]; then
  echo "▸ 数据层自检"
  swiftc -O -swift-version 5 \
    -target arm64-apple-macos13.0 \
    "${FRAMEWORKS[@]}" \
    -o "$BUILD/verify" \
    Sources/Settings.swift Sources/WeatherModel.swift Sources/WeatherService.swift \
    Sources/StarCatalog.swift Sources/Astronomy.swift tools/verify.swift
  "$BUILD/verify"
fi

if [[ "${1:-}" == "--preview" ]]; then
  echo "▸ 生成九格效果预览图"
  cp tools/preview.swift "$BUILD/main.swift"
  cp Sources/Settings.swift Sources/WeatherModel.swift \
     Sources/TextureFactory.swift Sources/SkyView.swift Sources/SkyStars.swift \
     Sources/StarCatalog.swift Sources/Astronomy.swift "$BUILD/"
  swiftc -O -swift-version 5 \
    -target arm64-apple-macos13.0 \
    "${FRAMEWORKS[@]}" \
    -o "$BUILD/preview" \
    "$BUILD"/*.swift
  "$BUILD/preview" "$ROOT/天气桌面-效果预览.png"
fi

echo "✓ 完成：$APP"
