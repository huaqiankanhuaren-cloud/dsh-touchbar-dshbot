#!/bin/bash
# 构建 DSHTouchBar.app（arm64 原生，仅需命令行工具）
# 用法: ./build.sh   然后 pkill -x DSHTouchBar 让插件看护重拉
set -e
cd "$(dirname "$0")"

SOURCES=(
  Sources/main.swift
  Sources/BotAvatarView.swift
  Sources/Characters.swift
  Sources/Eyes.swift
  Sources/WhaleGirl.swift
)

echo "==> 编译 (arm64)"
swiftc -O \
  -import-objc-header Sources/TouchBarPrivateApi.h \
  -target arm64-apple-macosx13.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -o DSHTouchBar.app/Contents/MacOS/DSHTouchBar \
  "${SOURCES[@]}"

echo "==> 签名 (ad-hoc)"
codesign --force --deep --sign - DSHTouchBar.app

echo "==> 完成: DSHTouchBar.app"
file DSHTouchBar.app/Contents/MacOS/DSHTouchBar
echo "重启生效: pkill -x DSHTouchBar   (插件会在 5 秒内自动重拉)"
