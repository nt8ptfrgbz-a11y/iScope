# iScope

用 SwiftUI 实现的原生 macOS 应用：导入脱壳 IPA，从功能词、类名、方法名、界面文案和 API 路径，定位 Mach-O 中的候选方法。

全部解析在本机完成，无第三方依赖，不执行导入的二进制，不上传 IPA。可选智能定位通过本机 Codex CLI 调用你配置的模型服务，发送功能描述和可选的候选证据摘要。

## 运行

- macOS 14 或更高版本，Apple Silicon / Intel。
- 开发需要 Xcode 15 或更新版本，或 Swift 5.9+ 的 Command Line Tools。
- 用 Xcode 打开 `iScope.xcodeproj`，选择 **iScope → My Mac → Run**。
- 构建可双击运行的通用 App：

```sh
zsh scripts/build.sh
```

产物：`build/iScope.app`。本机使用 ad-hoc 签名；分发给其他用户时需自行配置 Developer ID 和公证。

也可以使用 Swift Package Manager：

```sh
swift run iScope
swift test
```

IPA 解包使用 macOS 自带的 `/usr/bin/ditto`。Swift 符号还原使用 `xcrun swift-demangle`，没有 Command Line Tools 时仍可浏览原始符号。

## 功能

| 能力 | 用途 |
| --- | --- |
| 导入 IPA、ZIP、.app、Framework、dylib、裸 Mach-O | 自动识别主程序、嵌入 Framework、扩展中的二进制 |
| 64 位 / Universal Mach-O | 默认优先 arm64，可在概览切换其他架构 |
| Objective-C 类、Category、类方法、实例方法 | 恢复 Selector、类型编码、父类、属性和遵循的协议 |
| 中文功能词扩展 | “登录”扩展为 login / signin / authentication 等，“支付”扩展为 payment / purchase / checkout 等 |
| Codex 中文描述定位 | 将“微信运动步数”等自然语言转为结构化检索计划，再按真实名称、字符串引用和一层直接调用筛选前 20 个候选 |
| 可选候选评估 | Codex 仅评估本地找到的候选，引用已有证据编号，区分优先核查 / 可能相关 / 线索较弱 |
| 字符串 → 函数引用 | 从中文文案、URL、API 路径定位装载这些地址的 ARM64 函数 |
| 方法 → 字符串 / Selector | 结合名称与代码中的静态线索判断候选方法用途 |
| 直接调用关系 | 显示 ARM64 BL 调用的来源和目标，可跳转到已恢复的 Objective-C 方法 |
| Swift 符号还原 | 展示保留在符号表中的 Swift 类型和函数的可读名称 |
| 搜索范围与匹配依据 | 当前 Mach-O / 全部已分析文件；大小写、正则、多关键词；展示命中原因 |
| 地址定位 | 虚拟地址、相对 Image base 偏移、原始文件偏移（包含 fat slice 偏移） |
| 收藏与分析笔记 | 按导入文件路径保存在本机，重新打开恢复 |
| 导出 | 方法名 TXT、类名 TXT、接口草稿 H、字符串 TXT、方法地址 CSV、完整结果 JSON |
| 后台分析 | 搜索和解析不阻塞主线程，可取消分析 |
| 创建 Xcode Hook 工程 | 选择一个或多个方法，生成带原实现调用的 iOS dylib 项目，直接修改 Hooks.m |
| Hook 编译与部署 | App 内编辑源码，自动编译、注入、重签和安装；实时日志、取消、保留产物和仅重试安装 |
| 四个独立工具按钮 | 选择 Hook 源码编译 dylib、选择 dylib 目录注入 IPA、重签 IPA、安装 IPA；无需创建工程 |

## 推荐的定位流程

