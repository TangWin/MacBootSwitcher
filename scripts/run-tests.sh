#!/bin/bash
set -euo pipefail

# MacBootSwitcher 自动化测试执行脚本
# 在 Command Line Tools 环境下显式指定 TestingMacros 宏插件路径以运行 Swift Testing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTING_MACRO="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

cd "${PROJECT_DIR}"

# 运行测试并传递宏插件路径
swift test -Xswiftc -load-plugin-library -Xswiftc "${TESTING_MACRO}" "$@"
