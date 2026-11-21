# 片间拾影

片间拾影是一款为 HarmonyOS 手机开发的原生视频播放器，也是「栈里拾光」和「曲间拾声」的姊妹应用。可以在手机上管理影视源、搜索影片、选择线路和分集，也可以把想看的影片收藏起来，下次从「片单」继续观看。

应用使用 ArkTS 和 ArkUI 开发。搜索、影片详情和播放请求由手机直接发出，日常使用无需部署服务。

## 功能

| 功能 | 使用方式 |
| --- | --- |
| 多源搜索 | 在「搜索」输入片名或剧名。应用会并行查询已添加的影视源，结果会标明来源。 |
| 影片推荐 | 「搜索」页提供最近更新、热门、高分和最新上映。排名使用片源提供的更新时间、热度、评分和上映日期。 |
| 线路和选集 | 打开影片后选择线路和分集。播放页可手动切上一集、下一集，也可在设置里关闭默认开启的自动连播。 |
| 自动换源 | 播放报错时，优先重试当前来源的备用线路，再尝试搜索结果中片名、年份和集名匹配的其他来源。可在设置中关闭。 |
| 横屏和防误触 | 通过播放器的全屏按钮进入横屏。播放页可锁定控件，锁定全屏后用系统返回手势退出。 |
| 收藏 | 在影片详情点「收藏」，之后可从「片单 → 收藏」重新打开影片或取消收藏。 |
| 播放记录 | 在「片单 → 播放记录」续播、移除单条记录或清空历史。最近 100 条记录保存在本机。 |
| 链接播放 | 在「设置」粘贴 HTTP 或 HTTPS 的 HLS、MP4 直链。 |
| GitHub 寻源 | 在「设置」打开寻源弹窗，查看候选地址并逐条添加。 |

「最新上映」展示片源返回的近 90 天内的上映条目。片源缺少上映日期、热度或评分时，对应分类可能没有内容。

底部导航分为「搜索」「片单」「设置」。「片单」集中管理收藏和播放记录，播放偏好与影视源管理在「设置」中。

## 快速上手

1. 打开「搜索」，输入片名，或从推荐中挑一部影片。
2. 点开结果，选择线路和分集。播放时可切换横屏，或开启防误触。
3. 想留着以后看，可以在详情页收藏。看过的内容可以在「片单 → 播放记录」继续播放。
4. 想添加更多来源，在「设置」手动填写 API 地址，或使用「GitHub 寻源」。

## 配置影视源

应用内置光速资源、360 资源、极速资源、U酷资源、无尽资源和豪华资源作为初始选项。可以在「设置」移除或添加来源。来源和播放地址可能随服务端状态、片源地区限制及手机网络而变化。

### 手动添加

在「设置 → 影视源」填写名称和 MacCMS JSON 采集 API 地址，例如 `https://你的域名/api.php/provide/vod/`。应用使用 `ac=videolist&wd=关键词` 搜索，详情通过 `ac=videolist&ids=影片ID` 或 `ac=detail&ids=影片ID` 获取分集。

### GitHub 寻源

打开「设置 → GitHub 寻源」，应用会读取公开的 LibreTV 源清单，筛出符合格式要求的 HTTPS 点播候选，并略过已经添加的地址。点击候选旁的「添加」会保存该源，弹窗可以继续浏览，也能手动刷新。搜索和播放的可用性取决于片源与网络。[LibreTV 社区源清单](https://gist.github.com/xuyishan8058/fcd88d1a9e84c024cd5bc91531803ed3)

## 构建与真机安装

1. 用 DevEco Studio 打开本目录。工程兼容 SDK 为 HarmonyOS 6.0.0（API 20），目标 SDK 为 26.0.0。
2. 如果还没有 `build-profile.json5`，可从 `build-profile.example.json5` 复制一份。连接开启调试的 HarmonyOS 手机，在 DevEco Studio 配置本应用的调试签名。
3. 确认 `build-profile.json5` 中 `app.products` 下名为 `default` 的产品包含 `"signingConfig": "default"`，并且 `app.signingConfigs` 中存在对应的签名配置。
4. 在 DevEco Studio 选择已连接的设备并运行，或在 Windows PowerShell 中进入本目录构建。

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build.ps1
```

构建产物位于 `entry/build/default/outputs/default/`。配置签名后可使用 `entry-default-signed.hap` 安装到调试设备。未签名构建生成 `entry-default-unsigned.hap`。本地签名配置和证书材料应保存在本机。

## 代码结构

| 文件 | 职责 |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | 搜索、推荐、播放、片单与设置页面，以及本地状态管理 |
| `entry/src/main/ets/video/Catalog.ets` | MacCMS 请求、分集解析、内置影视源与 `Catalog` 接口 |
| `entry/src/main/ets/video/GitHubSources.ets` | 读取和筛选 GitHub 公开源清单 |
| `scripts/build.ps1` | 使用本机 DevEco Studio 工具链构建 HAP |

当前使用手机直连的 MacCMS 适配器。后续接入自建 LibreTV 或 LunaTV 服务时，可以通过 `Catalog` 接口添加对应适配器。

## 数据和来源

收藏、播放进度、影视源和播放偏好保存在本机。搜索时会向已添加的影视源发送关键词，点「GitHub 寻源」时会向 GitHub 请求公开清单。请使用自己有权访问的内容和来源。

## 致谢

影视源管理与播放流程参考了 LibreTV 和 LunaTV，界面风格延续了「曲间拾声」。[LibreTV](https://github.com/LibreSpark/LibreTV) · [LunaTV](https://github.com/MoonTechLab/LunaTV)
