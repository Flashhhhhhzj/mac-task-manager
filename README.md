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

> 当前构建只编译和打包，不使用开发者证书签名，也不提交 Apple 公证。进程、性能与可读取的风扇和温度数据仍可使用；现有特权 Helper 依赖同团队签名验证，因此当前包暂不能使用手动调速和清凉模式。

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
        策略映射 → 每个风扇的安全 RPM 区间 → 签名验证的 XPC Helper
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

### 风扇调速的当前限制

写入风扇转速通过 root 后台服务 `MacFanHelper` 执行。现有实现使用 `SMAppService` 注册服务，并在 XPC 连接时检查主应用与 Helper 的 Apple 签名和 Team ID。当前未使用开发者签名的构建不满足这条授权链路，点击“授权并启用”也不能使调速生效。

风扇页仍会直接读取 AppleSMC 提供的温度与转速。要恢复手动调速和清凉模式，需要另行实现经过管理员授权、具有客户端身份校验的特权服务安装与通信方案。

> 手动设置和清凉模式都不会突破硬件报告的 RPM 边界。应用退出、清凉模式异常或后台心跳中断时，风扇会恢复为 macOS 自动策略。

### 不使用开发者签名的调速方案（待实现）

推荐改用管理员明确授权安装的独立 LaunchDaemon：安装程序将 Helper 与 plist 放入 root 管理、普通用户不可写的系统目录，由 `launchd` 启动。主应用继续以普通用户运行，通过现有 XPC 协议请求调速。Apple 的 [LaunchDaemon 文档](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)描述了这种部署方式。

这条路线需要替换两处现有实现：

- **注册与状态检测**：改为管理员授权的安装、升级、卸载，以及独立服务的版本与连接检测，不再依赖 `SMAppService.status`。
- **请求授权**：移除对 Apple 签名及 Team ID 的依赖，改用本应用专用的 Authorization Services 权限。客户端通过系统授权对话框获取授权凭据，Helper 校验凭据与对应权限后才允许调速，并检查连接身份；不能直接删除签名检查后接受所有连接。Apple 的[权限提升说明](https://developer.apple.com/forums/thread/708765)和[授权凭据跨进程传递接口](https://developer.apple.com/documentation/security/authorizationmakeexternalform(_:_:))给出了这些机制。

现有 RPM 范围校验、清凉模式心跳超时恢复和异常回退都应保留。该设计不需要开发者证书或公证，但仍需要管理员授权，并需在目标 macOS 与硬件上验证。单靠提高进程权限不能保证固件接受风扇写入。

临时手动测试也可以扩展 Helper 的 CLI，增加固定的调速、恢复自动命令，再由用户在终端通过 `sudo` 执行；当前 CLI 只有只读命令，尚不具备这个功能。这种一次一条命令的方式不适合清凉模式持续调速。整个图形应用以 root 身份运行则不在推荐方案内，Apple 的权限提升说明也明确反对这种做法。

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
3. 直接使用进程与性能页；风扇页可查看可读取的转速和温度，当前调速限制见上文。
4. 在“设置”中选择主题、结束任务方式、清凉模式策略，以及是否保存监控日志。

### 从源码构建

**要求**

- macOS 13 或更高版本；
- 完整 Xcode 或可用的 Swift 工具链。

```sh
git clone https://github.com/Flashhhhhhzj/Mac-TaskManager.git
cd Mac-TaskManager

# 编译并生成 Mac-TaskManager.app，不签名、不公证
./build.sh

# 启动已构建应用
open Mac-TaskManager.app
```

运行清凉模式算法自检：

```sh
swift run -c release CoolModeAlgorithmChecks
```

## 打包 DMG

版本号统一保存在根目录 `VERSION`。每次发布前用同步脚本更新它；DMG 文件名和 App 内版本会从该文件读取。`APP_BUILD_NUMBER` 用于应用包的 `CFBundleVersion`。

```sh
./scripts/sync-version.sh 1.0.0-beta.3
APP_BUILD_NUMBER="5" ./build.sh dmg
```

默认生成 arm64 和 x64 两个 DMG，也可以只打包指定架构：

```sh
./build.sh dmg arm64
./build.sh dmg x64
```

脚本只生成带版本号和架构后缀的 DMG（例如 `Mac-TaskManager-v1.0.0-beta.3-arm64.dmg`），保留安装窗口布局检查；不读取钥匙串、不导入证书、不执行签名、公证或票据装订。旧的签名和公证环境变量不再参与构建。

Apple 芯片上的可执行文件可能由链接器自动生成 ad-hoc 签名，这是[平台的运行要求](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)，不包含开发者证书或公司身份；构建脚本不会额外执行签名。未公证的下载包可能被 Gatekeeper 阻止，用户需在信任来源的前提下通过[“系统设置 → 隐私与安全性”允许打开](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)。

## GitHub Actions

PR 和 `main` 推送会编译 App 与风扇 Helper，并运行清凉模式算法自检。推送与 `VERSION` 完全一致的 `v<版本号>` 标签会构建 arm64、x64 两个未签名、未公证的 DMG，只发布这两个带版本号的安装包；重跑现有标签时会先替换该 Release 中旧的 Mac-TaskManager DMG。

自动构建不再读取签名证书、证书密码或 Apple 公证 API 的 Actions secrets。

## 架构速览

```text
Mac-TaskManager.app
├── MacTaskManager          SwiftUI / AppKit 主应用
│   ├── SystemMonitor       进程与系统资源采样
│   ├── FanControl          风扇状态、清凉模式与 UI 状态
│   └── MonitoringLog       可选本地历史与 ZIP 导出
├── MacSMC                  AppleSMC 读取、算法、XPC 协议
└── MacFanHelper            经 macOS 批准的特权后台服务
    └── RPM 写入、范围校验、清凉模式心跳失联保护
```

## 设计原则

- **本地优先**：监控、预测和日志都在本机完成。
- **看得懂**：使用熟悉的 Windows 任务管理器信息架构，但数据与行为完全来自 macOS。
- **默认安全**：风扇写入有硬件边界、Helper 签名校验、异常自动恢复和明确的系统授权流程。
- **不给假承诺**：没有支持的风扇、温度或权限，就明确告诉你，而不是展示失真的数据。

## 第三方声明

第三方组件与声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

---

<p align="center">
  <strong>少一点“电脑为什么这么烫”的猜测，多一点真正可见、可控的系统状态。</strong>
</p>
