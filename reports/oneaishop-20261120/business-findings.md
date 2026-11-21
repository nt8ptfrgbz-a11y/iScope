# oneaishop_flutter.ipa：认证与业务 Hook 面静态审计

日期：2026-11-20。仅分析用户提供的 IPA 解包产物，没有读取应用项目源代码、运行 App、请求业务服务器或生成攻击脚本。

## 身份与地址约定

- IPA SHA-256（主调查已核对）：`e9ce5a54d021786dfbad315456d8f187f8313f330374c40a4ca74bfaf742f582`。
- 以下 `App` 指 `Payload/Runner.app/Frameworks/App.framework/App`；SHA-256：`691eeb86a46e12ec25734fae33e7b256cafae8074a361fdf53986434a95bbf83`，14,514,128 字节。
- 匹配符号文件：`Symbols/0C7143A3-CBEB-C9ED-4C4F-F302E944EB58.symbols`；SHA-256：`1b888666362b6df62244ca7b33ae2b1f4ad5667219249956b85a2e90d1c5895d`，6,435,116 字节。
- `dwarfdump --uuid` 确认 App arm64 UUID 正是 `0C7143A3-CBEB-C9ED-4C4F-F302E944EB58`。`lipo -detailed_info` 确认 FAT 内 arm64 slice 从文件 `0x4000` 开始；`otool -l` 确认 `__TEXT.vmaddr=0`、`cryptid=0`。
- 下文“VA”为未加 ASLR slide 的 arm64 地址；该 App 的代码 VA 对应整个 FAT 文件字节偏移 `VA + 0x4000`。注明“文件偏移”的字符串位置已经包含 FAT slice 偏移，不能再加 `0x4000`。
- 函数名来自包内匹配 UUID 的 `.symbols`，用 macOS `symbols -arch arm64 <file> -lookup ...` 解码；直接 `bl` 调用由 `llvm-objdump` 指令核对。没有把 Dart 函数名误称为 Objective-C selector；Dart AOT 需要不同的运行时适配和调用约定。

## BIZ-01：客户端解密 IM 配置并本地生成 UserSig，需优先确认服务器是否下发全局签名密钥

**证据等级：客户端行为已确认；全局签名密钥分发与身份冒用影响尚未验证。优先级：高。**

这不只是二进制中存在 `secretKey` 一词：调用链已经能从打包的指令与符号交叉确认。

| 证据点 | App VA / FAT 文件偏移 | 已确认事实 |
|---|---|---|
| `TencentImCredentialService.loadLoginInfo` | `0x44d590` / `0x451590`，长度 `0x200` | 入口取 IM 登录资料 |
| `loadLoginInfo` 的直接调用 | `0x44d5cc` / `0x4515cc` | 调 `CsRepository.getImCredential`（VA `0x452720`），随后等待结果 |
| `AppApi.getImCredential` | `0x452754` / `0x456754`，长度 `0xb0` | VA `0x45279c` 调 `DioMixin.get (#2)`；响应由 `ImCredentialResp.fromJson` 解析 |
| 配置响应模型 | `ImCredentialResp.fromJson`，VA `0x452838` / `0x456838` | 从 JSON 取两个字段，转换为字符串，分别存到对象 `+0x7`、`+0xf` |
| 两次配置解密 | 调用点 VA `0x44d688`、`0x44d6c4` | 两个响应字段均交给 `_decryptCredentialField`；第一项解密后 `int.tryParse` 并要求大于 0，第二项解密后要求非空 |
| 本地签名 | 调用点 VA `0x44d6ec` / `0x4516ec` | 把上面的整数、解密的第二字段、调用方提供的第三输入交给 `_generateUserSig` |
| `TencentImCredentialService._generateUserSig` | `0x44d7a8` / `0x4517a8`，长度 `0x330` | 读取当前时间，组装签名数据，执行 HMAC，输出签名结构 |
| HMAC 参数与计算 | VA `0x44d90c`、`0x44d92c`、`0x44d93c`、`0x44d948` | 依次调用 `Utf8Encoder.convert`、`new Hmac`、`Utf8Encoder.convert`、`Hmac.convert`；第二个解密字段保存在 `generateUserSig` 的栈槽 `-0x10`，从此槽送入前一项 UTF-8 编码，再送入 HMAC 构造 |
| 签名封装 | VA `0x44d9e4`、`0x44da68`、`0x44da84`、`0x44da8c` | 经过 base64、JSON、压缩和 base64；与腾讯 UserSig 生成结构一致 |
| `TencentImCredentialService._decryptCredentialField` | `0x44de28` / `0x451e28`，长度 `0x368` | base64 解码后使用 AES / CBC / PKCS7，最终输出 UTF-8 文本 |
| 解密组件调用 | VA `0x44e03c`、`0x44e044`、`0x44e04c`、`0x44e0e0`、`0x44e0e8`、`0x44e124` | 分别是 `PKCS7Padding`、`CBCBlockCipher`、`AESEngine`、`ParametersWithIV`、`KeyParameter`、`PaddedBlockCipherImpl.process` |

