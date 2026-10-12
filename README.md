# LCSign 复刻 · iOS App 路线实施方案

复刻目标：一个在设备本地完成 iOS 重签名的 App（SwiftUI + zsign 静态库），
不依赖服务端，支持「选 IPA → 选证书 → 改配置 → 签名 → 导出」。

本方案按 **阶段 0（命令行验证）→ 阶段 1（最小 App）** 推进，先把签名链路跑通，再套 UI。
不要一上来就写界面——签名跑不通的话，UI 写多少都是白写。

---

## 快速开始（不需要本地 Mac）

项目已配置 GitHub Actions，推上去就自动出包。

```bash
git init && git add -A && git commit -m "init"
git remote add origin git@github.com:<你的账号>/<仓库名>.git
git push -u origin main
```

推到 GitHub 后，Actions 会自动跑 `Build IPA` 流程：

1. 在 macOS runner 上编译 zsign 静态库（真机 + 模拟器两个切片）
2. 生成 Xcode 工程并编译 App
3. 产出 **未签名 IPA**（`LCSignClone-unsigned.ipa`）
4. **校验包完整性**（`Scripts/30_verify_bundle.py`）—— 逐个解析包内 Mach-O 的
   动态依赖，确认每一个都能在包内解析到实体文件。这一步拦的是
   「链接得上、装上去一打开就退」这类问题，见 6.6
5. 如果你配了证书密钥，同时产出 **已签名 IPA**（`LCSignClone-signed.ipa`）
6. 在模拟器上跑单元测试（描述文件解析、entitlements 比对、IPA 往返、
   以及一次真实的 ad-hoc 签名）

在 Actions 页面 → 对应那次运行 → 底部 **Artifacts** 下载即可。

> 第 6 步排在产物上传之后，是刻意的：测试红了也要先把 IPA 留下来，
> 不然一次测试失败会把能用的包一起吞掉。所以看到红叉先看是哪一步红的。
>
> 第 4 步则刻意排在打包之后、上传之前：包不完整就不该被发出去。

### 想让 CI 直接帮你签好

在仓库 **Settings → Secrets and variables → Actions** 里加三个 Secret：

| Secret | 内容 | 生成方式 |
|---|---|---|
| `P12_BASE64` | p12 文件的 base64 | `base64 -i cert.p12 \| pbcopy` |
| `PROVISION_BASE64` | 描述文件的 base64 | `base64 -i profile.mobileprovision \| pbcopy` |
| `P12_PASSWORD` | p12 导出密码 | 明文 |

配好后重新跑一次 workflow，就会多出一个已签名的 IPA，直接装到设备即可。

> **安全提醒**：Secrets 对仓库协作者可见（虽然不能回读明文，但能通过 workflow 间接使用）。
> 如果这是公开仓库，或者你不想把证书托管在 GitHub，就别配 Secrets，
> 只下载未签名 IPA，在本机用自己的工具签。**个人证书一旦泄露，别人可以拿它签任意 App**。

---

## 0. 环境前提（本地开发时）

| 项 | 要求 | 说明 |
|---|---|---|
| macOS | 13.0+ | zsign 的 iOS 静态库只能在 macOS 交叉编译 |
| Xcode | 15.0+ | 命令行工具链 |
| XcodeGen | `brew install xcodegen` | 用 `project.yml` 生成 `.xcodeproj`，避免手改 pbxproj |
| 证书 | p12 + mobileprovision | **两者必须配对**，见下一节 |
| 设备 | 一台真机 | 模拟器无法验证签名结果 |

检查环境：

```bash
./Scripts/00_check_env.sh
```

---

## 1. 证书：只有 p12 是不够的

这是最容易踩的坑，单独说清楚。

```
p12 文件            = 私钥 + 开发者证书      →  证明「你是谁」
mobileprovision    = Apple 签发的授权文件    →  说明「你能装什么、装到哪」
```

签名时必须同时提供两者，且 **Team ID 必须一致**。只有 p12 的话，
签出来的包会在安装阶段被系统拒绝（`ApplicationVerificationFailed`）。

### 从 Apple 开发者后台拿到配对的两件套

1. 登录 https://developer.apple.com/account/resources/certificates
2. **Certificates** → 创建 `iOS Development` 或 `iOS Distribution` → 下载 `.cer`
3. 双击导入钥匙串 → 在「钥匙串访问」里右键导出为 `.p12`（设置导出密码）
4. **Profiles** → 创建描述文件 → 选择 App ID 与证书 → 下载 `.mobileprovision`
5. **Devices** → 如果做 Ad Hoc，需先把目标设备的 UDID 加进白名单（上限 100 台）

