#!/bin/bash
set -euo pipefail

# 在项目内构建可直接打开的 .app，不修改系统设置或其他客户端工程。
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
build_configuration="${1:-release}"
if [[ "$build_configuration" != "debug" && "$build_configuration" != "release" ]]; then
  echo '用法：bash scripts/build-app.sh [debug|release]' >&2
  exit 2
fi
swift build -c "$build_configuration"
binary_dir="$(swift build -c "$build_configuration" --show-bin-path)"
app_dir="$project_dir/dist/Lumen.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Lumen" "$app_dir/Contents/MacOS/Lumen"
swift scripts/create-icon.swift "$project_dir/.build/Lumen.iconset"
iconutil -c icns "$project_dir/.build/Lumen.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Lumen</string>
  <key>CFBundleDisplayName</key><string>Lumen</string>
  <key>CFBundleIdentifier</key><string>app.lumen.logviewer</string>
  <key>CFBundleExecutable</key><string>Lumen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>CFBundleVersion</key><string>7</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Lumen · 本地 iPhone 日志工作台</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
echo "已构建：$app_dir"