1. 拖入脱壳 IPA，主程序自动开始分析。
2. 选择“功能定位”，输入“微信运动步数”等描述后点击“智能定位”，或输入“登录”“支付”等词做普通本地搜索。
3. 若名称无明显特征，搜索页面上实际出现的中文文案、报错文本或 API 路径。
4. 选中字符串，在右侧查看“引用此字符串的函数”；已识别的方法可点击跳转。
5. 检查方法引用的字符串、装载的 Selector、所属类及属性，缩小候选范围。
6. 主程序没有结果时，点击“分析全部”，把搜索范围改为“全部已分析 Mach-O”。
7. 收藏候选方法并写笔记；复制地址到其他反汇编工具，或导出 JSON / CSV。
8. 需要修改行为时，点击右侧“创建 Hook 工程”，选择方法和保存位置，然后“继续编译与部署”。在 App 中修改实现，连接真机后开始执行。

## 使用已有 Codex CLI

不需要另填 OpenAI API Key，也不需要部署本地模型。安装并配置好 Codex CLI 后，在工具栏的“Codex 设置”中检查 CLI；默认复用 CLI 当前的模型、Provider 和凭据。支持自定义可执行文件路径、模型和 Profile。Finder 启动的 App 也会搜索 `~/.local/bin/codex`、`/opt/homebrew/bin/codex` 和 `/usr/local/bin/codex`。

1. 输入描述，点击“智能定位”（或 ⌘↩）。只有明确提交才会调用模型，打字不会触发请求。
2. Codex 输出 JSON Schema 约束的计划：核心功能、明确动作、应用背景、辅助 API 猜测和歧义提示。例如“微信运动步数”未指定动作，不默认理解为修改或上传步数。
3. 本地用计划中的中英文词搜索当前范围的已分析文件；背景 / API 猜测本身不能产生候选。优先方法自身名称与字符串证据，降低仅所属类相关的通用方法和泛化 `step` 词的排序。还会寻找保留符号的 Swift / C 函数和引用指向的未命名函数。
4. 默认可再评估前 20 条候选。模型必须返回现有候选 ID 和有效证据编号，不能添加方法；评估失败时保留本地排序。设置中可关闭这一步。
5. 展开“检索计划与范围”查看检索词和覆盖提示；展开“文本线索”继续追踪字符串。点击“关键词结果”返回普通搜索，或进一步写明“读取当天步数”“展示排行榜”“上传步数”等动作再提交。

模型服务首先只接收描述；候选评估时额外接收最多 20 条名称、文件名和匹配依据摘要，不接收 IPA、二进制或完整索引。**本机 CLI 不代表本地推理**：请求由 Codex 已配置的服务处理，使用其现有额度 / 计费规则。静态证据和模型评估均不能证明运行时行为，模型输出不使用置信度百分比。

调用使用 `codex exec` 的 `--ephemeral`、`--output-schema`、`--output-last-message` 和只读沙箱，工作目录为独立临时目录。单次禁用 shell、应用、插件、Hook、子代理和联网搜索入口；先通过 CLI 获取已配置的 MCP 名称，再逐个在本次调用中禁用（空表会与原配置合并，不能只传空表）。采用低推理强度，不改动全局配置。功能描述通过 stdin 传入，输出经过结构和大小校验；CLI 有超时和取消处理，任务结束后清理临时文件。旧版 CLI 或不支持 JSON Schema 的 Provider 会显示调用失败，不会把词典结果伪装成模型结果。

智能定位仅覆盖已分析文件；不会自动解包新目标、执行任意模型指令或动态运行 IPA。

每次智能定位都会保留为“功能定位”页面中的结果标签，包含候选列表、排序、检索计划、模型评估和选中方法。创建 Hook、进入部署面板、查看其他页面后再返回，会恢复原列表并滚动到选中方法，不会重新调用模型。修改关键词、范围或执行新定位也会保留旧标签，点击即可返回；点击标签上的 × 才移除该次结果。关键词结果可单独查看，不会删除已保留的定位。

结果标签保留在当前 IPA 工作空间的内存中；重新导入文件建立新工作空间或退出 App 后会清空。每个标签标明检索时的文件与架构；切换架构不会改变旧候选的原始分析上下文。离开页面会取消未完成的检索或评估，已经取得的候选仍保留。

