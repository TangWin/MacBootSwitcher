#!/bin/bash
set -euo pipefail

# MacBootSwitcher 原生应用打包脚本
# 将 SPM 构建生成的二进制打包为 macOS 标准的 .app 结构并完成 ad-hoc 签名

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="MacBootSwitcher"
BUILD_DIR="${PROJECT_DIR}/.build/release"
OUTPUT_DIR="${PROJECT_DIR}/dist"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"

echo "==> 正在编译 Release 版本..."
cd "${PROJECT_DIR}"
swift build -c release "$@"

echo "==> 创建 .app 目录结构..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "==> 复制可执行文件..."
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "==> 复制应用图标与资源..."
if [[ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
if [[ -f "${PROJECT_DIR}/Resources/AppIcon.png" ]]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.png" "${APP_BUNDLE}/Contents/Resources/AppIcon.png"
fi

echo "==> 生成 Info.plist..."
cat <<EOF > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.tangw.${APP_NAME}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo "==> 执行 ad-hoc 签名..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> 打包完成：${APP_BUNDLE}"