### 三个硬性匹配规则

| 规则 | 不满足的后果 |
|---|---|
| 描述文件的 **Team ID** = 证书的 Team ID | 签名报错 |
| 描述文件的 **App ID** 能覆盖目标 App 的 Bundle ID | 签名成功但安装失败 |
| 目标 App 的 **entitlements** ⊆ 描述文件授权的权限 | 签名成功但启动即闪退 |

第三条是「签完能装、一打开就崩」的头号原因。调试时优先怀疑它。

### 免费 Apple ID 的情况

免费账号只能通过 Xcode 自动生成 7 天有效期的证书与描述文件，
签名后 App 每 7 天失效一次。本项目的 `CertificateStore` 已预留到期提醒字段。

---

## 2. 阶段 0：先用命令行验证签名链路

**目标：不写一行 UI，先确认 zsign 能用你的证书签出能装的包。**

```bash
# 1. 编译 zsign 为 iOS/macOS 静态库
./Scripts/10_build_zsign.sh

# 2. 用命令行重签一个测试 IPA
./Scripts/20_resign_cli.sh \
    --ipa   /path/to/input.ipa \
    --p12   /path/to/cert.p12 \
    --pass  'your-p12-password' \
    --prov  /path/to/profile.mobileprovision \
    --out   /path/to/output.ipa
```

签完后用 Xcode 的 **Devices and Simulators** 或 Apple Configurator 安装到真机。
**装得上、能启动 = 阶段 0 通过**，可以进入阶段 1。

> 阶段 0 失败时按这个顺序排查：
> 1. p12 密码对不对（`openssl pkcs12 -in cert.p12 -noout` 验证）
> 2. 描述文件与证书 Team ID 是否一致（`security cms -D -i profile.mobileprovision`）
> 3. Bundle ID 是否在描述文件覆盖范围内
> 4. entitlements 是否超出授权（对比描述文件里的 `Entitlements` 段）
> 5. 设备 UDID 是否在描述文件白名单里

### 本地开发循环

```bash
./Scripts/10_build_zsign.sh     # 先编静态库，否则下面链接不到 -lzsign
xcodegen generate               # 生成 .xcodeproj

# 跑测试（模拟器）。这一步会真跑一次 ad-hoc 签名，不用证书
xcodebuild test \
    -project LCSignClone.xcodeproj \
    -scheme LCSignClone \
    -destination 'platform=iOS Simulator,name=iPhone 15'

# 装到模拟器上点着看
xcodebuild -project LCSignClone.xcodeproj -scheme LCSignClone \
    -destination 'platform=iOS Simulator,name=iPhone 15' build
```

`10_build_zsign.sh` 默认同时编真机（arm64）和模拟器（arm64 + x86_64）
两个切片，因为单元测试要跑在模拟器上。只想出真机包时传
`PLATFORMS=iphoneos` 能省掉一半编译时间。

---

## 3. 阶段 1：最小可用 App

只做五件事，其他全部砍掉：

```
选 IPA → 选 p12 输密码 → 选描述文件 → 点签名 → 导出/分享
```

**明确不做**（留到后续阶段）：越狱注入、本地 HTTP/WebDAV 服务、
plist 树形编辑器、软件源解析、备份格式、插件系统、灵动岛、自更新。

### 装到设备后，先点一次「诊断」

第一次用真机跑这个 App，别急着导证书 —— 先点右上角的**诊断**，
跑一次引擎自检。

> 前提是 App 得能打开。如果**点开图标就闪退**，那跟证书、跟引擎都没关系，
> 是包本身缺了动态依赖，看 6.6。

自检**不需要任何证书**，它会临时构造一个 .app（可执行文件用的是
`LCSignCore.framework` 自己那段真实的 Mach-O），完整跑一遍
「打包 → 解包 → ad-hoc 签名 → 校验 `_CodeSignature/CodeResources`」。

它的价值在于把失败原因切开：

| 自检结果 | 说明 |
|---|---|
| 通过 | 引擎没问题。之后真签名再失败，**一定**是证书 / 描述文件的问题 |
| 不通过 | 引擎侧的问题（静态库没链上、架构不对、沙盒写不了临时目录…），跟证书无关 |

没有这一步的话，两类原因会混成同一句「签名失败」，排查方向全靠猜。

> ad-hoc 签名在 zsign 里是「不校验身份、只写一个固定的空 CMS 槽」的模式，
> 所以签出来的包装不了 —— 它只用来证明引擎活着，不是可用的产物。