## 为自己的 IPA 创建 Hook 工程

可以从方法 / 类的右键菜单、详情面板或工具栏打开工程生成器。一次选择多个方法，自动读取目标 Bundle ID，预览源码后生成完整 `.xcodeproj`。

生成工程无需 Theos 或 Logos，使用 Objective-C runtime 替换 IMP。`Hooks.m` 中每个方法都有独立替换函数，默认透传原实现；修改函数体后，在 Xcode 选择 **Any iOS Device → ⌘B**，即可得到 arm64 / iOS 15+ 动态库。生成的工程会处理类方法、继承方法、延迟加载 Framework，以及安装前的运行时签名校验，并附带 `HookTargets.json` 和 README。

支持对象、常见标量与指针、布局已验证的常见 UIKit / CoreGraphics 结构体。不能确认 ABI 的方法会显示原因并禁用。纯 Swift 非 `@objc` 方法不适用此模板；可变参数无法从元数据可靠辨认，选择前需确认真实签名。

生成后点击“继续编译与部署”，或随时从工具栏 / 分析菜单打开部署面板（⇧⌘B）。选择已有 iScope 工程也可继续工作。

## 在 App 内完成编译、注入、重签与安装

从欢迎页或工具栏打开“编译与部署”，选择“独立操作”，四个按钮分别执行：

1. **编译 Hook → dylib**：选择具体的 `.m` / `.mm` 文件，自动编译为同目录的同名 `.dylib`。默认 arm64、iOS 15+，链接 Foundation 和 UIKit；高级设置可选择 arm64e 或双架构。
2. **注入 dylib → 未签名 IPA**：选择 dylib 所在目录，勾选要注入的动态库。同目录只有一个 IPA 时自动选中；有多个时手动选择，也可点击“另选 IPA”指定其他目录的文件。未签名 IPA 输出到 dylib 目录，命名为 `原包名-unsigned.ipa`。
3. **重新签名 IPA**：选择 IPA，复用原工具的证书与描述文件自动匹配、嵌套签名及最终包复验，输出到 IPA 同目录的 `原包名-resign.ipa`。使用下方签名设置；默认 Bundle ID 追加 `.regisn`。独立源码若写有 Bundle ID 过滤条件，需让重签 ID 与源码匹配。
4. **安装 IPA 到设备**：选择已签名 IPA，验证签名和目标设备权限后安装到所选真机。

独立操作无需 `.xcodeproj`，也不会触发前面的步骤。产物或报告重名时自动编号（如 `Hook-2.dylib`），不覆盖已有文件。右侧提供日志、产物位置和取消操作；每次的 `request.json`、`result.json` 与 `workflow.log` 保存在同目录下独立的时间戳子目录中。

切换到“工程工作流”可继续使用以下完整流程：

1. 选择 iScope 生成的 `.xcodeproj` 和对应的原始 IPA / `.app`。从工程生成器进入时会自动带入。
2. 在内置编辑器修改 `Hooks.m`，也可用 Xcode 编辑。执行前自动保存；检测到外部编辑冲突会提示合并。
3. 选择执行目标：只编译 dylib、编译并注入、编译注入并重签、完整签名安装。也可单独安装已有的签名 IPA。
4. 默认自动匹配本机钥匙串中可用的证书与描述文件，可手动指定证书、`.mobileprovision`、额外 entitlements、显示名称和重签 Bundle ID。描述文件搜索 Xcode 目录、IPA / 工程同目录，以及原 `~/Downloads/ios-hook-tools` 和其 `profiles` 目录。
5. 连接并解锁 iPhone / iPad，信任 Mac 并启用设备所需的开发者模式，刷新设备列表。唯一连接的真机会自动选择；多台时需明确选择。安装前校验描述文件包含目标设备。
6. 点击“开始执行”。阶段状态、实时编译日志和产物会显示在右侧；可取消，关闭面板后任务继续，状态栏可重新打开。

