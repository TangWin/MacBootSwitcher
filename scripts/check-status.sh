#!/bin/bash
set -euo pipefail

# MacBootSwitcher 只读状态检查脚本
# 仅读取当前系统的启动盘配置、APFS 卷组及 bless 输出，不执行任何写操作。

echo "=========================================="
echo " MacBootSwitcher 只读系统启动状态报告"
echo "=========================================="

echo ""
echo "--- 1. 当前环境 ---"
echo "架构: $(uname -m)"
echo "系统版本: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "当前用户: $(whoami)"

echo ""
echo "--- 2. 当前运行系统根卷信息 ---"
/usr/sbin/diskutil info / | grep -E "Volume Name|Volume UUID|APFS Volume Group|FileVault|Internal|Mount Point" || true

echo ""
echo "--- 3. 当前选中的启动设备 (bless --getBoot) ---"
/usr/sbin/bless --getBoot --plist

echo ""
echo "--- 4. APFS 卷组列表 ---"
/usr/sbin/diskutil apfs listVolumeGroups

echo ""
echo "=========================================="
echo " 报告结束（未执行任何启动配置修改）"
echo "=========================================="