补充字符串证据均位于 App 本体：

| 字符串 | App 整文件偏移 |
|---|---|
| `app-api/infra/appCs/configs/im-credential` | `0xb315e0` |
| `sdkAppId` | `0xc1a7e0` |
| `secretKey` | `0xb7c0d0` |
| `TLS.identifier:` / `TLS.identifier` | `0xbb52f0` / `0xc665d0` |
| `TLS.sdkappid:` / `TLS.sdkappid` | `0xb5c111` / `0xc31d50` |
| `TLS.expire:` / `TLS.expire` | `0xb9ca31` / `0xbac4a0` |
| `TLS.sig` | `0xc72b20` |

**可 Hook 的边界与前提：** 攻击者需要能控制该 App 的运行进程（例如自己重新签名安装的副本或受控测试设备）。在返回模型、配置解密结果、HMAC 构造输入或 IM 登录资料返回处，可以观察到用于本地签名的明文材料；仅在传输中给配置加密，不能防止本应用进程观察解密后的材料。

**潜在影响：** 若第二个字段是该生产 SDKAppID 共用的长期 `secretKey`，则一名能取得此配置的用户，可能得到为其他 identifier 生成有效 IM 身份凭证的能力。这比“修改本机显示已登录”严重得多，可能涉及 IM 身份冒用及会话权限。若服务器下发的是严格限制身份和范围的临时派生材料，则影响需要重新评估。

**仍待确认：** 两个 JSON 常量键到 `sdkAppId` / `secretKey` 的对象池绑定未在本分工中完整解析；没有取线上响应、拿到完整签名密钥、生成他人 UserSig 或测试腾讯 IM 接受行为；调用方第三输入的身份来源与服务器绑定关系也未完成审计。不能将“存在客户端 HMAC 签名路径”写成“已成功冒充任意用户”。

**建议：** 服务端保存 IM 全局密钥，基于已认证的本用户身份在服务端签发短期 UserSig，客户端只接收自己的 UserSig。禁止通过任何配置接口把全局签名密钥（包括可在客户端解密的形式）交给客户端；若确认已有此分发，应优先轮换密钥并审计签发与 IM 登录日志。

## BIZ-02：Token 的当前 Flutter 读写走普通首选项，存在明晰的提取与替换边界

**证据等级：存储与请求侧读取调用已确认；不代表可跨 iOS 沙箱读取其他应用。**

| 证据点 | App VA / FAT 文件偏移 | 已确认事实 |
|---|---|---|
| `HeaderInterceptor.onRequest (#3)` | `0x5583c8` / `0x55c3c8` | 该请求拦截函数 VA `0x5587b8` 调 `SPHelper.getTokenInfo` |
| `SPHelper.getTokenInfo` | `0x41081c` / `0x41481c` | VA `0x41083c` 取字符串；VA `0x410860` 进行 `jsonDecode`；VA `0x41088c` 构造 `TokenEntity.fromJson` |
| `SPHelper.getString` | `0x4cad8` / `0x50ad8` | VA `0x4cb08` 直接调用 `SharedPreferencesWithCache.getString` |
| `SPHelper.saveTokenInfo` | `0x580a8c` / `0x584a8c` | VA `0x580ac4` 调 `SPHelper.saveString` |
| `SPHelper.saveString` | `0xdf55c` / `0xe355c` | VA `0xdf5b0` 调 `SharedPreferencesWithCache.setString` |

