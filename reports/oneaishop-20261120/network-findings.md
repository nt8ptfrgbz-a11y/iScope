# 网络、凭据与 WebView 静态审计

对象：`/Users/edy/Desktop/oneaishop_flutter.ipa`，IPA SHA-256 `e9ce5a54d021786dfbad315456d8f187f8313f330374c40a4ca74bfaf742f582`。应用 `com.tongchong.aishop`，版本 `2.1.201 (40)`。

本分工仅检查解包产物，并合并主审计的反汇编/REA 反编译证据；没有读取项目源代码、执行 App、访问业务服务器、验证账号或编写攻击脚本。字符串表中的偏移为解包文件内的十六进制字节偏移，**不是虚拟地址或可直接调用的 Hook 地址**；第 2 节另行标明代码分析地址。Dart AOT 快照中的可读字符串有时粘连对象标签字符，不能把附近字符串当作调用关系。

## 结论与优先级

| 项目 | 当前证据 | 影响成立的前提 | 修复优先级 |
| --- | --- | --- | --- |
| 全局允许任意网络加载 | **确认配置**：ATS `NSAllowsArbitraryLoads=true`；业务 HTTP 地址也在包内 | 生产可达流程确实使用 HTTP，且攻击者位于通信路径；仅凭静态字符串不能确认当前默认环境 | P1：先核实生产请求，关闭全局 ATS 放行并移除生产 HTTP |
| Token 持久化与调试日志 | **已确认静态存储数据流**：Token JSON 经 SharedPreferences 字符串读写；原生从 NSUserDefaults 读取 Token。日志仍仅为线索 | 有效 Token 确实写入这些路径；需应用容器读取权、相关备份/日志读取权或已注入进程 | P1：将 Refresh Token 移至 Keychain，清理旧偏好数据，并验证发布日志脱敏 |
| 发布包中的环境切换 | **确认字符串，入口可达性未知**：开发/测试 HTTP 地址、`Select Environment`、`sp_key_env_override` | 切换入口在发布环境可达，或已具备容器修改/进程注入能力；凭据是否跨环境复用未知 | P2：发布构建移除开发配置/入口，环境切换清空会话并隔离凭据 |
| WebView/JS 桥信任边界 | **确认组件存在，漏洞未证实**：桥接和 JS 相关能力；同时存在可信文档检查名称 | 不可信页面可进入有权限的桥，或可信 URL 校验/重定向处理不完整 | P1 验证、按结果定级；现有字符串不能证明绕过 |
| 服务端私钥/可复用 secret | **未确认**；存在 SDK 授权配置和一个用途不明的十六进制常量候选 | 必须先证明该值具有服务端授权/签名权限；长度或名称不能证明 | 不将公开 SDK ID/客户端授权 blob 报作密钥泄漏 |

## 1. ATS 与业务 HTTP 地址

**已观测：** `Info.plist` 解码后的 `NSAppTransportSecurity` 只有 `NSAllowsArbitraryLoads: true`，没有按域缩小范围。该设置放宽使用 ATS 的 Apple 网络栈的传输限制。Flutter/Dart socket 通信及各 SDK 的 TLS 行为仍需分别验证，不能据此概括所有请求。

App AOT 二进制同时包含以下地址：

| 文件内偏移 | 字符串 | 含义限制 |
| --- | --- | --- |
| `0xa970e0` | `http://43.143.93.58:8002/` | 业务候选 HTTP 基址，当前是否使用未知 |
| `0xc2b8f0` | `http://111.231.33.241:8004/` | 业务候选 HTTP 基址，当前是否使用未知 |
| `0xb1fda0` | `http://192.168.2.49:58080/` | 内网开发基址 |
| `0xb14570` | `http://192.168.2.55:5173/h5-v2/course/course-detail` | 内网 H5 开发地址 |
| `0xb4b840` | `http://192.168.2.55:5173/h5-v2/course/live` | 内网 H5 开发地址 |
| `0xa9b4f0` | `https://app.tctazhuyi.com/` | 同包存在 HTTPS 配置，不能断言全量明文 |
| `0xb2ef90` | `https://app.tctazhuyi.com/h5/` | H5 生产候选 |
| `0xb55000` | `https://app.tctazhuyi.com/payment/` | 支付页面候选 |
| `0xc2dc90` | `https://www.tctazhuyi.com/prod-api/` | 生产 API 候选 |