需要完整 Xcode 和 iOS SDK、Python 3.10+；App 自动搜索 Homebrew / PATH 下的 Python，也可在高级设置中指定。签名需要有效的本机证书及私钥、匹配 Bundle ID 的 Development / Ad Hoc / 企业描述文件。不会替你申请证书或下载描述文件。工具的 Python 代码随 App 打包，运行不依赖 Downloads 中的旧项目；该目录只是可选签名材料搜索位置。

编译使用源工程副本，按 IPA 主程序自动匹配 arm64 / arm64e，生成未签名 dylib，注入 `Frameworks` 并添加主程序加载项。只编译 / 注入保留原 Bundle ID；重签默认沿用旧工具的 `.regisn` 后缀，也可自定义。Hook 过滤条件在构建副本中同步适配最终 ID，原源码和原 IPA 保持不变。

默认从签名副本移除 App 扩展、Watch、App Clips 等组件，使用主 App 的描述文件签名；保留扩展的独立签名配置暂不支持。默认保留 URL Schemes；高级设置可隔离，可能影响登录回调。额外 entitlements 必须由描述文件允许。重签无法自动保留原 App 所属团队的推送、App Groups、iCloud 等能力，改 Bundle ID 也可能影响应用自身校验和服务。

每次执行在输出目录下创建独立运行目录，保存 `SourceSnapshot`、`Products`、未签名 / 已签名 IPA、校验报告、`request.json`、`result.json` 和完整 `workflow.log`。最终 IPA 会重新解包验证签名、证书、权限与描述文件。安装失败时已签名 IPA 仍保留，点击“仅重试安装”即可跳过编译和重签。安装成功后仍需在设备上启动并验证实际 Hook 行为。

每个工程的输入与签名选项保存到 `iScopeWorkflow.local.json`，不复制私钥。取消或退出 App 时会终止工作流及其活动子进程；已完成的产物保留。

无源码 IPA 也可使用独立编译的 LookinServer 调试界面。仓库提供服务端 dylib 编译、注入与重签脚本，生成的签名 IPA 可在部署面板中选择“安装已有签名 IPA”。具体步骤见 [无源码 IPA 集成 Lookin](docs/lookin.md)；当前尚未提供 App 内的 Lookin 模板开关。

空格分开的关键词采用 AND 匹配；每个中文功能词与其扩展词采用 OR 匹配。正则模式会关闭词语扩展。结果列表最多展示 1,000 条，顶部显示总数，可缩小搜索范围；完整分析导出不受该显示上限影响。导出范围是当前文件或全部已分析文件，不受搜索条件影响。

## 解析范围

- 直接解析 little-endian 64 位 Mach-O，不依赖 class-dump、Hopper、IDA 或 REA 服务。
- 支持绝对方法列表、small relative method lists、直接或间接 Selector，以及常见 dyld chained pointer 格式（64 / 64_OFFSET / arm64e / USERLAND / USERLAND24）。未支持的布局会显示提示，可能导致部分元数据缺失。
- ObjC Category 若已被链接器合并，会以所属类的方法出现。
- 字符串索引覆盖 C strings、Objective-C Selector、类名、类型编码、Swift reflection strings，以及常见的 UTF-16 常量 CFString。
- 引用扫描覆盖 ARM64 的 ADR、ADRP + ADD / LDR、literal LDR 和直接 BL。函数边界优先来自 `LC_FUNCTION_STARTS`。缺少函数边界时会显示推定范围提示。
- 引用扫描遇到未建模指令会清除寄存器状态，以减少错误归属，因此可能漏掉经过复杂指令序列的引用。
- **Selector 地址装载不等于调用某个具体类的方法**。`objc_msgSend`、虚表、动态派发、运行时拼接字符串和间接调用无法完整归属。
- 这是静态定位工具，搜索匹配和字符串引用用于生成候选方法，不能单独证明实际功能或运行时行为。
- 纯 Swift 的类型与方法主要来自保留的符号；无法恢复被剥离的原始名称。Flutter Dart / Unity IL2CPP 的方法恢复不在当前版本范围内。
- 检测到非零 `cryptid` 时保留文件信息与符号，跳过类与加密区内容，提示重新导入脱壳文件。
- 32 位和 big-endian Mach-O 可被识别，但不支持深入分析；ZIP64 / 分卷 ZIP 暂不支持。
- 字符串最多索引 500,000 条，静态引用最多 1,000,000 条；触发上限会显示提示。类与方法不会因界面显示上限而截断。
- 导入前校验 ZIP 的路径、重复条目、符号链接和展开大小，拒绝危险归档。IPA 在临时目录解包，正常退出时清理；直接导入的原始文件不会被修改。

