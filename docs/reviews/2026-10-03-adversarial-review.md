# MacBootSwitcher 对抗性审查与修复方案

日期：2026-10-03。状态：审查完成，修复待 89 确认。

## 结论

当前版本可编译，现有 6 个套件、19 个测试全部通过，已有 App 签名校验通过。但这些证据不足以支持“安全切换功能已完成，仅待两次启动”的交付状态。发现 **4 项 P1、7 项 P2**；建议修复并完成非写入验证后，再安排真实启动写入窗口。

核心风险是：用户确认的稳定目标未贯穿提权边界；执行器的超时与取消不保证有限时间返回；当前系统身份未知时仍开放切换；写入期间正常退出和窗口关闭没有协调保护。没有证据表明本轮或现有代码已经修改了持久默认盘，也没有把尚未实测的风险写成已发生事故。

本轮只新增本报告与 SHA-256 快照清单。未修复代码，未修改既有需求/验证文档，未重打包 App，未提权、输入真实凭据、设置启动目标或重启机器。

## 审查基线与方法

- 权威需求：`AGENTS.md`、`docs/architecture.md`、`docs/implementation-plan.md`。`FEASIBILITY.md` 仅是旧调查，不恢复一次性目标查询、撤销或旧版门槛。
- 当前目录不是 Git 仓库，无法固定 branch/HEAD/提交差异。因此审查对象是当前全量文件，使用相邻 `2026-10-03-baseline.sha256` 固定源码、测试、脚本、需求、资源及现有 App 的 plist/主程序。报告生成前，清单中全部 24 个文件校验一致。
- 主 Agent 负责基线、测试可信度、证据裁决和修复顺序；3 个独立 Agent 分别审查流程/需求、权限/进程、磁盘发现/身份。独立发现后互相质疑触发条件，合并重复发现并撤回不成立结论。
- P1：安排真实写入前应修复的安全或核心流程缺口。P2：需求、诊断、可恢复性或验证缺口，应在交付前修复。未发现需要报告为已发生严重事故的 P0。
- 证据分为静态确定缺口、非特权模拟复现、本机只读验证、尚未实机验证；不以 mock 成功证明固件行为。

### 从基本要求推导验收标准

| 基本要求 | 必须成立的条件 |
| --- | --- |
| 用户选择另一套系统 | 当前系统身份已知；同名目标可辨认；选择对象冻结为稳定身份 |
| 只作用于下一次启动 | 每条实际写入路径具有公开的一次性语义；没有默认盘恢复替代方案 |
| 设置到准确目标 | 认证等待结束后，在实际写入侧核验卷组、System 卷和即时挂载对象 |
| 认证不泄露凭据 | 管理员与 owner 分开；凭据不进入参数、普通文件或诊断；异常路径也受控 |
| 设置结果可以解释 | 只有工具明确成功才重启；中断、部分执行和失联不冒充未执行 |
| 用户可保存工作、取消重启 | 使用正常重启；关闭窗口/退出不会让写入失去协调；不强制关机 |
| 验证结论可信 | 测试运行真实受测模块；编译、模拟验证、真实切换分别记录 |

## P1：真实写入前的修复项

### R1：稳定身份核对没有贯穿到实际提权写入

**证据：**[SwitchWorkflow.swift:175](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Workflow/SwitchWorkflow.swift:175) 先保存挂载路径，再整机扫描；180–191 行仅检查原卷组仍存在、仍就绪。195 行调用 Boot 时继续使用旧路径。[BootSetter.swift:23](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Boot/BootSetter.swift:23) 接口只接受路径，不接受稳定身份；94–101 行在这些核对之后才等待管理员认证，特权侧没有再次核验。[DiskutilScanner.swift:76](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Discovery/DiskutilScanner.swift:76) 仅取首个卷组匹配并返回挂载点，不比较选择时的 System 卷 UUID。

**触发与影响：**整机扫描或管理员认证等待期间，卷组 A 移到新路径，旧路径被 B 占用。A 仍存在、仍就绪，所有现有守卫均可能通过，但 `bless --mount` 使用的是 B 的路径。另一种情况是卷组 ID 相同而 System 成员变化，现有核对不会拒绝。

**证据等级：**静态确定的时间窗口与校验缺口。Scanner 模拟探针另确认：Locked=true 但 MountPoint 存在时，resolve 仍返回路径；这不能单独证明最终写入，因为后续扫描可能拒绝。未在真实机器上换卷或制造错写。

