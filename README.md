<p align="center">
  <img src="assets/app-icon-display.png" width="112" alt="Mac-TaskManager 图标" />
</p>

<h1 align="center">Mac-TaskManager</h1>

<p align="center">
  <strong>给 macOS 的原生任务管理器：看清负载，提前散热，始终把控制权留给你。</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-111827?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 13+" />
  <img src="https://img.shields.io/badge/Native-Swift%20%2B%20SwiftUI-0A84FF?style=for-the-badge&logo=swift&logoColor=white" alt="Native Swift and SwiftUI" />
  <img src="https://img.shields.io/badge/Monitoring-Local--first-14B8A6?style=for-the-badge" alt="Local first monitoring" />
  <img src="https://img.shields.io/badge/Fan%20control-Safe%20bounds-F59E0B?style=for-the-badge" alt="Safe fan control bounds" />
</p>

<p align="center">
  不是虚拟机，不是远程桌面，也不是套壳网页。<br />
  <strong>Mac-TaskManager</strong> 是一款原生 macOS 应用，用 Windows 任务管理器的高信息密度视图，呈现 Mac 的真实运行状态。
</p>

<p align="center">
  <img src="assets/mac-taskmanager-processes.png" alt="Mac-TaskManager 进程监控页" width="900" />
</p>

---

## 你能得到什么

| 模块 | 不只是“看数据” |
| --- | --- |
| **进程** | 按应用与后台进程分组，展开子进程；实时查看 CPU、GPU、内存、磁盘、网络与 PID；支持搜索、运行新任务、退出或强制退出。 |
| **性能** | 以任务管理器式视图集中呈现系统资源状态，帮助你迅速定位“谁在吃资源”。 |
| **风扇** | 读取 AppleSMC 风扇与温度传感器；手动转速永远钳制在当前硬件报告的安全最小/最大 RPM 之间，可一键交还 macOS 自动控制。 |
| **清凉模式** | 不只按当前温度查表：结合 CPU、GPU、内存、磁盘吞吐、SMC 温度与升温趋势，提前判断散热压力并主动调节风扇。 |
| **诊断日志** | 默认不留存。你可以主动开启最近 60 分钟的本地监控、风扇与清凉模式决策记录，再导出为 ZIP 诊断包。 |
| **原生体验** | 支持浅色、深色、跟随系统主题；保留 Dock 图标与顶部状态栏入口，点击状态栏可快速查看正在运行的应用。 |

> 当前构建仅使用无需账号或证书的 ad-hoc 签名保证 App 完整性，不使用公司或其他开发者证书，也不提交 Apple 公证。进程、性能与可读取的风扇和温度数据可直接使用。首次点击“启用完整功能”并在系统窗口完成管理员授权后，即可安装风扇服务，在受支持机型上使用手动调速与清凉模式；正常重启和日常使用无需反复输入密码。

## 一眼看懂清凉模式

清凉模式的目标不是宣称“直接测得键盘或掌托表面温度”——应用并不这样做。它是一个本地、确定性的短时散热压力预测器：在系统温度真正冲高前，先根据工作负载和温升趋势提高散热力度。

```text
CPU / GPU 占用 ─┐
内存 / 磁盘吞吐 ├─> 负载平滑 + SMC 温度反馈 + 温升趋势
温度传感器     ─┘                │
                                 ▼
                    预测散热压力（低 / 中 / 高）
                                 │
                                 ▼
        策略映射 → 每个风扇的安全 RPM 区间 → 已授权用户的 XPC Helper
                                 │
                                 ▼
                    快速升速 · 缓慢降速 · 滞后防抖
```

| 策略 | 适合谁 | 行为 |
| --- | --- | --- |
| **静音平衡** | 更在意风噪 | 明显升温后再积极提高转速。 |
| **舒适优先**（默认） | 日常办公与编译 | 更早介入散热，兼顾机身舒适度与噪声。 |
| **极致降温** | 长时间高负载 | 优先压低温升，允许更高的风扇转速。 |

