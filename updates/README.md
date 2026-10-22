# 更新发布维护

## 用户流程

- 设置底部提供自动检查开关、手动检查、下载进度和取消操作。
- 默认每天自动检查正式版；发现更新后下载，完成后询问是否更新并重启。
- 暂不更新会取消准备好的安装，不会在普通退出时偷偷安装；稍后可重新下载。
- 保持 ad-hoc App 签名，不使用 Apple 开发者证书，不公证。不保证免除首次启动的 Gatekeeper 提示。
- 1.0.0 需要手动升级一次，之后才具备应用内更新能力。

## 独立更新密钥

公开部分为本目录的 `public-key.txt`，构建时写入 `SUPublicEDKey`。私钥不进入仓库、App 或日志。

当前维护机使用 Sparkle 钥匙串账号 `local.Mac-TaskManager.updates`；另有权限为 0600 的备份文件 `~/.config/mac-task-manager-signing/ed25519-private-key`。请将备份安全保存到独立位置。GitHub Actions 使用仓库 secret `SPARKLE_PRIVATE_KEY`。不要将私钥粘贴到 issue、代码或 Release 说明中。

这是更新真实性校验用的 Ed25519 密钥，与 Apple 的 ad-hoc / Developer ID 代码签名独立。丢失私钥且没有可用备份时，现有用户无法信任新密钥，必须人工安装新版；不要随意重新生成或只替换公钥。

## 发布

1. `scripts/sync-version.sh <新版本>` 同步 `VERSION` 并递增 `BUILD_NUMBER`，提交两者。同版本重做包也必须递增构建号。
2. 推送与 `VERSION` 一致的 `v<新版本>` 标签。
3. Release workflow 构建并校验两个架构的 DMG，使用仓库更新私钥生成、签名和复查更新信息，再发布 DMG 与 `appcast-arm64.xml`、`appcast-x64.xml`。
4. 正式版必须为 GitHub 最新的非预发布 Release，应用从 `/releases/latest/download/appcast-<arch>.xml` 检查更新。预发布不会提供给默认用户。

本地签名命令：`scripts/create-update-feed.sh arm64 <版本> dist/Mac-TaskManager-v<版本>-arm64.dmg`，Intel 使用 `x64`。脚本从归档读取 App 版本、构建号和最低系统要求，不手填资源数值。工具固定为 Sparkle 2.10.0，并校验下载 SHA-256；公开的更新信息和 DMG 均通过 Ed25519 校验。

首次启用更新源时，可以为现有 1.0.0 归档添加签名更新信息；不会替换原来的 App。新版使用更高构建号，不会被降级。新的发布流程随此源码合入主分支后生效。

## 权限边界

Sparkle 负责验证、解包、替换和重启，风扇和系统管理助手不执行更新命令。应用位置不可写时可能需要系统管理员批准；后台助手有变更时仍可能需要原有的升级授权。GitHub 或网络不可达、签名不符、归档损坏、系统或硬件不兼容时保留当前 App，界面显示失败原因。

依赖与发布文档：https://sparkle-project.org/documentation/