**最小修复：**内部 Boot 接口接收冻结的卷组 UUID 与 System 卷 UUID；管理员授权结束后，由实际执行侧唯一重新解析身份，反查挂载对象、锁定/挂载状态及非当前身份。字段冲突、重复身份、断开或身份变化一律拒绝，不沿用旧路径。挂载路径只作最终工具的即时参数。特权入口只接受固定的“设置下一次启动”操作，不能扩展为任意执行器。

**验收：**模拟认证前后的身份变化、最终挂载对象不匹配、卷组重复和目标断开，真实写入适配调用次数均为 0。同一卷组和 System UUID 仅换挂载点时，只能使用授权后重新核验的新路径，绝不使用被别卷占用的旧路径；每次允许的写入只产生一条带 `--nextonly` 的命令。需验证受限提权执行侧本身的核验，而非只测试 Workflow。

### R2：超时、取消与输出处理不能保证受控结束

**证据：**[CommandExecutor.swift:79](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Boot/CommandExecutor.swift:79) 的任务组先 `waitUntilExit()`，后读取两路输出；93–97 行超时只向直接进程发送 terminate；113–118 行的取消包装没有实际取消处理。任务组必须等子任务完成，取消信号不会自动中断阻塞等待，这与 [Swift TaskGroup 官方文档](https://docs.swift.org/latest/documentation/swift/taskgroup/) 一致。

**非特权实测：**直接编译当前执行器，运行 `/usr/bin/head`、`/bin/sh`、`/bin/sleep`：

| 场景 | 设定 | 实测 |
| --- | --- | --- |
| 输出 256 KiB | 超时 0.5 秒，正常命令应成功 | 0.515 秒返回 timeout，输出未被及时排空 |
| shell 忽略 SIGTERM | 超时 0.2 秒、实际 sleep 3 秒 | 3.027 秒后才返回 timeout |
| shell 退出、后代持有输出管道 | 超时 0.2 秒、后代 sleep 2 秒 | 2.023 秒后才返回 timeout |
| 取消 sleep 2 秒任务 | 0.1 秒取消 | 2.016 秒后才返回 CancellationError |

**影响：**正常磁盘大输出可能被误判为扫描失败；超时或取消后流程仍等待，无法按承诺处理结果。对真实提权链，只终止 `osascript` 不能证明授权后的实际工具已停止；root 子进程存续是静态风险，本轮未实测。

**最小修复：**启动后并行排空 stdout/stderr，统一处理完成、超时、取消、读取结束与资源回收；保留退出原因。提权执行单元须自己管理受限工具生命周期，UI 不能凭 `osascript` 消失就释放仍在进行的写入互斥。设置超时或失联归未知，不重启、不自动重试。有限等待与“底层是否已停止”是两个不同验收条件。

**验收：**上述 4 案全部修正；增加启动失败、双路大输出和成功输出完整性验证。所有实验只用非特权无害工具；真实提权进程控制仍须单独确认机制，不用 mock 替代。

### R3：当前系统身份未知时仍允许切换

**证据：**[DiskutilScanner.swift:178](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Discovery/DiskutilScanner.swift:178) 对根卷缺失 APFSVolumeGroupID 返回 nil；208 行因此把全部卷组判为非当前；238 行使已挂载候选就绪。

**触发与影响：**根卷 info 命令成功，但关键身份字段缺失；当前 System 卷同时挂载。程序无法排除当前系统，却允许选择并设置它，违反“当前系统不能作为切换目标”。

**证据等级：**真实 Scanner 配模拟输出复现：`currentSystemID=nil, candidates=1, canSwitch=true`。本机只读核实字段正常存在，不能描述成这台机器当前必然触发。

**最小修复与验收：**根身份缺失、无效或不能唯一确认时禁用设置并解释原因；不得把 nil 当作已确认非当前。使用真实 Scanner 验证缺失字段与合法根快照两类输出，前者不能产生可切换目标，后者正确识别当前系统。

### R4：写入期间没有正常退出和窗口关闭保护

**证据：**[MacBootSwitcherApp.swift:7](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/App/MacBootSwitcherApp.swift:7) 只有 WindowGroup；没有应用/窗口生命周期协调。[ContentView.swift:470](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/App/ContentView.swift:470) 只有“请勿强行退出”文字，不处理 Cmd-Q 或正常关闭窗口。

**触发与影响：**设置期间 Cmd-Q 可以退出应用；关闭执行窗口不一定终止 App，但会使可能仍在写入的操作失去可视状态。实际命令是否继续由进程链决定，应用没有可信收尾；不能假设退出等于撤销。

**最小修复：**设置可能执行期间，对正常退出与执行窗口关闭提示等待并延后；保留可视状态和操作所有权。结束后恢复正常关闭。进入正常重启阶段必须允许系统结束本应用，不能反过来阻挡重启。

**验收：**挂起 MockBootSetter，检查正常退出和窗口关闭均被协调；失败/未知终态可正常退出；系统正常重启阶段不被保护逻辑阻挡。此项静态确认，未运行真实写入过程的 UI 验收。

## P2：交付前的修复项

### R5：测试名称与覆盖、交付文档与实际证据不一致

**证据：**[MacBootSwitcherTests.swift:74](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Tests/MacBootSwitcherTests/MacBootSwitcherTests.swift:74) 的卷组去重测试只是给 MockScanner 放入两个已构造候选，再读取回来；当前系统与空列表测试同样没有执行真实解析器。fixture 没有被任何测试读取；项目测试没有调用 ProcessExecutor，也没有重复点击/多实例竞态测试。522 行“脱敏”测试只检查长度。

README、架构和计划写 18 项，验证记录写 19 项；[architecture.md:113](/Users/tangw/Documents/documents/projects/MacBootSwitcher/docs/architecture.md:113) 声称 Package.swift 通过 swiftSettings 加载插件，但实际 Package.swift 没有该配置，插件由 run-tests.sh 指定。架构开头仍写待实施，后文又写已完成。实机 101 失败记录是历史证据，不能凭本轮代码判断其全部根因或修复已有效。

**影响：**19 项通过本身真实，但“解析正确、执行器超时有效、并发保护已验收”等结论没有对应测试证据；更换错误解析器仍可能全部通过。

**最小修复：**让真实 Scanner 接收 mock 命令输出，接入完整脱敏 apfs list/info fixture；加入本轮发现的失败模式、并发守卫与有限等待测试。保留已有有意义的 Workflow 测试，替换复述 mock 的断言。同步 README、架构、计划和 validation 的测试数与验证层级，不把全部阶段继续标成已验收。

**验收：**测试能因真实解析错误、身份守卫缺失、执行器超时失效而失败；报告实际执行数。README 的构建/测试命令应与所用 CLT 工具链匹配；本轮没有单独验证不带插件参数的裸 `swift test`。

### R6：不完整卷组和未知字段被判为确定的就绪状态

**证据：**[DiskutilScanner.swift:101](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Discovery/DiskutilScanner.swift:101) 记录 Data 成员却没有用于安装实例检查；217 行对缺少 System 的候选假定内置，225–227 行把缺失 Internal/Locked 分别假定外置/未锁定；238 行仅凭 System 角色与挂载点判就绪。

**复现：**真实 Scanner 接收只有 System 成员、无 macOS 文件的模拟输出，仍 `canSwitch=true`；缺失 Locked/Internal/名称时仍 `canSwitch=true, isInternal=false`。本机 man diskutil 支持赋予新卷角色，角色不是完整安装证明。

**最小修复：**缺少支持范围内必要关联成员的卷组保留为信息不足、不可切换；内外置属性显式保留未知；关键就绪字段无法确认时不默认安全。版本仍可选，不能因版本不可读就一律否定系统，更不能把结构核验宣传成可启动保证。

**验收：**真实 Scanner 覆盖完整 System/Data、孤立 System、仅 Data、辅助卷、锁定、未挂载、字段缺失和类型错误；界面显示真实未知原因。

### R7：取消、异常终止与工具失败分类不可靠

**证据：**[BootSetter.swift:104](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Boot/BootSetter.swift:104) 依赖 stderr 包含 -128/canceled/cancelled 就认定设置前取消；[CommandExecutor.swift:85](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Boot/CommandExecutor.swift:85) 没有保留 terminationReason。其他非零退出全归普通 failure；Workflow 222 行只说失败、未重启，不提示不能排除部分变更。

**影响：**工具已经执行的错误若包含取消词，界面会错误宣称“未执行设置”；信号终止被混同为普通工具失败。当前打印的“bless 退出码”实际是 osascript 进程状态，不能替代内部工具错误号。Apple 的 [do shell script 文档](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_cmds.html) 区分脚本错误号与工具 stderr。

**最小修复与验收：**保留进程退出原因及错误来源；仅在可信授权阶段的结构化取消结果下声明未执行。信号、超时、失联归未知；普通工具失败不能排除部分写入时明确提示临时状态可能有效。模拟包含取消词的普通错误、真正授权取消、信号退出和内部工具非零，均不重启，不误报未写入。

### R8：截断错误原文没有实现脱敏

**证据：**[BootSetter.swift:134](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Boot/BootSetter.swift:134) 只保留前 150 字符，账号、路径或 UUID 若在开头仍直接显示。

**最小修复与验收：**界面使用受限错误类别和必要退出结果；确需附加字段时采用允许名单，不直接显示未经处理的 stderr。用合成账号、路径、UUID 和凭据哨兵验证诊断。未证实真实 bless 会输出密码，不报告为已发生密码泄露。

### R9：同名系统内部能区分，用户不能区分

**证据：**[ContentView.swift:310](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/App/ContentView.swift:310) 的列表和633行的确认卡片只显示名称、可选版本及内外置属性；不展示区别目标的身份信息。

**触发与影响：**两个目标完全同名、同版本、同存储类型时，用户无法判断选中了哪套系统。内部 UUID 不同不能满足“同名系统可区分”的需求。

**最小修复与验收：**列表和确认页显示一致、在当前候选集合中唯一的卷组短标识，必要时扩展长度避免碰撞；以真实存储信息辅助辨认。两个完全同名目标也必须可辨，确认对象与执行身份一致，不硬编码名称或设备号。

### R10：确认和结果文案超出实际能够证明的事实

**证据：**[ContentView.swift:655](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/App/ContentView.swift:655) 缺少覆盖已有一次性选择且不查询/恢复的说明；[SwitchWorkflow.swift:226](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Workflow/SwitchWorkflow.swift:226) 把系统设置“启动磁盘”当成未知临时选择的核对建议；重启失败后仍保持 restartRequested，ContentView 495行标题仍宣称已提交；67行静态绿灯“默认盘保护已激活”没有相应监测或验证机制。

**最小修复：**补齐覆盖声明和“扫描不保证可启动”；未知结果明确临时选择可能仍有效、无法独立确认，不引导用户修改默认盘解决；按重启实际返回结果展示标题。安全说明表达实施策略，不伪装为已测得的系统状态或运行中的保护服务。

**验收：**检查确认文本；mock 设置未知、工具失败及重启失败时检查标题与正文，无查询、撤销、默认盘恢复或自动重试入口。

### R11：重启适配绕过统一执行层，可能无限等待

**证据：**[Restarter.swift:25](/Users/tangw/Documents/documents/projects/MacBootSwitcher/Sources/MacBootSwitcher/Restart/Restarter.swift:25) 自行创建 Process，35行 waitUntilExit，没有有限等待或取消边界；未异步排空输出。等待期间 Workflow 仍占有操作互斥和文件锁。

**最小修复：**复用修复后的执行适配层，保留固定的正常重启操作；结果至少能表达已提交、明确失败和无法确认。等待用户保存文档不等于取消，超时也不能触发强制或重复重启。有限等待只约束请求进程与 UI 协调，不据此宣布机器已重启。

**验收：**用模拟命令覆盖启动失败、非零、成功和迟迟不退出；最终界面能解释请求状态，保留临时选择可能有效的提示，无强制重启兜底。真实 System Events/TCC 交互尚未验收。

## 修复顺序与确认范围

### S1：先闭合身份与按次授权执行边界（R1、R3、R6）

涉及 Discovery、Boot 内部协议与 Workflow 调用。先做非写入的受限执行原型：固定操作、稳定身份输入、执行侧核验、错误来源和生命周期均可测试。沿用按次、不常驻的方向，但现有 AppleScript 只是提权传输，不能自动承担这些校验职责。

本报告不宣称某个尚未实现的特权 runner 已可用。确认修复后，必须先把该方案的调用方式、可信代码位置/签名、参数白名单及进程控制证据记录清楚，再接入真实写入动作；仅重复普通层核对不算 R1 修复。优先保持当前免安装方案。若无法以公开能力做到而必须安装 helper，提交具体签名/安装设计供 89 决定，不自动安装，也不改默认盘兜底。

### S2：收敛进程、结果和互斥生命周期（R2、R7、R8、R11）

统一执行层、并行输出读取、有限等待、结构化结果和受限诊断；重启复用执行层。写入互斥须由实际受限执行单元持有直到工具结束，UI 退出、失联或重新打开不能解除或绕过；失联不得显示安全重试。这样未知结果界面允许正常退出，也不会使仍在执行的旧动作与新实例并发。按次执行单元完成后自然退出。保留现有正常重启机制，不增加后台常驻、状态查询、撤销或独立仅设置操作。

### S3：补齐用户操作与事实表达（R4、R9、R10）

仅修改执行期关闭/退出协调、同名辨识和必要文案。保持当前窗口和按钮范围，不顺手重新设计界面。正常重启必须能完成应用退出，不能被写入保护机制阻塞。

### S4：针对缺口验证并同步交付状态（R5）

新增/调整真正覆盖缺口的局部测试，完成后更新 README、architecture、implementation-plan、validation。记录真实测试数及非写入验证结果；只在代码改动后重建 Release/App 并验证签名。没有新疑点时不重复扩大测试，不自动提交或推送。

**确认即授权的范围：**S1–S4 的必要源码、局部测试和相关文档修复，以及无真实写入的构建/模拟验证。真实管理员/owner 交互验证、启动写入、两次启动和外置系统验收仍另行说明目标与步骤，等待 89 安排窗口。修复确认不等于自动授权重启或安装 helper。

## 本轮验证与限制

| 验证 | 本轮结果 | 能证明什么 |
| --- | --- | --- |
| 局部构建及项目测试 | 构建40.60秒；6套件19项通过、0失败；测试0.027秒 | 当前代码在本机工具链编译、已有断言成立 |
| 真实执行器非特权实验 | 4案复现R2，实验进程均已结束 | 超时/取消/管道边界存在缺口 |
| 真实Scanner配模拟输出 | 4探针复现根ID缺失、孤立System、未知字段和resolve锁定路径 | 真实解析/判定存在对应缺口 |
| FIFO cleanup模拟 | 100次，阻塞残留0，线程全部join | 未支持“取消必然挂死”的指控；不保证所有时序 |
| 本机磁盘只读schema | 根为快照；关键字段与解析名称一致；未保存真实UUID | 当前系统结构可以作为fixture设计依据 |
| 本机man bless | Apple Silicon专节支持所用一次性和stdinpass参数 | 公开接口有文档依据 |
| 现有App签名 | codesign verify strict通过 | 已有产物签名完整；不证明与当前源码完全对应 |
| 脚本静态检查 | 3个脚本bash语法检查通过 | 脚本语法成立，不证明打包/重启等实际行为 |
| 真实启动写入、正常重启及两次启动 | 未执行 | 一次性实际效果和持久默认不变仍须实机证据 |

项目测试首次因沙箱不允许写 `~/.cache/clang` 而在 manifest 阶段失败，未运行测试；将缓存与scratch目录转入 `/private/tmp` 后编译及19项执行成功。此限制不是项目测试失败，也没有据错误链中的后续SDK提示直接判定工具链不兼容。命令如下：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/MacBootSwitcher-review-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/MacBootSwitcher-review-swift \
./scripts/run-tests.sh \
  --scratch-path /private/tmp/MacBootSwitcher-review-build --disable-sandbox
```

临时非特权探针源文件：`/private/tmp/macbootswitcher-review-process.swift`、`/private/tmp/MacBootSwitcher-discovery-review.swift`、`/private/tmp/macbootswitcher-review-fifo.c`。它们不是项目新增测试，4+4探针和100次FIFO实验不并入19项计数；临时目录文件可能被系统清理。

### 被排除或不作为新增需求的结论

- 不能依据旧Intel段落认定Apple Silicon不支持 `--nextonly`，本机man明确支持。
- 没有可证实的shell注入；两层转义有实现。存在shell仍与项目“参数数组、不拼含用户输入shell”的规则有偏差，应在S1的受限接口设计中解决，但不把规则偏差夸大成已证实漏洞。
- FIFO是命名管道，不能仅因存在路径就断言密码落盘；100次cleanup实验也不支持必然留阻塞线程。真实凭据端到端安全性仍未由这些实验完成验收。
- 不把当前系统版本未从根快照挂载点读取等展示问题升级为写入阻断，也不顺手扩大修复。
- 已存在同用户flock防护，不能称其完全没有多实例保护；项目缺少并发验收，跨用户边界未验证，不据此假定锁已通过所有场景。
- 缺少独立一次性目标查询和撤销不是缺陷，不引入这些功能。不以修改持久默认盘后恢复完成“一次性”。

## 实机验收出口（修复后的独立操作窗口）

重新发现并由 89 确认目标，不直接复用历史设备编号。记录稳定身份、原默认配置及必要安全状态；明确区分管理员授权和owner认证。先确认工具报告结果，再验证第一次进入目标系统；在目标系统正常重启、不执行恢复默认盘操作，确认第二次回到原默认系统。保存前后核对与两次启动证据，不能以单项 `bless --getBoot` 输出解释一次性目标读回。

遇到失败或不确定：不自动重试、不重启、不更改默认盘、不降低安全策略。外置系统没有实际设备或操作窗口时仍标为未验证；不在实机主动拔盘或制造中断来测试异常。

89 确认 S1–S4 后才执行修复。此前现有应用继续保持“尚未完成安全边界验证与实机验收”的交付定位。
