# MacBootSwitcher

本机使用的 macOS 一次性启动切换工具：选择系统 → 按需认证 → 设置下一次启动 → 请求正常重启。**不修改默认启动盘或安全设置。**

当前状态（2026-10-03）：已修复身份、执行器、互斥及 UI 状态问题，保留当前步骤、耗时和脱敏事件日志。窗口可调整大小，确认与拥有者认证合为一页，失败/未知结果分别呈现，返回或刷新保留本次会话的临时状态提醒。5 个套件、38 项测试通过。管理员授权与 owner 认证的完整交互、真实一次性写入、正常重启和两次启动仍待 89 安排窗口验收；测试通过不代表实际切换已验证。

## 执行模型阅读顺序

1. [项目规则](AGENTS.md)
2. [最小版架构设计](docs/architecture.md)
3. [实现计划](docs/implementation-plan.md)
4. [验证记录](docs/validation.md)
5. [历史可行性调查](FEASIBILITY.md)：只参考证据，其中原完整版的撤销门槛已废止。

## 目录结构

```text
MacBootSwitcher/
├── AGENTS.md                  # 项目规则与执行边界
├── README.md                  # 项目入口与操作说明
├── FEASIBILITY.md             # 保留的历史调查，非当前需求
├── Package.swift              # Swift Package Manager 工程配置
├── docs/
│   ├── architecture.md        # 最小版范围、模块与交互
│   ├── implementation-plan.md # 分阶段任务与出口条件
│   └── validation.md          # 详细验证记录与实机验收方案
├── Sources/MacBootSwitcher/
│   ├── App/                   # SwiftUI 窗口与应用入口 (MacBootSwitcherApp, ContentView)
│   ├── Discovery/             # 系统扫描、APFS 卷组去重与稳定身份 (DiskutilScanner, SystemCandidate)
│   ├── Workflow/              # 操作协调与状态转换 (SwitchWorkflow)
│   ├── Boot/                  # 一次性启动及认证适配 (BlessBootSetter, CommandExecutor)
│   └── Restart/               # 正常重启适配 (SystemRestarter)
├── Tests/MacBootSwitcherTests/
│   ├── Fixtures/              # 脱敏磁盘样例 (two_systems.plist)
│   └── MacBootSwitcherTests.swift # 真实解析、无害进程及模拟写入边界测试
└── scripts/
    ├── build-app.sh           # Release 构建与 .app 打包签名脚本
    └── check-status.sh        # 只读系统启动与 APFS 状态检查脚本
```

## 真实命令与操作指南

### 1. 构建与编译

项目基于纯 Swift Package Manager 构建，无需独立安装 Xcode.app（支持 Command Line Tools）：

```bash
# Debug 编译
swift build

# Release 优化编译
swift build -c release
```

### 2. 运行自动化测试

扫描使用真实解析器与脱敏 fixture；执行器测试运行非特权 `sh/head/sleep/cat/printf`。启动写入和重启边界使用模拟执行器，**不会调用真实 bless 写入或重启机器**。当前 CLT 环境通过脚本加载 TestingMacros：

```bash
./scripts/run-tests.sh
```

当前执行结果：5 个测试套件，38 个测试用例全部通过。环境和命令限制详见 [验证记录](docs/validation.md)。

### 3. 应用打包与签名

使用提供的脚本将产物组装为 macOS 标准应用程序并执行本地 ad-hoc 签名：

```bash
./scripts/build-app.sh
```

打包产物位于 `dist/MacBootSwitcher.app`。

### 4. 运行应用

可以通过终端直接运行或在 Finder 中打开：

```bash
# 方式一：直接运行二进制
./dist/MacBootSwitcher.app/Contents/MacOS/MacBootSwitcher

# 方式二：通过 open 命令启动窗口
open dist/MacBootSwitcher.app
```

### 5. 只读系统状态检查

可运行只读检查脚本查看系统工具报告的启动设备与 APFS 卷组；不能把单项 `bless --getBoot` 输出解释为一次性目标读回或持久默认未变的完整证明：

```bash
./scripts/check-status.sh
```

### 6. 清理与卸载

```bash
# 清理构建产物与打包目录
rm -rf .build dist

```

受限执行侧使用 root 拥有的固定锁文件；操作结束时自动释放 `flock`。不要删除锁文件来解除占用，否则可能破坏并发保护。应用退出不代表撤销已提交的启动选择。

## 关键安全与操作边界

1. **仅设置下一次启动**：程序底层严格使用 `bless --mount <dir> --setBoot --nextonly`，绝不修改持久默认启动磁盘，不调用任何修改默认盘的接口。
2. **密码传递**：owner 输入通过本次 Unix socket 发送给核验过 UID 的 root 执行侧，再通过 stdin 传给固定 `bless` 命令。参数、普通临时文件和诊断不包含密码；使用后清空应用持有的引用，不保证 Swift 字符串副本已从内存擦除。管理员授权与 owner 认证分别处理。
3. **正常重启与取消**：调用 AppleScript 发起正常重启，系统会提示未保存文档并允许用户取消。若取消重启，临时选择可能仍然有效；**本版本不提供撤销功能**。
4. **不可作为可启动保证**：扫描到候选系统仅表示发现合法的 APFS 系统卷组，不构成目标系统绝对可正常启动的保证。
5. **进展与等待**：扫描显示实际子步骤和候选核对数量；执行显示检查、授权、重新核验、设置、正常重启请求及阶段耗时。事件日志只记录固定阶段与结果，不显示原始系统输出。授权和系统服务耗时仍可能较长，不提供虚构的完成百分比。
6. **确认与返回**：选择目标后点击“继续…”，在同一页核对目标、风险和拥有者账户，点击“认证并重启”后才进入系统管理员授权。取消或 Esc 会清空密码引用；返回列表、刷新或取消新操作不撤销已有启动选择。提醒仅属于本次会话，不代表已查询实际一次性目标；退出后重开不推断其状态。

本轮根因、修复映射和限制见 [批量修复记录](docs/reviews/2026-10-03-fix-results.md)；[原对抗性审查](docs/reviews/2026-10-03-adversarial-review.md) 保留为修复前快照。