**可利用推断：** 如果登录、Token 刷新、个人信息或带鉴权的请求实际走 HTTP，路径上的攻击者可读取/修改该次通信，甚至不需要先 Hook App；如果只有开发环境使用 HTTP，则不能把该影响归到生产用户。需注意测试/反馈服务是否附带生产 `Authorization`。

**建议：** 在测试账号下被动记录生产环境的实际 URL、重定向、请求头和失败策略；关闭全局任意加载；全部敏感接口使用 HTTPS；独立检查 Dart/Dio、WKWebView 和 SDK 的网络策略。

## 2. 已确认的 Token 偏好设置存储路径；日志待验证

**已观测字符串：**

| 文件 | 偏移 | 值 |
| --- | --- | --- |
| App | `0xb98bc0` | `sp_key_token` |
| App | `0xbeee70` | `saveTokenInfo` |
| App | `0xb47060` | `getTokenInfo` |
| App | `0xc06880` | `SPHelper.getTokenInfo decode failed:` |
| App | `0xaf2750` | `tokenJsonStr >>` |
| App | `0xc65700` / `0xbd3b80` | `accessToken` / `refreshToken` |
| App | `0xc19f70` / `0xb009f0` | `Authorization` / `Bearer ` |
| App | `0xb0c840` / `0xc2b7a0` | `Request: ` / `Response: ` |
| App | `0xc34250` | `package:oneaishop_flutter/core/network/interceptors/token_interceptor.dart` |
| SharedPreferences 插件 | `0x19119` / `0xd926` | `NSUserDefaults` / `UserDefaults` |
| SharedPreferences 插件 | `0xf4a4` | `flutter.` 前缀 |

**新增、已确认的静态数据流：** 主审计的 Dart AOT 反汇编及符号映射把上述命名线索升级为可确认的读写路径：

- `HeaderInterceptor.onRequest (#3)` 的调用点 `0x5587b8` → `SPHelper.getTokenInfo`（函数起点 `0x41081c`）→ 其调用点 `0x41083c` → `SPHelper.getString`（起点 `0x4cad8`）→ 调用点 `0x4cb08` → `SharedPreferencesWithCache.getString`。`getTokenInfo` 在 `0x410860` 处进一步调用 `jsonDecode`，构成请求鉴权读取偏好设置 Token JSON 的路径。
- `SPHelper.saveTokenInfo`（函数起点 `0x580a8c`）的调用点 `0x580ac4` → `SPHelper.saveString`（起点 `0xdf55c`）→ 调用点 `0xdf5b0` → `SharedPreferencesWithCache.setString`，确认 Token 持久化使用偏好设置字符串接口。
- Runner 的 `getTokenInfo`（REA 虚拟地址 `0x100016838`）直接调用 `NSUserDefaults.standardUserDefaults` 和 `stringForKey:`，读取 `UserTokenInfoMessage` / `UserOldTokenInfoMessage` 等字段，再组合、编码为 JSON。REA 证据：`ev_36ae5463533895e4ec7a2be96740b594ff762da96417e66c13de24d29c4dce09`。

以上 Dart 数字是已保存符号映射与反汇编中的代码分析地址；Runner 数字是 REA 返回的虚拟地址，均不代表某次设备运行时地址。可复核材料：[business-extra-disassembly.txt](/Users/edy/Desktop/iScope/build/security-audit/oneaishop-20261120/business-extra-disassembly.txt)、[app-symbol-map.json](/Users/edy/Desktop/iScope/build/security-audit/oneaishop-20261120/app-symbol-map.json)、[rea-runner-evidence.json](/Users/edy/Desktop/iScope/reports/oneaishop-20261120/rea-runner-evidence.json)。