清凉模式运行时会接管风扇卡片，避免手动调速与算法互相覆盖；关闭模式、手动设置、恢复自动、读取失败、XPC 失败或心跳超时，都会让已接管的风扇回到 macOS 自动控制。Helper 连续约 10 秒收不到心跳也会主动恢复自动散热。

## 权限与安全边界

### 开箱即用的部分

- 进程、CPU、GPU、内存、磁盘、网络与可读取的温度数据：无需额外管理员权限。
- 没有可读取风扇的机型会明确显示不支持，不会伪造控制能力。

### 首次启用风扇控制

1. 将 App 拖入“应用程序”，打开后点击“启用完整功能”。也可先跳过，在风扇页或“设置 → 散热”中启用。
2. 在 macOS 系统窗口输入管理员密码，软件自动安装后台服务并检测连接。密码由 macOS 处理，应用不会保存密码。
3. 配置成功后使用手动调速或清凉模式；以后重新打开 App 或重启 Mac，无需重复授权。

服务版本发生变化时可能需要再次批准更新。取消授权或安装失败后仍可使用监控功能，可点击“启用 / 修复”重试；不应显示为已经启用。无风扇机型不会获得不存在的调速能力，SMC 固件兼容性仍取决于具体硬件和系统版本。

### 服务安装与权限边界

后台服务不再通过 `SMAppService` 注册，也不再检查 Apple 签名或公司 Team ID。首次系统授权允许将固定的风扇服务安装到 root 管理、普通用户不可写的目录：

- `/Library/PrivilegedHelperTools/local.Mac-TaskManager.FanHelper.v2`：服务程序；
- `/Library/LaunchDaemons/local.Mac-TaskManager.FanHelper.v2.plist`：系统后台启动配置；
- `/Library/Application Support/Mac-TaskManager/fan-helper.json`：已授权用户与服务文件校验信息。

授权范围是**当前本机用户的受限风扇控制能力**，包含该用户运行的进程，不以 App 的名称、Bundle ID 或 ad-hoc 签名作为身份凭据。服务通过内核提供的 XPC 用户身份与受保护的授权记录核对，只提供固定的风扇操作，不提供任意命令执行或任意文件写入接口。主应用也校验对端为 root 服务及协议版本。

服务文件及其父目录需要由 root 拥有且不可被组或其他用户写入；符号链接、篡改的安装记录与非有限转速参数会被拒绝。更新失败时尝试恢复旧版文件，服务状态由安装记录、文件校验和实际连接共同判断。旧版服务使用不同的服务名，迁移时会停用已加载的旧服务。

手动调速和清凉模式均遵守硬件报告的 RPM 范围。App 运行时发送心跳，连续约 10 秒失联后服务恢复自动散热；每次接管风扇前写入受保护的恢复记录，服务异常重启后尝试恢复自动散热。正常退出 App 也会请求恢复全部已接管的风扇。

在“设置 → 散热 → 风扇控制服务”可移除服务。移除时会先恢复系统自动散热，再删除已安装的服务和授权记录；需要系统管理员批准。硬件恢复失败时会保留恢复记录，并尝试重新启动服务继续恢复。

## 隐私与运行日志

默认情况下，Mac-TaskManager **不保存历史监控日志**。设置中的“保存监控日志”开关由你决定：

- **关闭（默认）**：不保留历史；导出仅含当下的完整快照。
- **开启**：本地滚动保存最近 **60 分钟** 的系统采样、进程与子进程信息、资源指标、风扇读数和清凉模式决策；存储上限为 **256 MB**。
- **导出**：生成 ZIP 归档，包含 `manifest.json`、当前快照和可用的历史 JSONL 分段；文件只写入你在保存面板选择的位置，不会由该功能上传网络。

这使日志既能用于复现高负载、风扇响应或算法判断，又不会在未经你同意时长期留存。

## 快速开始

### 安装发布版 DMG

