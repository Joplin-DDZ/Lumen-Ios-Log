#!/bin/bash
set -euo pipefail

# 在项目内构建可直接打开的 .app，不修改系统设置或其他客户端工程。
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
build_configuration="${1:-release}"
if [[ "$build_configuration" != "debug" && "$build_configuration" != "release" ]]; then
  echo '用法：bash scripts/build-app.sh [debug|release] [native|universal]' >&2
  exit 2
fi
# CI 可构建双架构；本地默认仍只编译当前机器架构。
build_architecture="${2:-native}"
app_version="${LUMEN_VERSION:-1.3.0}"
build_number="${LUMEN_BUILD_NUMBER:-8}"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo '错误：版本必须为三段数字，构建号必须为数字。' >&2
  exit 2
fi
build_arguments=(-c "$build_configuration")
case "$build_architecture" in
  native) ;;
  universal) build_arguments+=(--arch arm64 --arch x86_64) ;;
  *) echo '错误：架构必须为 native 或 universal。' >&2; exit 2 ;;
esac
echo "开始构建：版本=${app_version}，构建号=${build_number}，架构=${build_architecture}"
swift build "${build_arguments[@]}"
binary_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
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
  <key>CFBundleShortVersionString</key><string>1.3.0</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Lumen · 本地 iPhone 日志工作台</string>
</dict></plist>
PLIST
# 通过 plist 工具写入版本，避免将环境变量直接插入 XML。
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
if [[ "$build_architecture" == universal ]]; then
  lipo "$app_dir/Contents/MacOS/Lumen" -verify_arch arm64 x86_64
fi
codesign --verify --strict "$app_dir"
echo "已构建：$app_dir"
