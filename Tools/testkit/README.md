# Luma TestKit · 测试集 / 产品截图 / 性能基线

一套可复现的本地测试资产，覆盖 **图片、视频、图库、网盘、影院、网络资源、在线影院、电视直播** 八个方向：

- **统一故事线**：一个中国家庭（爸爸、妈妈、姐姐、弟弟）2010–2026 年的生活记录——环球旅行、国内景点、上学上班、补课、婚礼、长隆、水世界、迪士尼、九寨沟、西藏……照片带真实 EXIF / GPS，视频画面取自这些照片并叠加拍摄地点角标。
- **回归测试集**：固定样片 + 固定 mock 源，任何一次改动都能对着同一套数据复测。
- **真实产品截图**：应用内 `TestKitHarness` 打开真实界面逐页截图，供官网 / 手册 / AI 文档直接引用。
- **性能基线**：转封装、重编码、拖动、AVPlayer 可播性的量化报告。
- **可进入的入口**：本文、`screens/screens.json`、`Sources/Luma/Services/App/TestKitHarness.swift` 三处互相指向。

所有产物默认写到 `~/Movies/LumaTestKit`，**不写进仓库**。只有脚本与截图清单入库。

---

## 1. 快速开始

```sh
# 1) 生成测试集（约 1–3 分钟，首次会编译图片生成器）
python3 Tools/testkit/testkit.py dataset

# 1.1) 规模模式：生成 5000 张照片（按 2010–2026 分年相簿，用于图库压力 / 性能测试）
python3 Tools/testkit/testkit.py dataset --photos 5000

# 1.2) 真人素材：仓库已内置一套（四张透明背景 PNG）
# 位置 Tools/testkit/fixtures/faces/{father,mother,elder,younger}.png，四张齐全才生效；
# 生成时人物直接贴真人照片（脚底对齐、按身高等比缩放）。删掉这四张就退回插画人物。
# 来源（Pexels License，可免费商用）：#31956963 父母、#24380278 姐姐、#5560037 弟弟；
# 换人时用 split_family / cutout_faces 从一张全家福或单人照重新抠图。

# 2) 校验测试集与 mock 源
python3 Tools/testkit/testkit.py validate

# 3) 启动 mock 源（WebDAV / 苹果CMS / HLS / EPG）
python3 Tools/testkit/testkit.py serve

# 4) 截图（需要先 ./build.sh debug；应用不能已经在运行）
python3 Tools/testkit/testkit.py screens --build

# 5) 视频性能基线
python3 Tools/testkit/testkit.py perf

# 6) 一条龙：数据集 + 校验 + 全部截图
python3 Tools/testkit/testkit.py all
```

产物位置：

```
~/Movies/LumaTestKit/
├── dataset/                 测试集
│   ├── photos/              带 EXIF / GPS 的照片（按相簿分目录）
│   ├── screenshots/         截屏素材（PNG）
│   ├── live/                实况照片 + HLS + 台标 + 运行时 M3U
│   ├── videos/              视频矩阵
│   ├── variants/            重复 / 近似重复 / 模糊 / 全景 / 竖幅 / 损坏
│   ├── cloud/               WebDAV / NAS 的目录树
│   ├── cinema/              本地影院目录 + NFO + 海报
│   ├── catalog/             网络影院海报 / 背景图
│   └── manifest.json        总清单
├── screenshots/             产品截图 + index.json + captures.md
├── perf/                    HLS / 重编码输出
└── reports/                 validation / video-perf / screens-summary / regression
```

---

## 2. 测试集覆盖

