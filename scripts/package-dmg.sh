#!/bin/bash
set -euo pipefail

# 使用独立临时目录组装镜像，避免将 dist 中的旧包或本机文件混入发行包。
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
app_dir="$project_dir/dist/Lumen.app"
if [[ ! -d "$app_dir" ]]; then
  echo '错误：请先运行 bash scripts/build-app.sh release universal。' >&2
  exit 2
fi
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo '错误：应用版本号格式无效。' >&2
  exit 2
fi
# 包名声明 Universal，必须同时包含两种架构且签名完整。
codesign --verify --strict "$app_dir"
lipo "$app_dir/Contents/MacOS/Lumen" -verify_arch arm64 x86_64
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumen-dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
package="Lumen-v${app_version}-macOS-universal.dmg"
echo "开始制作安装镜像：$package"
ditto "$app_dir" "$staging_dir/Lumen.app"
ln -s /Applications "$staging_dir/Applications"
# 压缩只读 HFS+ 镜像可直接由 Finder 打开；无需额外的打包依赖。
hdiutil create -volname "Lumen $app_version" -srcfolder "$staging_dir" \
  -fs HFS+ -format UDZO -ov "$project_dir/dist/$package"
hdiutil verify "$project_dir/dist/$package"
(cd dist && shasum -a 256 "$package" > "$package.sha256")
echo "安装镜像与校验文件已生成：dist/$package"