1. 下载与 Mac 架构匹配的 `Mac-TaskManager-v<版本号>-arm64.dmg`（Apple 芯片）或 `Mac-TaskManager-v<版本号>-x64.dmg`（Intel），将 **Mac-TaskManager** 拖到“应用程序”。
2. 从“应用程序”启动它；Dock 和状态栏都会保留入口。
3. 直接使用进程与性能页；需要调速和清凉模式时，点击“启用完整功能”完成首次授权。
4. 在“设置”中选择主题、结束任务方式、清凉模式策略，以及是否保存监控日志。

### 从源码构建

**要求**

- macOS 13 或更高版本；
- 完整 Xcode 或可用的 Swift 工具链。

```sh
git clone https://github.com/Flashhhhhhzj/Mac-TaskManager.git
cd Mac-TaskManager

# 编译并生成 Mac-TaskManager.app，仅 ad-hoc 签名，不公证
./build.sh

# 启动已构建应用
open Mac-TaskManager.app
```

运行清凉模式算法与授权边界自检：

```sh
swift run -c release CoolModeAlgorithmChecks
```

## 打包 DMG

版本号统一保存在根目录 `VERSION`。每次发布前用同步脚本更新它；DMG 文件名和 App 内版本会从该文件读取。`APP_BUILD_NUMBER` 用于应用包的 `CFBundleVersion`。

```sh
./scripts/sync-version.sh 1.0.0-beta.4
APP_BUILD_NUMBER="7" ./build.sh dmg
```

默认生成 arm64 和 x64 两个 DMG，也可以只打包指定架构：

```sh
./build.sh dmg arm64
./build.sh dmg x64
```

脚本只生成带版本号和架构后缀的 DMG（例如 `Mac-TaskManager-v1.0.0-beta.4-arm64.dmg`），保留安装窗口布局检查，并重新挂载最终 DMG 校验 Helper 和完整 App。签名身份固定为 `-`（ad-hoc）：不读取钥匙串、不导入证书、不使用公司签名，也不执行公证或票据装订。旧的签名和公证环境变量不再参与构建。

单个可执行文件的链接器签名不能代替完整 App 的资源封装；脚本在资源与 Info.plist 就绪后，先为 Helper、再为整个 App 执行无证书的 [ad-hoc 签名](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc)，并严格校验。它保证包的完整性，不代表 Apple 已认可开发者或通过公证。未公证的下载包可能被 Gatekeeper 阻止，用户需在信任来源的前提下通过[“系统设置 → 隐私与安全性”允许打开](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)。安装与运行流程不要求关闭 SIP 或全局关闭 Gatekeeper。

## GitHub Actions

PR 和 `main` 推送会编译 App 与风扇 Helper，并运行清凉模式算法与授权边界自检。推送与 `VERSION` 完全一致的 `v<版本号>` 标签会构建 arm64、x64 两个包含 ad-hoc App、未公证的 DMG，只发布这两个带版本号的安装包；重跑现有标签时会先替换该 Release 中旧的 Mac-TaskManager DMG。

自动构建不再读取签名证书、证书密码或 Apple 公证 API 的 Actions secrets。

## 架构速览

```text
Mac-TaskManager.app
├── MacTaskManager          SwiftUI / AppKit 主应用
│   ├── SystemMonitor       进程与系统资源采样
│   ├── FanControl          风扇状态、清凉模式与 UI 状态
│   └── MonitoringLog       可选本地历史与 ZIP 导出
├── MacSMC                  AppleSMC 读取、算法、XPC 协议
└── MacFanHelper            经管理员授权安装的特权后台服务
    └── RPM 写入、范围校验、清凉模式心跳失联保护
```

## 设计原则

- **本地优先**：监控、预测和日志都在本机完成。
- **看得懂**：使用熟悉的 Windows 任务管理器信息架构，但数据与行为完全来自 macOS。
- **默认安全**：风扇写入有硬件边界、本机用户授权与服务文件校验、异常自动恢复和明确的系统授权流程。
- **不给假承诺**：没有支持的风扇、温度或权限，就明确告诉你，而不是展示失真的数据。

## 第三方声明

第三方组件与声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

---

<p align="center">
  <strong>少一点“电脑为什么这么烫”的猜测，多一点真正可见、可控的系统状态。</strong>
</p>