Objective-C `.h` 为接口草稿：根据类型编码生成返回值和参数类型，参数名是占位符；属性保留原始 attributes 注释，不代表原始源码或可直接编译的完整头文件。

## 项目结构

```text
Sources/iScopeCore/       Mach-O / IPA 解析、引用索引、搜索和导出
Sources/iScopeApp/        SwiftUI 三栏界面、工作空间状态、收藏与笔记
Tests/iScopeCoreTests/    解析、检索排序、CLI 协议、Hook 工程与部署集成测试
Tests/iScopeAppTests/     功能定位结果保留、页面往返、Hook 创建与标签关闭回归测试（Swift Package）
Sources/iScopeCore/Resources/HookTools/  随 App 打包的注入、重签、设备与工作流后端
Resources/               Info.plist 和 App 图标
scripts/build.sh         构建通用 macOS App
scripts/generate_project.py  无外部依赖的 Xcode 工程生成器
```

新增 Swift 文件后运行 `python3 scripts/generate_project.py` 更新工程。运行 `python3 scripts/make_icon.py` 可重新生成几何图标。

## 验证

```sh
swift test
xcodebuild -project iScope.xcodeproj -scheme iScope \
  -destination 'platform=macOS,arch=arm64' test
```

测试需要完整 Xcode（包含 iOS SDK）。自行编译 Objective-C / Swift 测试产物，覆盖 chained fixups、传统指针、iOS arm64e 与相对方法列表、Category、协议、属性、中文 CFString 引用、Swift 符号还原、Universal 架构选择、IPA 主程序识别、危险 ZIP 路径拒绝、损坏文件、类型编码、导出，以及 Hook 工程的验证、无覆盖写入和真实 iOS dylib 构建。

智能定位测试覆盖数千个泛化 `step` 方法中的优先排序、一层调用与未命名函数、背景 / API 猜测不能单独产生候选、未知候选 / 无效证据编号拒绝、CLI stdin 与临时目录协议、进程双向管道、输出限制、超时和取消。默认不请求模型；用合成描述和测试夹具验证你现有的真实服务：

```sh
ISCOPE_LIVE_CODEX=1 swift test --filter FeatureSearchTests.testLiveCodexPlanAndCandidateReview
```

部署测试默认使用自建 iOS App 验证真实编译与注入，不安装真机。以下命令可额外使用本机签名材料验证最终 IPA（不安装），以及运行后端的阶段、失败保留、重试、设备过滤、归档校验与子进程取消测试：

```sh
ISCOPE_LIVE_SIGNING=1 swift test --filter WorkflowTests
python3 -B scripts/test_workflow.py
```

## 后续适合增加的能力

- 版本对比：对比两份 IPA 的新增 / 删除类和方法、接口与字符串变化。
- 持久化分析工程：缓存索引、跨会话保留多个 IPA，避免大型文件反复解析。
- 更完整的调用链与控制流：接入可选反汇编引擎，解析 stubs、间接调用和更多指令模式。
- 资源到代码的线索：关联 Storyboard / XIB 的控制器与 action、URL Scheme 和资源文件。
- 运行时证据关联：在用户指定的测试环境中，将实际触发功能时的调用记录关联到静态方法。
