# Livebox

> iOS 应用仓库管理器 / IPA 下载器，配合 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 使用。
> 本项目基于 [Lolendor/LBox](https://github.com/Lolendor/LBox) 修改增强，**MIT 许可**，与 LBox 官方无隶属关系。

<p align="center">
  <img src="./screenshots/livebox_icon.png" width="120" alt="Livebox">
</p>

---

## 这是什么

Livebox 把「找应用 → 下载 IPA → 装进 LiveContainer → 启动」这条链路做成了一个 App：

- 添加 AltStore 格式的源（JSON），像商店一样浏览；
- 后台下载 IPA，自动解压并放进 LiveContainer 的 Applications 目录；
- 已安装的应用可以检查更新、批量更新，并在更新时**保留应用数据**；
- 直接通过 URL 下载 IPA，也可以导入本地文件。

它本身不提供任何应用，只负责管理**你自己添加的源**。

## 在 LBox 基础上做了什么

| 能力 | 说明 |
|---|---|
| GitHub Releases 更新源 | 给已装应用绑定 `owner/repo`，直接按 Releases 判断更新；自动识别（下载记录 → 你添加的源 → GitHub 搜索）只是**候选**，确认一次后永久绑定，也可以手动粘贴链接绑定 |
| 正式版 / 预发行版分线 | GitHub API 的 `prerelease` 字段为准，两条线各自比较版本；预发行更新用橙色标记 |
| 更新不再清数据 | 安装新包的同时把旧的 `LCAppInfo.plist` 合并进新包，首次启动就指向原数据目录（不再需要「跑一次再回 LBox」） |
| 更新保留备份 | 每次更新静默保留上一版，可长按应用回滚；设置里能看到占用并一键清空 |
| IPA 备份 | 下载过的 IPA 自动归档到备份目录，正式版 / 预发行版各留最新一份；备份目录可自定义 |
| 批量更新 | 队列串行执行，自动跳过冲突弹窗，失败自动跳过并继续 |
| 绑定导入导出 | 绑定存在 App 内部，换 Bundle ID 或重装前可以导出 JSON，装好后再导入 |
| 官方源内置 | 首次启动自带 AltStore、SideStore 社区源、LiveContainer、StikDebug 四个官方源，列表在 App 内，不依赖外部服务器 |
| 中英文 + 深色模式 | 默认跟随系统语言与外观，也可以在设置里手动指定 |

## 安装

未签名的 IPA 需要自己签名，需要：

1. Windows / macOS 上的 **Sideloadly**（或 AltStore、SideStore）与 iTunes 驱动；
2. 一个普通 Apple ID（免费账号证书 7 天，需重签）或开发者账号；
3. 目标设备上已安装 **[LiveContainer](https://github.com/LiveContainer/LiveContainer)**。

步骤：

1. 从 [Releases](https://github.com/noneedtobesad7-sketch/Livebox/releases) 下载 `Livebox-1.0-unsigned.ipa`；
2. 用 Sideloadly 签名并安装到设备；
3. 打开 Livebox → 选择 LiveContainer 的存储目录（「On My iPhone」→ LiveContainer），否则无法自动安装和启动；
4. 需要的话在「设置 → 目录」里改下载目录 / IPA 备份目录。

> 首次打开如果文件选择器不可用：打开 LiveContainer → 在 My Apps 里长按 Livebox → Settings → 打开 **Fix File Picker**，再回来选目录。

## 从 LBox 迁移

- **源列表**：旧 LBox 里 `设置 → Export Repos → Copy as JSON`，装好 Livebox 后 `设置 → 导入源（JSON）` 粘贴回去；
- **GitHub 绑定**：旧版 LBox 没有导出功能，需要在 Livebox 里重新确认一轮（Apps 页橙色提示条，或长按应用手动绑定）。以后换版可以直接用「导出绑定 / 导入绑定」。

## 自己编译

没有 Mac 也能编：仓库自带 GitHub Actions 工作流，用 GitHub 免费提供的 macOS 机器编出**未签名 IPA**。

1. Fork 本仓库（或直接用 Actions）；
2. `Actions` → **Unsigned Build (Artifact)** → `Run workflow`；
3. 跑完在 Artifacts 里下载 `LBox-IPA`，解压得到 `LBox.ipa`（文件名沿用工程内部 target 名）。

本地开发需要 macOS + Xcode 26 或更新版本（工程使用 `objectVersion = 77` 与 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`），最低支持 iOS 17.6。

## 已知限制

- **未签名 IPA**：必须自行签名才能安装，免费开发者证书 7 天过期；
- **数据迁移依赖 LiveContainer**：更新保数据是靠在安装时合并 `LCAppInfo.plist` 实现的，LiveContainer 大改存储结构后会失效；
- **GitHub API 限额**：未填 token 时每小时 60 次，建议在设置里填一个 Personal Access Token（只读 public repo 即可）；
- 应用内的搜索匹配只是**候选**，不会自动改成你的更新源；
- 这个 App 不能上架 App Store，只适合自用或小范围分发。

## 许可与致谢

- 本项目基于 [Lolendor/LBox](https://github.com/Lolendor/LBox)，遵循 **MIT License**，原始版权归原作者所有，详见 [LICENSE](./LICENSE)；
- 图标与界面改动为本项目所有；
- 与 LiveContainer、AltStore、SideStore、StikDebug 均无隶属关系，相关名称与商标归各自所有者；
- 本项目**不托管、不分发**任何第三方应用，所有内容来自你自己添加的源。