同一段代码在 CI 里也有对应的测试用例（`EngineSelfTestTests`），
跑在模拟器上。模拟器过不了，真机上也好不了。

---

## 4. 目录结构

```
LCSignClone/
├── project.yml                       XcodeGen 工程定义
├── Scripts/
│   ├── 00_check_env.sh               环境检查
│   ├── 10_build_zsign.sh             编译 zsign 静态库（真机 + 模拟器）
│   ├── 20_resign_cli.sh              阶段 0：命令行重签
│   ├── 30_verify_bundle.py           IPA 包完整性校验（动态依赖 + Info.plist）
│   └── zsign_shim/                   zsign C++ 引擎的纯 C 门面（唯一来源）
│       ├── zsign_shim.h
│       └── zsign_shim.cpp
├── Tests/
│   └── LCSignCoreTests/              单元测试（跑在模拟器上）
│       ├── TestSupport.swift         造描述文件 / 临时目录 / .app 的工具
│       ├── ProvisioningProfileTests.swift
│       ├── SigningCertificateTests.swift
│       ├── IPAArchiveTests.swift     含 zip slip 防护
│       └── EngineSelfTestTests.swift 真跑一遍 ad-hoc 签名
└── Sources/
    ├── LCSignClone/                  UI 层（iOS App target）
    │   ├── LCSignCloneApp.swift
    │   ├── Info.plist
    │   ├── AppModel.swift            界面状态与签名任务编排
    │   └── Views/
    │       ├── HomeView.swift        主界面：任务列表
    │       ├── SignSheet.swift       签名表单
    │       ├── CertificateRow.swift  证书展示 / 证书库 / 导入
    │       └── DiagnosticsView.swift 诊断页：跑引擎自检 + 环境信息
    └── LCSignCore/                   核心层（framework target）
        ├── SigningRequest.swift      签名参数模型
        ├── SigningService.swift      签名编排（核心）
        ├── SigningError.swift        错误定义
        ├── CertificateStore.swift    证书库 + 钥匙串
        ├── SigningCertificate.swift  证书模型（含有效期）
        ├── ProvisioningProfile.swift 描述文件解析 + 授权比对
        ├── IPAArchive.swift          IPA 解包/打包
        ├── EngineSelfTest.swift      不依赖证书的引擎自检
        ├── include/
        │   ├── LCSignCore.h          伞形头文件（umbrella header）
        │   └── ZSignBridge.h         Objective-C++ 桥接接口
        └── ZSignBridge.mm            桥接 zsign C++ API
```

> `Scripts/zsign_shim/` 是 shim 的**唯一来源**：`10_build_zsign.sh` 编译它，
> 并把它拷到 `Vendor/zsign/include/` 供 Xcode 侧的桥接层 include。
> 所以 `Vendor/` 整个目录都在 `.gitignore` 里，不要往里放源码。

> **为什么是伞形头文件而不是桥接头**：framework target 不支持桥接头
> （Xcode 直接报 `using bridging headers with framework targets is unsupported`）。
> Apple 给 framework 的做法是 `DEFINES_MODULE = YES` + 把要暴露给 Swift 的
> ObjC 头文件 import 进伞形头文件 `LCSignCore.h`。文件名必须与模块名一致。

---

## 5. 集成 zsign 的三种方式

| 方式 | 优点 | 缺点 | 建议 |
|---|---|---|---|
| **A. 自编 XCFramework** | 可控、无外部依赖 | 需要处理 OpenSSL 交叉编译 | **推荐**，`10_build_zsign.sh` 走这条路 |
| B. CocoaPods | 一条命令 | 依赖第三方 pod 的维护状态 | 快速验证时可用 |
| C. 打包 zsign CLI 可执行文件 | 最简单 | 沙盒内无法 fork 子进程执行 | **不可行**，iOS 不允许 |

选 A。zsign 本身是 C++，需要 OpenSSL、libz、libbz2。
OpenSSL 用 `krzyzanowskim/OpenSSL` 或 `OpenSSL-Universal` 提供的 iOS 版本。

---

## 6. 已知的坑

### 6.1 iOS 16+ 的 DER entitlements

iOS 16 起，系统除校验传统 plist 格式的权限外，还会校验
`__TEXT,__entitlements` 段中的 **DER 编码**版本。只写 plist 不写 DER，
会出现「签名成功但启动闪退」。zsign 已支持，但需要正确传入 entitlements。

### 6.2 沙盒限制

iOS App 无法把文件写进 `/Applications`，也无法 fork 子进程。
所以「签名」必须在 App 进程内用静态库完成（这也正是 zsign 要编成静态库的原因），
而「安装」必须交给系统机制或第三方工具。