| 方向 | 素材 | 能测什么 |
| --- | --- | --- |
| 图片 | 65 张带 EXIF / GPS 的家庭照片：10 个主题相簿（2010–2026 的旅行 / 日常 / 自拍 / 全景 / RAW / 动图）+ 6 张截屏 + 2 组实况照片；爸爸（深蓝衬衫）、妈妈（珊瑚色）、姐姐（姜黄）、弟弟（青绿）都有面孔、发型与固定配色；`--photos N` 可扩到 5000+ 张，按年份分相簿 | 导入、时间轴、地点、截屏识别、查重、体检、OCR / 场景标签；2010–2016 的老照片带数码相机日期水印 |
| 视频 | 17 个编码矩阵样片，画面统一取自旅行 / 日常照片并叠加「年月 + 地点」角标：H.264 / HEVC / HDR10 / 4K / 竖屏 / 隔行 TS / MKV / AVI / AC-3 / DTS / 双音轨 / 内嵌字幕 / 外挂 SRT+ASS / 章节 / 实况照片 / 损坏文件 | 原生直读、转封装、重编码、HDR 映射、音轨切换、字幕、拖动、错误恢复 |
| 图库 | 65 张照片 + 17 个视频；导入后默认建好 4 个文件夹（旅行 / 家里与成长 / 国内山河 / 精选）与 14 个相簿，并给「个人收藏」写入跨年份的样本 | 时间轴（2010–2026 共 17 个年份）、文件夹层级、相簿、收藏、视频页、体检、值得重看、回收站 |
| 媒体类型 | 自拍、实况照片、全景照片、截屏、动图（GIF）、RAW（.dng）、视频；收藏与星级同时有分布 | 侧边栏每个媒体类型入口都有内容，可测筛选、查看器与编辑 |
| 来源导入 | `StreamSource/` 导出的网络资源 / 网络影院 / 网络电视 JSON，启动时直接导入 | 「创建 → 导入」链路、源排序、跨源搜索、聚合首页 |
| 网盘 | `cloud/` 目录树 + WebDAV mock（PROPFIND / Range） | 接入、浏览、缩略图、视频拖动、网盘影院 |
| 影院 | `cinema/Movies` 与 `cinema/TV` + NFO + poster/fanart | 本地扫描、NFO 读取、海报墙、剧集 / 季 |
| 网络资源 | 图集站 HTML mock（首页 / 频道 / 图集详情 / 标签墙）+ `catalog/` 海报 | 源接入、源总览、频道海报墙、标签墙（其它网页源适配器仍需真实站点，见 §7） |
| 在线影院 | 苹果CMS JSON（`ac=list` / `ac=detail`）+ 本地 HLS 播放地址 | 列表、分类、搜索、详情、分集、选源播放 |
| 电视直播 | 4 路本地 HLS、多线路 M3U、XMLTV 节目单、台标 | 频道墙、分组、EPG、切台、选线、回看模板 |

`dataset/manifest.json` 会记录本次实际生成的媒体数量与入口命令。

---

## 3. Mock 源服务

`mock_sources.py` 一个进程提供五类源，全部只读本地测试集：

| 端点 | 用途 |
| --- | --- |
| `GET /health` | 健康检查 |
| `PROPFIND /webdav/` | WebDAV 目录（Depth 0/1），映射 `dataset/cloud` |
| `GET/HEAD /webdav/...` | 文件下载，支持 `Range`（206） |
| `GET /cms/api.php/provide/vod/` | 苹果CMS：`ac=list` / `ac=detail&t=` / `&wd=` / `&ids=` |
| `GET /`、`/file/<slug>/`、`/tags/...`、`/all-tags` | 图集站 HTML（Tuzac 页面结构），对应「网络资源」的源导入、频道列表与图集详情 |
| `GET /hls/<channel>/index.m3u8` | 4 路本地 HLS |
| `GET /epg.xml` | 动态 XMLTV，前后各 3 天 |
| `GET /playlist.m3u` | 多线路 M3U（`tvg-id` / 分组 / catchup 模板） |

启动时会打印 `LUMA_TESTKIT_SERVER=http://127.0.0.1:<port>`，并写入：

```
dataset/live/playlist.runtime.m3u
dataset/live/epg.runtime.xml
```

接入方式：

- 网络存储：地址填 `http://127.0.0.1:<port>/webdav`，账号任意。
- 网络影院：地址填 `http://127.0.0.1:<port>/cms/api.php/provide/vod/`。
- 网络资源：地址填 `http://127.0.0.1:<port>`（根地址即图集站首页）。
- 网络电视：导入 `playlist.runtime.m3u`。

---

## 4. 产品截图

### 4.1 直接采集

```sh
./build.sh debug
python3 Tools/testkit/testkit.py screens --screens all --size 1440x900
```

输出：

```
~/Movies/LumaTestKit/screenshots/
├── gallery.timeline.png
├── gallery.all.png
├── viewer.video.png
├── networkCinema.png
├── television.png
├── ...
├── index.json       机器可读：id / 标题 / 图注 / 文件名
└── captures.md      图注清单，可粘贴进 Markdown
```

只想截某几页：

```sh
python3 Tools/testkit/testkit.py screens --screens gallery.timeline,networkCinema,television
```

每次运行默认**重建演示库**：上一次的 mock 端口、源与探活结果不会带进来。想复用上次导入结果时加 `--keep-library`。

应用不能用已打开的 Luma 实例：应用是单实例，截图前先退出。若要用独立副本验证，可加 `--app <另一个 Luma 可执行文件> --force`。

### 4.2 应用内入口（给 AI 编程工具）

入口代码是 [TestKitHarness.swift](../../Sources/Luma/Services/App/TestKitHarness.swift)，由环境变量驱动，正常启动完全不参与：