**仍未观察的内容：** 没有读取测试安装的实际偏好设置文件或看到 Token 值；没有观察到运行时完整 Token 日志。因此可报告“确认 Token JSON/Token 字段使用偏好设置字符串存储路径”，不能报告“已取得有效 Token”或“已发生外部泄漏”。`tokenJsonStr >>`、`Request:` / `Response:` 仍只是日志线索，不能单独证明敏感数据实际输出。现有证据也不排除其他路径另有 Keychain 使用。

**攻击者能 Hook 的面：** 在已经能够注入当前 App 进程的前提下，偏好设置读取、Token 读写、Dio 请求鉴权和 Flutter 平台通道都是接触会话信息的候选位置。客户端最终需要使用 Access Token；Keychain 可缩小磁盘/备份泄漏面，却不能保证已控制进程的攻击者读不到正在使用的凭据。

**验证：** 使用测试账号登录后，只检查该测试安装的应用容器与控制台；核对 `sp_key_token`、`UserTokenInfoMessage` / `UserOldTokenInfoMessage` 实际写入哪些会话字段，重启、退出登录后是否保留，日志是否打印完整 Token/请求头。只保存掩码或 SHA-256 指纹。

**修复：** Refresh Token 用合适的 Keychain 访问控制及 `ThisDeviceOnly` 策略保存；按业务需求缩短 Access Token 生命周期，支持刷新轮转、吊销与重用检测；发布构建禁用或脱敏鉴权日志；服务端重新验证权限，避免把客户端本地状态当作授权结论。

## 3. 开发配置与环境切换

除了前述 HTTP/内网地址，App 中还包含 `https://test-tc.tzyclass.com/`（`0xad2e70`）、`https://uat.tazhuyi.cn/prod/`（`0xb8fa00`）、`https://app-uat.tctazhuyi.com/h5/`（`0xc37980`），以及：

- `Select Environment`：`0xbd1050`。
- `sp_key_env_override`：`0xc03240`。
- `restoreFromPreferences`：`0xb89a00`。
- `package:oneaishop_flutter/features/setting/dev_page.dart`：`0xb72fd0`。
- `setAppConfig`：`0xc2b710`，`_syncAppConfigToNative`：`0xa84480`。

**推断：** 攻击者若能改变本地环境选择或相关参数，可能把部分业务流量切换到另一个内置环境；是否可设置任意 URL、默认值是什么、切换时是否清 Token，当前均未知。存在环境切换本身不等于服务端越权。

**建议：** 发布产物去除开发页和内网配置；不同环境隔离签名/会话 audience；切换环境强制退出并清除缓存和客户端凭据。审查原生同步配置入口是否只接受固定环境枚举。

## 4. WebView、JS 桥与 URL scheme

**已观测：** 注册自定义 scheme `aishop`；存在 WKWebView 插件、`BaseWebViewPage`、`runJavaScript`、`addJavaScriptChannel`、`_handleJavaScriptMessage` 及 `oneaishop_bridge` 字符串。

| 证据 | 文件内偏移 |
| --- | --- |
| Info.plist：`CFBundleURLSchemes` / 实际 `aishop` 值 | `0xb18` / `0xb34` |
| App：`oneaishop_bridge` | `0xbd3c60`（快照粘连尾字节不属于可确认桥名称） |
| App：`_handleJavaScriptMessage` | `0xb59b30` |
| App：`addJavaScriptChannel` | `0xbb44b0` |
| App：`runJavaScript` | `0xa9f870` |
| App：`_isTrustedDocument` | `0xb01690` |
| App：`isTrustedCourseDocument` | `0xc561a0` |
| App：`package:oneaishop_flutter/core/webview/course_h5_protocol.dart` | `0xc29720` |