App 中的相关字符串：`sp_key_token` 位于整文件 `0xb98bc0`、`accessToken` 位于 `0xc65700`、`refreshToken` 位于 `0xbd3b80`、`Bearer ` 位于 `0xb009f0`、`Authorization` 位于 `0xc19f70`。这里字符串为键或协议标签，没有输出用户 token。

**可 Hook 的边界与前提：** 能控制当前进程的攻击者可观察 `getTokenInfo`、JSON 解析结果、请求拦截器或首选项读写。若测试设备存在可读 App 容器/备份，也应核查 token 持久化文件的备份及 Data Protection 配置。重新签名安装的副本默认不因此获得原 App 的容器权限。

**潜在影响：** 可窃取或替换自己所控制进程中可见的会话、维持会话重放；实际接管其他账号仍需要取得该账号的有效凭证。跳过 401 处理或改本地登录标志，不能让正确验证 token 的服务器接受无效凭证。

**仍待确认：** token 是否有设备/会话绑定、服务端撤销、刷新轮换、有效期、登出即时失效，以及首选项是否被备份。主调查另在 Runner 原生兼容桥接确认 `NSUserDefaults` 读取旧 token 键；那条历史兼容路径与这里当前 Flutter 调用链应分别描述。

**建议：** 将长期会话凭证放到合适访问等级的 Keychain；限制敏感 token 的备份迁移，并在服务端执行刷新轮换、撤销和异常会话检测。Keychain 不能让已完全受控的本应用进程变得可信；最终授权仍必须由服务器执行。

## BIZ-03：旧课程存在可操纵的课时状态与完成上报边界

**证据等级：指令调用顺序和上报结构已确认；虚假完课、越权看课或付费绕过均未被证明。**

`CourseVideoNotifier.selectPeriod`（VA `0x5deccc`，FAT 偏移 `0x5e2ccc`，长度 `0x16c`）先比较当前课时与目标课时 ID；目标不同后更新本地状态，VA `0x5dedfc` 调用 `OldRepository.finishPeriod`，等待该调用返回，然后 VA `0x5dee18` 才触发 `CourseVideoPageState._playVideo`。该调用携带的是目标课时对象 `+0x7` 中取得的整数值（保存于 `selectPeriod` 栈槽 `-0x28`）。

`OldRepository.finishPeriod`（VA `0x5dee68`）转调 `OldApi.finishPeriod`（VA `0x5dee9c`，FAT 偏移 `0x5e2e9c`，长度 `0x2ac`）。后者构造只有一对键值的 Map（一个常量键和传入整数），VA `0x5def38` 调用 `DioMixin.post`。App 中 `api/course/finishPeriod` 位于整文件 `0xb22b70`，`periodId` 位于 `0xc01cb0` / `0xc02460`。上述函数里没有看到播放时长、播放完整性或服务端挑战证明被加入此 Map；常量键与 URL 对象池的精确绑定尚未完成。

其他定位到的课程边界：

| 函数 | App VA | 已有证据 |
|---|---|---|
| `CourseVideoNotifier.loadPeriodList` | `0x6274e0` | 真实代码符号，可作为服务端课时列表进入客户端的审查点 |
| `OldApi.getCourseVideoPeriodList` | `0x627824` | 真实代码符号；对应同名 API 路径字符串在包内 |
| `CourseApi.getCourseEntryUrl` | `0x47c758` | 真实代码符号，适合核查 H5/SSO 播放入口授权 |
| `AppData.isSeriesCourseUser` | `0x630ad4` | 从本地静态用户资料取值并调用下项 |
| `UserInfo.isSeriesCourseUser` | `0x630b18` | 读取用户对象 `+0x67` 处字符串对象，依据其长度是否为零返回布尔值；这是本地判断 |

**可 Hook 的边界与前提：** 控制 App 进程后可改本地会员/课程状态、课时参数、返回列表、播放地址和上报调用时机。如果媒体地址已进入客户端，攻击者也可观察该地址。

**潜在影响：** 本地会员展示或页面入口可被改；若服务器仅凭课时 ID 的一次请求就记为完成，可能接受并未实际观看的学习记录；若播放接口不重新验证课程归属，则存在付费内容访问风险。

