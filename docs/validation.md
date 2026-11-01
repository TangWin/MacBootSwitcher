# 验证记录

## 2026-10-03 UI 与交互修复

- 修复结果分类：扫描失败、设置失败、设置未知、重启请求已提交、重启请求失败与重启结果未知分别呈现。执行和结果显示冻结的目标上下文，重启失败/未知不使用成功配色。
- 临时状态提醒仅记录本次会话反馈。工具成功、写入阶段失败或设置未知后，返回、刷新、扫描失败、取消新操作及新的写入前拒绝均保留提醒；不持久化，也不查询或推断实际一次性目标。
- 合并确认与拥有者认证为一张页，补齐账户/密码标签、两种认证说明、不可选原因、打开磁盘工具的辅助入口、键盘选择与刷新快捷键。单窗口允许调整大小，列表和长说明可滚动，操作记录默认折叠。
- **Debug 编译与真实执行测试**：`./scripts/run-tests.sh --scratch-path /private/tmp/MacBootSwitcher-ui-build --disable-sandbox`，环境变量 `CLANG_MODULE_CACHE_PATH=/private/tmp/MacBootSwitcher-ui-clang`、`SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/MacBootSwitcher-ui-swift`。5 个 Suite、**38 项测试全部通过**；最终流程版本增量编译 4.55 秒，测试 0.422 秒。新增 4 项回归测试覆盖扫描失败分类、取消清空密码/再次确认、未知提醒跨导航/扫描失败/取消保留，以及写入前后失败的区别；扩展既有测试检查重启结果类别及刷新提醒。真实启动设置和重启仍使用 mock。
- **最终增量回归**：补齐候选焦点、辅助功能角色及提醒中的目标短标识后，以相同缓存环境执行 `--filter WorkflowTests`，9 项流程测试通过（0.006 秒）。此前完整 38 项测试的数量与本次局部回归分别计数，不合并成 47 个不同用例。
- **Release 构建**：沙箱内编译在 `GenerateDSYMFile` 被 `Operation not permitted` 拦截；执行环境审批后，完成本地构建、打包和 ad-hoc 签名。最终增量 Release 构建 6.06 秒，`codesign --verify --deep --strict` 通过，`Info.plist` lint 通过。未安装应用、helper 或其他软件。
- **原生只读界面检查**：检查本机扫描后的目标选择、深色确认页布局、空密码禁用提交、密码框初始焦点、展开说明与固定操作按钮。辅助功能检查发现候选角色缺失后补齐按钮角色，并重新核对其角色为按钮、包含目标身份和选择状态。补齐列表初始焦点后，方向键选择、Return 打开确认页、Esc 取消并恢复列表焦点、Cmd-R 刷新并清空选择均实测通过。不输入密码，不提交拥有者或管理员认证，不调用启动写入或重启。
- **未验证**：真实管理员授权、拥有者认证、写入、正常重启与两次启动；VoiceOver 的实际朗读、浅色外观、最小窗口及长名称/大量候选的完整视觉验收。状态提醒/错误页通过模拟流程测试，未在真机制造写入失败或未知。

本轮打包和界面最终检查以此节为准。下节保留 UI 修复前的审查/进展验证快照，其中历史 34 项不代表本轮测试数量。

## 2026-10-03 审查与进展修复记录（UI 修复前）

本批根据对抗性审查与“整个过程慢、缺少进展”的反馈修复源码、局部测试和文档。下文 2026-09-30 是历史记录，其中覆盖范围与“已完成”的表述由本节纠正，不能作为当前授权/启动效果的证明。

| 验证层级 | 本轮证据 | 限制 |
| --- | --- | --- |
| 构建与测试 | 5 个 Suite、34 项测试通过；最终记录 0.415 秒，构建 5.30 秒 | 构建时间不计入测试耗时 |
| 真实解析器 | `listVolumeGroups` 与 info 脱敏 fixture；根快照、缺失身份/字段、同名、锁定、未挂载、卷组重复、成员替换、挂载反查 | diskutil 输出来自模拟命令；可启动性未验证 |
| 非特权真实执行器 | 双路 256 KiB 输出、大输入、TERM 忽略、取消、持管道后代、信号退出、创建失败、连续输出及关闭输出、100 个并行短进程 | 不证明提权系统服务的生命周期或写入可撤销 |
| 执行侧守卫与流程 | 真实 Scanner 配模拟磁盘输出，受限 BootOperation 配模拟 bless；固定一次性参数、拒绝后零写入调用、错误/未知不重启、跨实例锁和符号链接拒绝 | 非 root 单元测试；root 锁安装、完整 socket/root 连接与真实授权未做 |
| 当前只读磁盘诊断 | 旧路径 22 命令/4.407 秒；新版扫描 6 命令/0.998 秒、目标核验 5 命令/0.732 秒 | 两种探针的单次样本，未控制缓存/负载，非端到端基准，不含授权、bless 或重启 |
| 非特权签名原型 | root 副本方案需完整 App；正确 cdhash 校验成功，错误 cdhash 被拒绝 | 普通用户复制/校验，不证明真实管理员执行全链路 |
| Release/App | 最终增量构建 5.01 秒；ad-hoc 签名 strict/deep 校验、Info.plist lint、3 脚本语法通过；新版完整副本正确 cdhash 返回 0、错误 cdhash 返回 3 | 不自动安装或执行写入 |
| 只读原生 UI | 启动扫描、目标选择、确认页短标识与风险文案核对，通过后取消确认 | 未继续认证；真实执行进展/窗口关闭联合验收仍未做 |
| 真实授权、owner、启动写入、正常重启与两次启动 | 未执行 | 必须由 89 安排操作窗口；外置启动也未验收 |