| 环境变量 | 含义 |
| --- | --- |
| `LUMA_TESTKIT_DATASET` | 测试集根目录（必填） |
| `LUMA_TESTKIT_SEED=1` | 把测试集导入演示图库（默认 `~/Movies/LumaTestKit/Demo.photoslibrary`） |
| `LUMA_TESTKIT_LIBRARY` | 演示图库路径 |
| `LUMA_TESTKIT_MODULES=1` | 接入 mock 网盘 / 网络影院 / 电视源 |
| `LUMA_TESTKIT_SERVER` | mock 源地址，如 `http://127.0.0.1:9410` |
| `LUMA_TESTKIT_TV_PLAYLIST` | 运行时 M3U 路径 |
| `LUMA_TESTKIT_SOURCE_BUNDLE` | `StreamSource/` 目录：网络资源 / 网络影院 / 网络电视的导出 JSON，启动时直接导入 |
| `LUMA_TESTKIT_SIDEBAR_EXPAND=1` | 截图前把侧边栏各层级展开（由 `screens.json` 的分区自动选择聚焦位置） |
| `LUMA_TESTKIT_SCREEN` | 页面 id，逗号分隔或 `all` |
| `LUMA_TESTKIT_SCREENS` | 页面清单 JSON（`screens/screens.json`），由 `testkit.py` 自动传入 |
| `LUMA_TESTKIT_SHOTS` | PNG 输出目录 |
| `LUMA_TESTKIT_SETTLE` | 每次切换页面后的等待秒数，默认 `2.5` |
| `LUMA_TESTKIT_SIZE` | 窗口内容尺寸，默认 `1440x900` |
| `LUMA_TESTKIT_QUIT=1` | 截完退出 |

页面 id、标题、建议图注与**进入方式**都在 [screens/screens.json](screens/screens.json) 里，应用内不再维护第二份页面清单。

新增一个页面 = 在这份 JSON 里加一条 `action`，不需要改 Swift：

| `action.kind` | 用途 | 主要字段 |
| --- | --- | --- |
| `gallery` | 图库视图 / 分组 / 排序 | `grouping` `aspect` `sortKey` `sortAscending` |
| `navigate` | 侧边栏目标 | `to`（如 `allAlbums`、`people`、`firstCloudMount`） |
| `viewer` | 照片 / 视频查看器 | `target`（`photo` / `video`）、`info` |
| `search` | 统一搜索 | `scope` `text` |
| `select` | 多选 N 张 | `count` |
| `sheet` | 新建相簿 / 命名 / 批量修改 / 导出 / 压缩 / 关键词 / 快捷键 | `target` |
| `overlay` | 删除确认 / 幻灯片 | `target` `count` |
| `editor` | 照片编辑器 | — |
| `wizard` | 接入资源 / 网盘 / 电视 | `target` |
| `menu` | 右键菜单（按窗口比例定位，后台截屏后自动 Esc 关闭） | `target` `x` `y` |
| `window` | 独立窗口（导入面板） | `target` |
| `sidebar` | 侧边栏逐项点击，一条 JSON 产出多张 `<id>.<suffix>.png` | `target`：`basics` / `albums` / `folders` / `cloud` / `catalog` / `tv` / `scenes` |
| `ai` | AI 智能助手整页 | `target`：`welcome` / `chat` / `approval` |

只有出现一种全新的交互方式时，才需要在 `TestKitHarness.run(_:…)` 里加一个 `kind`；侧边栏与 AI 助手的「逐项点击 / 会话状态」由 `sidebar`、`ai` 两种 kind 统一承接。

### 4.3 给官网 / 手册 / AI 文档使用

- 每张图都是真实应用界面，**不要用设计稿或重新绘制的示意图替代**。
- 图注直接用 `captures.md` 或 `screens.json` 的 `suggestedCaption`。
- 需要把截图放进仓库时，显式指定输出目录，例如：

```sh
python3 Tools/testkit/testkit.py screens --out docs/screenshots
```

- AI 写页面时的最小上下文：

```text
1. 读 Tools/testkit/screens/screens.json，选择与章节对应的 screen id。
2. 如果截图不存在，运行 python3 Tools/testkit/testkit.py screens --screens <id>。
3. 引用 ~/Movies/LumaTestKit/screenshots/<id>.png，图注用 suggestedCaption。
4. 不要编造界面元素；截图里没有的功能不要写进文案。
```

---

## 5. 视频性能

```sh
python3 Tools/testkit/testkit.py perf
# 跳过 30MB 以上样片
python3 Tools/testkit/testkit.py perf --quick
```