**仍待确认：** `finishPeriod` 在服务器上的真实含义（点击记录、开始学习还是完成学习）、是否验证用户与课时归属、进度时序、重复上报、播放地址是否短期且绑定用户，以及旧课程 API 是否仍是生产有效路径。当前审计没有证明服务器接受虚假进度，也没有证明修改该布尔值能取到付费媒体。

**建议：** 用服务端课程归属检查保护课程列表、SSO 入口和真实播放凭据；将“开始播放/打开课时”与“完成课时”分开记账；若完课产生权益或考核结果，基于服务端可验证的进度状态推进。短期媒体签名和服务端授权应独立于本地 `isVip` / `isSeriesCourseUser`。

## BIZ-04：本 IPA 随包附带精确 Dart 业务符号，显著降低定位 Hook 点的成本

**证据等级：已确认。** 对匹配 UUID 的 `.symbols` 执行通配符查询，解析获得 33,865 条 App 地址/长度/名称记录。包含 `TencentImCredentialService`、token 拦截与存取、课程/订单仓库、H5 入口、学习记录等具体业务函数；原 App 的常规 `nm` 则仅暴露四个 Dart snapshot 根符号。

例如符号文件本身的字符串偏移：`TencentImCredentialService._generateUserSig` 为 `0x57e42e`，`SPHelper.getTokenInfo` 为 `0x573e28`，`SPHelper.saveTokenInfo` 为 `0x5acacd`，`OldApi.finishPeriod` 为 `0x5bcc2d`。这些名称还带有可解析到精确 VA 的索引。

**影响与限制：** 获取此 IPA 的攻击者无需先靠猜测恢复大量业务地址。符号泄漏本身不赋予签名、安装、注入权限，也不说明 App Store 最终下载包包含相同 `Symbols/` 目录；结论仅针对用户提供的这一份 IPA。

**建议：** 外发/分发 IPA 只包含安装所需内容，将 dSYM、`.symbols` 与 Dart split-debug-info 单独保存到受控符号服务器；用适当的发布混淆降低名称暴露。去符号和混淆不是服务器授权的替代品。

## 范围检查与未证实事项

| 用户关心的方向 | 本分工结论 |
|---|---|
| 登录与 token | 已确认普通首选项读写链和请求侧读取点；服务端会话安全未知 |
| IM 登录与权限 | 已确认客户端解密配置、本地 HMAC/UserSig 生成；全局密钥范围及冒用接受行为未知 |
| 会员 | 已确认本地系列课用户判断函数，另有 `isVip` 字符串（App 整文件 `0xba8eb0`）；未证明改状态能提升服务器权限 |
| 课程/解锁/学习进度 | 已确认课时选择与 `finishPeriod` 调用顺序；实际权益判断及进度接受规则未知 |
| 支付/订单/售后 | 包内有 `OrderRepository.getOrderDetail`、`getOrderPage`、`applyAfterSale` 与订单 API 路径；此轮未反编译完整校验链，不能声称支付成功回调可伪造为真实订单 |
| 余额/积分 | 本次对 App 字符串与符号的定向搜索未定位足以建立余额/积分可修改业务的证据；“payAmount/points”等零散词不构成可利用性证明 |

本报告未识别或测试可从普通远程攻击者直接利用的内存破坏漏洞。大多数 Hook 前提是攻击者先控制客户端执行环境；真正需要避免的是服务器把可被 Hook 的客户端数据当作最终身份、支付或权益凭证。

## 本地复核材料

全部位于 `/Users/edy/Desktop/iScope/build/security-audit/oneaishop-20261120/`：

- `app-symbol-map.json`：从 IPA 内匹配符号文件解析的 33,865 个符号条目。
- `business-focused-disassembly.txt`：IM 配置/本地签名、token 存取、课时上报和会员判断的局部反汇编，已用包内符号注释直接调用。
- `business-extra-disassembly.txt`：首选项存取和请求拦截器的补充反汇编。
- `business-call-evidence.json`：局部反汇编中直接调用的地址及符号映射。
- `business-im-disassembly.txt`：最初独立保存的 IM 相关局部反汇编。

这些是静态审计产物，包含地址、函数名和指令，没有用户 token、完整密钥或可运行的 Hook/攻击脚本。