### 6.3 itms-services 走不通

`itms-services://` OTA 安装要求 **HTTPS + 受信任证书**，
自签证书 iOS 不认。所以原版的 `LocalIPAServer` 实际用途是
「局域网内给其他设备下载 IPA」，而不是直接触发安装。
阶段 1 直接砍掉，导出 IPA 让用户自己导入 AltStore/TrollStore 更实在。

### 6.4 大文件内存

一个 IPA 解包后可能几百 MB。`IPAArchive` 用流式解压，
不要一次性 `Data(contentsOf:)` 读进内存，否则大包必崩。

### 6.5 签名的耗时

签名是 CPU 密集操作（RSA + 逐文件 SHA256），几百 MB 的包可能耗时数十秒。
必须放到后台线程并给进度反馈，否则主线程卡死被系统杀掉。
`SigningService` 已用 `actor` 隔离。

### 6.6 动态依赖没被嵌进 App 包（装上去一打开就退）

**这是本项目实际踩过的坑，也是最难自查的一类**：构建全程绿灯、IPA 也能正常打出来，
但装到设备上一打开就被 dyld 终止，崩溃日志里长这样：

```
Exception Type:  EXC_CRASH (SIGABRT)
Termination Reason: DYLD, [0x1] Library missing
  Library not loaded: @rpath/OpenSSL.framework/OpenSSL
  Referenced from: /var/containers/Bundle/Application/.../LCSignClone.app/Frameworks/LCSignCore.framework/LCSignCore
  Reason: tried: '.../LCSignClone.app/Frameworks/OpenSSL.framework/OpenSSL' (no such file)
```

根因：SwiftPM 的 `krzyzanowskim/OpenSSL` 产物是**动态框架**，而
`LCSignCore` 链接了它。`xcodebuild` 只保证「链接时找得到」（从 DerivedData 里），
**不保证「打包后运行时还找得到」**；而 Xcode 也**不会**递归嵌入「被嵌入框架」的动态依赖。
只把 OpenSSL 声明在 `LCSignCore` 上，就没有任何 target 负责把它拷进 `.app/Frameworks/`。

修法是在 **application target** 上也声明一次（见 `project.yml`）：

```yaml
dependencies:
  - target: LCSignCore
  - package: OpenSSL
    product: OpenSSL
    embed: true      # 注意：对 package 依赖，embed 默认是 false，必须显式写
```

两个容易踩的点：

- XcodeGen 对 **target 依赖**的 `embed` 有 `?? target.type.shouldEmbed(...)` 兜底
  （application target 默认 true），但对 **package 依赖**是严格判断
  `if dependency.embed == true`（`PBXProjGenerator.swift` 第 986 行）。
  也就是说 package 依赖**不写 `embed: true` 就是 false**，不存在「application target 自动嵌」这回事。
- `EngineSelfTest` 抓不到这个错。它测的是「合成 .app 的 ad-hoc 签名」，
  压根不涉及动态框架嵌入 —— 引擎再健康，包还是缺文件。
  所以必须另加一步**静态**校验：`Scripts/30_verify_bundle.py`。

自查手法（不依赖 macOS）：

```bash
# 看包内某个 Mach-O 依赖了什么
python3 Scripts/30_verify_bundle.py 你的包.ipa
```

它会逐个解析 `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` / `LC_REEXPORT_DYLIB` 等加载命令，
把 `@rpath/` `@loader_path/` `@executable_path/` 三类前缀按包内布局解析一遍，
解析不到就报红并退出码 1。CI 里已经接上这一步。

---

## 7. 与原版的差异

原版有几个东西**不建议复刻**：

- **`.lcres` 加密载荷 + `KeystreamProvider`**：那是作者给自己代码加的保护，
  2.8 MB 的加密运行时引擎纯属反分析措施，你的项目不需要
- **内嵌公共证书 `i.lcsignx.com.p12`**：共享证书会被 Apple 批量吊销，
  连带影响所有使用者，风险高于收益
- **越狱注入能力**：dylib 注入需要 MobileSubstrate/substitute 环境，
  受众窄且增加合规风险

砍掉这三块，项目复杂度能降一大截，核心功能不受影响。

---

## 8. 法律边界

重签名技术本身是双用途的（企业内部分发、自用调试、越狱开发均属正当场景），
但**对第三方商业应用去签名保护、修改后重新分发**可能违反著作权法
与 Apple 开发者协议。请仅用于自己拥有权利的应用。
