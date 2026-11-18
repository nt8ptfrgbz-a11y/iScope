# 为无源码 IPA 加入 Lookin

Lookin 的 Mac 客户端在 https://github.com/hughkli/Lookin，可直接从
https://lookin.work/get/ 下载发布版，无需编译客户端。
IPA 内需要的是 https://github.com/QMUI/LookinServer 的服务端代码。

以下操作需要脱壳的 iOS IPA 或完整 `.app`、Xcode、Python 3.10+，以及有效的本机签名材料。
不需要目标 App 的源码。所有打包与签名操作均在副本中进行。

## 编译服务端

在 iScope 仓库根目录执行：

```sh
git clone --depth 1 https://github.com/QMUI/LookinServer.git build/LookinServer
python3 scripts/build_lookin_server.py \
  --source build/LookinServer \
  --output build/LookinDebug/LookinServer.dylib
```

默认编译 arm64 / iOS 15+ 的 Objective-C Core。需要包含 arm64e 时传入
`--arch arm64 --arch arm64e`，或通过 `--minimum-ios` 指定部署版本。
输出文件已经存在时，请使用新的输出路径。

脚本显式启用 `SHOULD_COMPILE_LOOKIN_SERVER`，直接链接全部 Core 的实现文件，
保留 Category 与 `+load`。服务端在 App 启动时自动加载，在 App 进入前台后监听
本机端口 47175–47179，供 Mac 客户端通过 USB 连接。
产物依赖 Apple 系统库；签名在打包阶段完成。

旁边的 `.build.json` 记录源码提交、架构、部署版本、依赖和 dylib SHA-256。
当前模板没有启用可选 Swift reflection 模块，不能将它视为完整的 Swift 对象检查支持。

## 注入和签名

```sh
python3 scripts/package_lookin.py \
  --input /path/to/Payload/YourApp.app \
  --dylib build/LookinDebug/LookinServer.dylib \
  --output-directory build/LookinDebug/IPA \
  --bundle-id com.example.yourapp.lookin \
  --display-name 'YourApp Lookin' \
  --device-udid YOUR_DEVICE_UDID
```

输入也可以是 `.ipa`。省略 `--bundle-id` 时，在输入 Bundle ID 后追加 `.lookin`。
默认自动匹配本机证书和描述文件，可以用 `--profile`、`--identity` 手动指定，或通过
`--profile-search-directory` 增加描述文件搜索位置。

复用 iScope 的注入及重签后端，检查架构、必需动态库和 Mach-O 头部空间，
完成嵌套代码签名，再解包最终 IPA 复验签名、权限与描述文件。
签名副本默认移除需要独立描述文件的扩展，保留 URL Schemes。
每次执行创建独立目录，保存未签名 IPA、已签名 IPA、校验报告与 `result.json`。

## 安装与连接

1. 在 iScope 的“编译与部署”面板选择“安装已有签名 IPA”，选择生成的 `Lookin-signed.ipa`。
2. 连接并解锁 iPhone，信任 Mac，选择设备后安装。
3. 在手机上打开调试版 App 并保持前台，再在 Mac 打开 Lookin。
4. 在 Lookin 中选择设备和 App，加载界面层级。通过控件找到所属视图类和控制器，
   将类名带回 iScope 搜索，并用候选方法的 Hook 日志继续验证业务调用。

Lookin 连接依赖进程内服务端，无需 LLDB 附加权限。注入、签名和安装成功仍需要
真机启动及客户端连接验证。它主要观察运行时 UI 对象，不会自动恢复业务源码或确定完整业务调用链。
不同 Bundle ID 的调试副本使用独立沙盒；原 App 的登录状态不会自动迁移。

官方要求 LookinServer 仅用于调试，不能随 App Store 发布包一起交付。
