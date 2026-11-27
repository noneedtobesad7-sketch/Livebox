# Livebox

简体中文 · [English](README.en.md)

<img src="./screenshots/livebox_icon.png" width="120" alt="Livebox">

**在 LiveContainer 里管理你侧载 App 的下载、更新和备份。**

Livebox 是 [Lolendor/LBox](https://github.com/Lolendor/LBox)（MIT，已停更）的延续分支，专门为「配合 LiveContainer 使用」这一场景重做：商店源、GitHub 源绑定、更新检查、ipa 下载/归档、更新前快照、安装交接，全部围绕 LC 的安装流程设计。

> 本仓库只提供**未签名 IPA**，需要你自己签名安装（Sideloadly / AltStore / SideStore 等）。

---

## 目录

- [为什么需要它](#为什么需要它)
- [功能](#功能)
- [环境要求](#环境要求)
- [安装与首次设置](#安装与首次设置)
- [多任务：安装和更新的前提](#多任务安装和更新的前提)
- [更新一个 App 会发生什么](#更新一个-app-会发生什么)
- [目录结构](#目录结构)
- [截图](#截图)
- [常见问题](#常见问题)
- [版本历史](#版本历史)
- [自行构建](#自行构建)
- [许可与致谢](#许可与致谢)

---

## 为什么需要它

LiveContainer 能让没越狱的设备跑改过签名的 App，但它只管「运行」，不管「去哪找新版、下下来、留一份旧的、装回去」。

Livebox 补的就是这一段：

- 从 AltStore / SideStore / 任意 AltStore 兼容源里搜索、下载 ipa
- 给已装 App 绑定 GitHub Releases 源，自动比对版本、下载新包
- 下载的 ipa 和备份分开放，更新前还能留一份旧版快照用于回滚
- 把安装动作交给 LiveContainer 自己的安装流程（只有经过它打补丁，App 才能在 LC 里启动、且数据不丢）

Livebox 自己是跑在 LiveContainer 里的 guest，所以它的界面、安装交接、数据目录都按这个前提设计。

## 功能

**商店**

- 多源管理：内置默认源，可添加任意 AltStore 兼容源；支持启用/停用、拖动排序
- 搜索、按名称 / 版本 / 更新日期排序
- 同一 App 多来源时可选「分开显示」或按 Bundle ID 合并
- 应用详情页显示描述、版本、更新记录

**已绑定 / 未绑定**

- 「检查来源」扫描可识别的 GitHub 源，生成候选让你确认绑定
- 绑定后自动比对 GitHub Releases 的版本（支持预发行通道）
- 行内按钮四态：**下载 → 安装 → 最新**，下载中显示进度 / 继续
- 未绑定：找到候选显示「绑定」，没有则显示「未知」，点它直接进手动绑定表单
- 批量：**全部下载**（只下缺的）/ **全部更新**（串行，装完一个再发下一个）/ **未发现更新**

**下载与备份**

- 下载目录与备份目录严格分开（`ipa_downloads` / `ipa_backups`）
- 下载记录：最近 3 条常驻可滚动，失败可一键重试，文件被删会标「文件已删除」
- 右上角「导入本地ipa」：同名可「保留两个」或「替换」
- 备份：更新前快照当前版本（可选含数据），长按 App 回滚

**其它**

- 中英双语（跟随系统 / 简体中文 / English），深色模式
- 日志：设置里可开关、查看、导出 `app.log`（含安装、轮询、归档、GitHub 刷新/限流记录）
- 覆盖更新不丢数据：安装始终通过 LiveContainer 的安装流程完成

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | iOS / iPadOS **17.6+**，arm64 |
| LiveContainer | **3.5.0+**（多任务模式是 3.5.0 引入的） |
| LC 安装选项 | 必须 **Keep App Extensions**（保留 `LiveProcess` 扩展），否则多任务不可用 |
| 经典模式 | **不能**开（开了永远不会多任务） |
| 签名 | 自行签名；本仓库产物**未签名** |

## 安装与首次设置

1. 用 Sideloadly / AltStore / SideStore 给 `Livebox-x.y.z-unsigned.ipa` 签名并安装（建议装进 LiveContainer）。
2. 打开 Livebox，首次会提示「先完成初始设置」，点「去设置」。
3. 设置 › 存储与目录：
   - **LiveContainer 目录**：选 LC 的数据目录（Livebox 需要把 ipa 交给它安装）
   - **存储根目录**：选一个你找得到的位置（例如「我的 iPhone」下新建的文件夹）
   - 选好后会自动创建 `<根目录>/ipa_downloads` 和 `<根目录>/ipa_backups`
4. 设置 › 仓库：确认内置源，按需添加或启用。
5. 到「商店」搜索，或去「应用 › 未绑定 › 检查来源」绑定 GitHub 源。

## 多任务：安装和更新的前提

这一条很关键，也是 Livebox 与普通侧载管理器最大的不同。

**单任务**时 LiveContainer 的进程本身变成了 guest（也就是 Livebox），宿主 UI 不在，`livecontainer://install` 会被 LC 的 guest hook 直接拦下——表现就是「点了没反应」或弹「重启后安装」。

**多任务**时 guest 跑在 `LiveProcess` 扩展进程里，宿主仍然活着，安装请求才会被 LC 收到并弹出安装框。

设置一次即可（二选一）：

- 在 LiveContainer 里进 **Livebox 的应用设置** → 多任务 → **是**（只影响 Livebox）
- 或 LC **设置 › Multitask** → 打开 **Auto Launch in Multitask Mode**（全局，所有 App 都多任务）

Livebox 会在安装前自检，若不是多任务会弹出引导（附「复制步骤」），不会白点一次。设置页也能看到当前状态：多任务启动状态 · 已启用 / 未启用。

## 更新一个 App 会发生什么

```
点「下载」            → ipa 落到 ipa_downloads，按钮变「安装」
点「安装」            → 校验 ipa → 归档一份到 ipa_backups
                      → 复制副本到 LC 的交接目录
                      → 打开 livecontainer://install?url=…
LC 弹「覆盖更新 / 安装为新 App」→ 选「覆盖更新」保留数据
LC 打补丁并安装        → 回到 Livebox
回到前台 / 轮询发现版本变化 → 重读已装列表 → 按钮变「最新」
```

要点：

- **原件永远不删**：`ipa_downloads` 里那份一直在；LC 删掉的是交接目录里的副本
- **副本会自动清理**：回前台删一次，启动再清 10 分钟以上的残留
- 「覆盖更新 / 安装为新 App」这个弹窗在 LC 进程里，**必须你点一次**，Livebox 代替不了
- 批量更新是串行的：上一个装完（检测到版本变化）才会发下一个；120 秒没动静会暂停并询问「继续下一个 / 停止」，不硬发（会被 LC 丢弃）

## 目录结构

```
<你选的存储根目录>
├── ipa_downloads/     下载的、导入的 ipa（安装源）
└── ipa_backups/       安装前的归档副本 + 更新前快照
```

- 两个目录都可以长按安装（下载页右上角「导入本地ipa」也把文件放这里）
- 备份快照是 `<uuid>/` 文件夹，不是 ipa；`应用名_版本.ipa` 才是归档副本

## 截图

| 商店 | 应用 |
|---|---|
| ![商店](./screenshots/store.png) | ![应用](./screenshots/apps.png) |

| 下载管理 | 应用详情 |
|---|---|
| ![下载](./screenshots/downloads.png) | ![详情](./screenshots/app_details.png) |

## 常见问题

**点安装没有任何反应？**
没开多任务。按上面「多任务」那一节设置一次，重启 Livebox 后再试。

**装完了版本号没变、按钮还是「安装」？**
现在会每 2 秒轮询已装版本、最长 120 秒；如果 LC 那边你还没点「覆盖更新」，它不会变。点完再等一两秒。

**提示「ipa 里没有 Payload/xxx.app/Info.plist，LiveContainer 装不了」**
这个包结构不符合 LC 的预期（AltStore 能装、LC 装不了），换一个来源或让作者重新打包。

**GitHub 检查更新失败 / 绑定源失败？**
多半是限流：没填 Token 时是 60 次/小时。到 设置 › 更新 把「没有 Token 时不自动检查」打开，或填一个 GitHub Token；也可以把检查频率调成每小时/每 6 小时。

**下载的 ipa 不见了？**
2.0.7 之前有个「下载完成自动解压」的旧逻辑会归档后删源文件，已经移除。现在下载只落盘、不删、不自动装。

**想定位问题？**
设置 › 日志 › 导出日志，把 `app.log` 发出来；里面有安装、轮询、归档、GitHub 刷新的记录（Token 和主目录会自动打码）。

## 版本历史

| 版本 | 重点 |
|---|---|
| 1.0 – 2.0 | 品牌化、双语、深色模式、数据保留升级、GitHub 源绑定 |
| 2.0.1 – 2.0.4 | 安装方式反复调整，2.0.3 有严重问题已废弃 |
| 2.0.5 | 产物统一为 `Livebox.app` / `Livebox.ipa`，商店顶部重叠修复 |
| 2.0.6 – 2.0.8 | 修「下载的 ipa 被删」，安装入口回到 `livecontainer://install` |
| 2.0.9 | 多任务检测 + 闸门、安装轮询、三态批量、日志、新图标 |
| 2.0.10 | 设置「多任务启动状态」、刷新时机、删除标记、导入本地 ipa |
| **2.0.11** | UI 文案与单次切换按钮、检查频率、预发行归档分通道、包内名字归档、错误日志 |

完整发行说明见 [Releases](https://github.com/noneedtobesad7-sketch/Livebox/releases)。

## 自行构建

无需 Mac，用 GitHub Actions 出未签名包：

```
改代码 → push → Actions「Unsigned Build (Artifact)」→ 下载 Livebox-IPA.zip → 解压得 Livebox.ipa
```

- 工程 `objectVersion = 77`，需要 **Xcode 26+**（CI 若不是，把 workflow 的 `runs-on` 改成 `macos-26`）
- 依赖仅 SPM：ZIPFoundation 0.9.20
- Bundle ID：`NNSAD.Livebox`

## 许可与致谢

- 基于 [Lolendor/LBox](https://github.com/Lolendor/LBox)，MIT License
- 运行宿主：[LiveContainer](https://github.com/LiveContainer/LiveContainer)
- 解压：[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)
- 图标：作者自绘