**必须保留的反证：** 可信文档检查函数名确实存在，不能据桥和 JS 存在就报任意页面调用原生权限。`localStorage`、`sessionStorage` 字符串存在，也不能证明 Token 放入 H5 存储。

**验证重点：** 在自己的离线测试页面/测试环境核对来源是否严格按 scheme+完整 host+必要端口比较；处理重定向、iframe、弹窗与导航完成后的当前来源；每个桥方法限制权限和参数。确认没有把 Token 拼到 URL/query 或发给非信任来源。自定义 scheme 需要校验动作、参数和认证状态；若用于登录回调，需要独立 state/nonce/PKCE，不能仅凭 `aishop://` 就认定可信。

## 5. TLS 与密钥：没有证实的内容

App 中存在 Dart 通用 `set:badCertificateCallback`（`0xad5fd0`）、`registerBadCertificateCallback`（`0xab39b0`）；Runner 中存在 SDK/AFNetworking 的 `allowInvalidCertificates`（`0x18f09a`）及 pinning 名称。这些是能力/符号证据，**不能证明业务代码设置了信任任意证书，也不能证明已经启用证书固定**。需在测试环境分别验证系统不信任证书、域名不匹配、证书过期时是否拒绝连接。

`Info.plist` 包含 `AliyunPNSAuthKey`（字段名偏移 `0xf2`），值长 268 字符，SHA-256 `f7d5b94cef55501fe1d2b0b472600eb0b913b0c5f60b6b6365a241214e244999`。这是客户端 SDK 授权配置候选；没有证据证明其是具有服务端权限的私钥，不披露原值、不将其定性为漏洞。

App `0xac4a20` 存在一个 32 位十六进制字符串候选，快照可读段长度为 33（粘连尾字节）；该整段 SHA-256 指纹 `6cca028880883aa4b481`。用途未知，可能是客户端 SDK/许可证配置，不能单凭外观称为服务端签名 secret。Runner `0x16eb70` 的 24 位十六进制常量指纹为 `ed2ab4121319b2e43859`，同样没有确认服务端授权能力。

对 App、Runner、Info.plist 的有界模式检查未发现 PEM 私钥头、AWS Access Key ID、硬编码 JWT、长 Bearer 字面量；它不覆盖编码/拆分/加密后的常量或全部第三方 framework，也不证明包内绝对没有秘密。App 中有 `app-api/infra/appCs/configs/im-credential`（`0xb315e0`）和 `tencent_im_credential_service.dart`（`0xa81fb0`）线索，说明可能从服务端取 IM 凭据；是否按当前用户授权、限制有效期，仍需服务端验证。

## 证据文件身份与未解决问题

解包根：`/Users/edy/Desktop/iScope/build/security-audit/oneaishop-20261120/Payload/Runner.app`。

| 缩写 | 文件 | SHA-256 |
| --- | --- | --- |
| App | `Frameworks/App.framework/App` | `691eeb86a46e12ec25734fae33e7b256cafae8074a361fdf53986434a95bbf83` |
| Runner | `Runner` | `906846187a216c1dfdfaffa6bb32ee68242d99e133b256cb55c1b456890d5c02` |
| Info.plist | `Info.plist` | `96489ef40136ac332e683f0cc9ce7758f2824e5a8e6f3cde1ec97640a73bb2db` |
| SharedPreferences 插件 | `Frameworks/shared_preferences_foundation.framework/shared_preferences_foundation` | `e1fd24711c0a7de5e7c59c7643b0c3c6ebd38f128a8d93e512e77e0a4635e729` |

已回答：ATS 配置、包内网络地址/插件/scheme、Token 偏好设置字符串读写路径、公开 SDK 配置线索。部分回答：Token 日志、环境切换、WebView 防线。未回答：生产实际流量、TLS 校验结果、实际保存的 Token 值与保留周期、JS 来源检查的数据流、服务端权限/重放控制。全部利用影响仍应遵循各项列出的前提。