测试命令（当前受限环境使用独立缓存、scratch 与 SPM `--disable-sandbox`，后者不授予系统 root 权限）：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/MacBootSwitcher-review-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/MacBootSwitcher-review-swift \
./scripts/run-tests.sh --scratch-path /private/tmp/MacBootSwitcher-review-build --disable-sandbox
```

打包命令：`./scripts/build-app.sh`。本轮在相同缓存环境下增加 `--disable-sandbox`，并通过执行环境审核在沙箱外完成本地编译/签名：沙箱内 manifest 子沙箱、随后 dsymutil 受到限制。这些环境失败没有执行测试或启动写入，也没有据此宣称工具链不兼容。

本轮实现按次 Unix socket 传递固定请求、root 私有完整 App 副本及 cdhash 核验、执行侧固定锁、授权后重新核验稳定目标。最终核验与 bless 不原子，杀进程不能撤销已发生写入或保证停止系统服务。未知结果不自动重试或重启。日志只显示固定阶段与结果，清空密码引用不保证物理内存擦除。

当前事实见 [修复记录](reviews/2026-10-03-fix-results.md)，修复前事实见 [对抗性审查](reviews/2026-10-03-adversarial-review.md)。

## 1. 验证概览

| 阶段 | 内容 | 状态 | 验证结果 |
| --- | --- | --- | --- |
| 阶段 A | 环境、接口与授权方案 | 设计与非写入验证完成，完整授权待验收 | Apple Silicon 参数有本机文档依据；真实凭据链未验证 |
| 阶段 B | 只读窗口与扫描 | 已完成 | 结构化扫描实现，APFS 卷组去重，使用卷组 UUID 作为稳定身份 |
| 阶段 C | 操作协调与系统适配 | 已完成 | 包含状态机、操作互斥、多实例锁、核对守卫、超时与异常处理 |
| 阶段 D | 实机验收 | 待用户窗口 | 涉及真实启动写入与重启，须由用户安排操作窗口配合，不在自动化中触发 |
| 阶段 E | 本机交付 | 非写入交付完成 | SPM 工程、38 项测试、Release 打包与本地签名；不等于可启动效果验收 |

---

## 2. 详细验证记录

### 2026-09-30：阶段 A、B、C、E 完成与单元测试通过

历史执行数为 19，不是其他旧文档中的 18。多数“扫描解析”测试实际读取 MockScanner 构造的候选，没有运行真实 DiskutilScanner；旧 fixture 未使用，未测试真实进程超时，旧“脱敏”断言仅限制长度。通过数量真实，不能支持其原先列出的全部覆盖结论。本批已替换这些薄弱断言。

- **系统版本与环境**：
  - 架构：`arm64` (Apple Silicon)
  - 系统版本：macOS 26.6.2 (Build 25G83)
  - 开发者环境：`/Library/Developer/CommandLineTools` (无独立 Xcode.app)
  - 编译器：Swift 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
  - SDK：`MacOSX27.0.sdk`

- **编译结果**：
  - `swift build`：通过（耗时约 36s）
  - `swift build -c release`：通过（耗时约 33s）
  - 产物位置：`.build/release/MacBootSwitcher` (可执行文件大小约 534 KB)
  - 打包产物：`dist/MacBootSwitcher.app`（通过 `scripts/build-app.sh` 完成并完成 ad-hoc 签名）
  - 签名验证：`codesign -vvv dist/MacBootSwitcher.app` 返回 `valid on disk`，满足 Designated Requirement

- **单元测试执行情况**：
  - 测试命令：`./scripts/run-tests.sh`
  - 测试套件数：6 个 Suite
  - 实际测试用例数：**19 个测试**
  - 测试结果：**19 通过，0 失败**（耗时 0.010 秒）
  
  | 测试套件 | 测试用例 | 结果 |
  | --- | --- | --- |
  | **扫描解析** | 卷组去重：Preboot、Recovery 不产生独立候选 | ✔ 通过 |
  | | 当前系统识别正确 | ✔ 通过 |
  | | 空列表处理 | ✔ 通过 |
  | | 锁定卷不可切换 | ✔ 通过 |
  | | 未挂载卷不可切换 | ✔ 通过 |
  | | 同名系统通过卷组 UUID 区分 | ✔ 通过 |
  | **身份检查** | 操作前目标断开时拒绝写入 | ✔ 通过 |
  | | 操作前目标状态变化（变为锁定）时拒绝写入 | ✔ 通过 |
  | **认证与执行** | 设置前取消不写入 | ✔ 通过 |
  | | 设置失败不请求重启 | ✔ 通过 |
  | | 结果不确定不自动重启或重试 | ✔ 通过 |
  | | 设置成功才请求重启 | ✔ 通过 |
  | **命令约束** | bless 命令通过管理员提权脚本包含 `--nextonly` 与 `--setBoot` 参数 | ✔ 通过 |
  | | 密码通过安全管道传递，绝不在命令行参数中 | ✔ 通过 |
  | | 目标含空格和特殊字符时安全转义 | ✔ 通过 |
  | | 用户取消管理员认证时返回 cancelledBeforeExecution | ✔ 通过 |
  | **重启请求** | 仅设置成功才调用重启 | ✔ 通过 |
  | **安全数据** | MockBootSetter 不存储密码 | ✔ 通过 |
  | | 错误输出脱敏 | ✔ 通过 |

### 2026-09-30：运行时报错 101 排查与按次管理员提权修复

- **问题现象**：
  实机点击切换时抛出：`bless 退出码 101: Bootability failed Error Domain=BYErrorDomain Code=101 "Failed to mount volume"`。
- **历史根因假设（当前未复现确认）**：
  通过 `log show --predicate 'process == "bless" OR process == "BootabilityService"'` 定位到底层日志：
  `Can not mount (/dev/disk3s3) because mount returned 66`（EINVAL/Permission denied）。
  `bless` 工具在配置 Apple Silicon 引导策略时，由系统服务挂载底层的 Recovery 分区；以普通用户进程（uid 501）直接调用时无权执行底层挂载系统调用，导致启动设置失败。
  上述是历史记录的解释；该错误号和挂载日志不足以单独证明唯一根因，也没有本轮真实写入结果证明提权已解决 101。保留证据，不宣称当前已实机修复。
- **修复方案**：
  以下为已被本批 Unix socket + 受限 runner 替代的历史 FIFO 方案，不作为当前实现说明：
  采用方案 A（按次原生管理员提权 + 安全内存 FIFO 管道），严格符合项目架构约束：
  1. 使用 macOS 原生 Security AuthTrampoline 提权机制（通过 `/usr/bin/osascript` 执行 `do shell script ... with administrator privileges`）；
  2. 运行时创建权限为 `0600` 的安全内存命名管道（FIFO），后台异步流转 Owner 密码，进程读完立即销毁，密码绝不进入命令行参数、临时文件或日志；
  3. 用户在系统管理员提权弹窗中点击“取消”（错误码 -128）时，精准映射为 `.cancelledBeforeExecution`，安全优雅退回界面；
  4. 无需安装任何系统常驻 LaunchDaemon 或 PrivilegedHelperTool。

- **只读基线与默认启动状态核对**：
  - 核对命令：`/usr/sbin/bless --getBoot --plist`
  - 核对结果：`Boot Volume = /dev/disk3s1`（Macintosh HD 系统卷）
  - 当前根系统 APFS 卷组 ID：`2671FCA2-812C-46D3-A201-62EA92102169`
  - 候选目标卷组 ID（Remote Work）：`FC07C8A2-8199-4A20-A145-6554CE15FEC5`
  - 确认在所有开发与测试过程中，**未调用真实 bless 写入，未修改默认启动盘，未触发系统重启**。

---

## 3. 待实机验收事项（阶段 D）

依据项目规则，实际设置启动目标与实机重启须向 89 说明目标及步骤，等待 89 安排操作窗口配合：

1. **实机验收准备**：
   - 重新扫描确认当前运行系统及目标的稳定身份；历史名称、设备号和路径不作为此次执行输入。
   - 核对当前基线：`/usr/sbin/bless --getBoot --plist`
2. **切换步骤**：
   - 运行 `./dist/MacBootSwitcher.app/Contents/MacOS/MacBootSwitcher` 或打开 App
   - 界面扫描识别用户确认的目标并显示就绪；这不保证可启动
   - 核对目标名称与短标识，点击「继续…」
   - 在同一页阅读风险说明、再次核对目标并输入本机拥有者账户短名称与登录密码
   - 点击「认证并重启」，在随后出现的 macOS 管理员授权弹窗中完成本次授权
   - 程序执行 `bless --mount <path> --setBoot --nextonly --user <user> --stdinpass`
   - 工具报告成功后，触发正常系统重启请求
3. **重启验证步骤**：
   - 确认第 1 次启动成功进入本次确认的目标系统
   - 在目标系统正常点击「重新启动」（不运行任何恢复默认盘命令）
   - 确认第 2 次启动回到原默认系统，并记录前后默认配置与必要安全状态证据
   - `bless --getBoot --plist` 仅是辅助证据，不能单独证明持久默认从未变化或读回一次性选择