输出：

- `reports/video-perf.json`：逐文件的事实数据。
- `reports/video-perf.md`：可直接贴进文档的表格。

指标：

| 指标 | 口径 |
| --- | --- |
| 转封装实时倍率 | `6s / ffmpeg -c copy 到 HLS 的实际耗时`，> 1.0 表示快于实时 |
| 重编码实时倍率 | `4s / libx264 ultrafast 实际耗时` |
| 拖动耗时 | 从 25% / 50% / 75% 位置解码一帧的耗时中位数 |
| AVPlayer | 复用 `Tools/dev/avplayer_probe.swift` 的公开 API 事实：可播、轨道、实际播放秒数 |

阈值建议：1080p 转封装 ≥ 2.0、重编码 ≥ 1.0；4K 重编码允许 < 1.0，但需记录。性能回归应比较同一台机器上的趋势，不做跨机型绝对值比较。

---

## 6. 回归

```sh
python3 Tools/testkit/testkit.py regression
python3 Tools/testkit/testkit.py regression --with-ui
```

依次执行：

1. `validate`：媒体可解析、EXIF / GPS、损坏样本按预期失败、HLS、NFO、海报、WebDAV / 苹果CMS / EPG 自检。
2. `swift run LumaCoreChecks` / `LumaContentChecks` / `LumaDataChecks`。
3. 可选 `screens --screens all` 做界面冒烟。
4. 汇总到 `reports/regression.json`，失败以非零码退出。

---

## 7. 已知边界

- **网络资源（网页源）**：mock 只实现 Tuzac 一套图集站模板，用于验证导入、频道列表、标签墙与详情；其它网页源适配器仍依赖真实站点 HTML。
- **素材风格**：人物默认使用 `fixtures/faces/` 里的四张真实人像（Pexels License），按身高贴进 CoreGraphics 绘制的场景；删除素材后退回插画人物。场景本身仍是程序化绘制，不是照片级风景；也可以直接替换 `dataset/photos/<相簿>/*.jpg` 并保留文件名 / EXIF。视频画面来自这些照片，替换照片后重跑 `dataset` 会按新照片重建视频。
- **视频时间线**：ffmpeg 生成的视频把拍摄时间写进 `creation_time`，MKV / TS / AVI 读不到时由 `dataset/.meta/video_dates.json` 兜底（应用内 `TestKitHarness` 会自动应用）。
- **影院刮削**：本地 NFO 已就绪，但 TMDB / 豆瓣刮削需要用户自备网络与凭据；`screens` 默认只保证海报墙页面可截，不保证条目已刮削。
- **录制 / 时移**：电视的 30 秒录制与缓冲时移依赖真实播放会话，本工具只提供 HLS 与 EPG 输入。
- **截图范围**：`TestKitHarness` 用 `CGWindowListCreateImage` 截取窗口（含工具栏与侧边栏，不含系统菜单栏与窗口阴影），足以用于官网与手册；需要窗口装饰时用系统 `screencapture` 另行补拍。
- **右键菜单截图**：由应用内自注入右键事件触发，再由后台线程截取「窗口 + 菜单」区域；这一步依赖系统的「屏幕录制」权限，没有权限时菜单不会出现在图里。
- **AI 助手 / 设置截图**：AI 助手是模态 sheet，设置是 SwiftUI `Settings` scene，两者在当前自动化窗口下都会触发布局循环，暂不纳入批量截图；需要这两类图时手动打开后截图。其余页面（查看器、网络影院、电视、网盘等）都可自动采集。
- **本地影院截图**：本地影院的条目名来自导入后的文件名；没有 TMDB 凭据时卡片会显示「未识别」。批量截图不包含本地影院，产品图使用「网络影院」；需要本地影院海报墙时先配置刮削源并完成一次刮削。
- **单实例**：应用是单实例，截图前必须先退出已打开的 Luma。

---

## 8. 目录

```
Tools/testkit/
├── testkit.py              主入口：dataset / serve / screens / perf / validate / regression / all
├── mock_sources.py         WebDAV + 苹果CMS + HLS + EPG mock
├── fixtures/
│   └── generate_images.swift   带 EXIF 的图片 / 截屏 / 海报生成器
├── screens/
│   └── screens.json        页面 id / 标题 / 建议图注（AI 文档入口）
└── README.md               本文件
```

相关文档：

- 开发规范：[AGENTS.md](../../AGENTS.md)
- 代码地图：[docs/development.md](../../docs/development.md)
- 视频播放能力：[docs/playback/video-playback-capability-design-2026-11.md](../../docs/playback/video-playback-capability-design-2026-11.md)
