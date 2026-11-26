# 重构收尾状态（2026-11-26）

本文是 `docs/architecture/` 下三份大规划之后的「收尾清单」，只记录**可验收的工程项**，
不重复规划正文。判定标准写在每项下面，完成一项就勾掉一项并在「证据」里留文件位置。

## 背景与验收口径

上一轮已经落地：8 个库 target、`package` 可见性、照片网格整栈迁入 `LumaUI`、
相册滚动卡顿修复、批量取照片索引、网格宿主广播去抖、堆叠角标缓存、
时长格式化收敛、`Components.swift` 拆分。本文记录本轮收尾的 9 项（A–D）与
大图库时间轴的 UX 修复（E），**全部已完成**。

- 验收口径：代码改动 + `swift build` + `LumaCoreChecks` / `LumaContentChecks` / `LumaDataChecks` 通过。
- 性能项的验收口径：`python3 Tools/dev/ui_perf.py` 记录基线，改动前后不回归（见文末「性能基线」）。

## 三份大规划的权威性

三份文档主题有重叠，按下面的分工阅读，避免当成三份并行方案：

| 文档 | 定位 | 状态 |
| --- | --- | --- |
| `modularization-abstraction-2026-11.md` | **模块化 / 契约层**的现状与结论（分层、`package`、`LumaContentCore`） | 结论 1–5 已落地或已过期，以文首「当前落地情况」为准 |
| `multi-mode-architecture-2026-11.md` | **多模式（图库 / 云盘 / 影院 / 资源站 / 电视）** 的目标架构 | §4 统一导航描述符、跨源搜索未落地 |
| `shiguang-house-2026-11.md` | **拾光之家**（设备 / 消息 / 网页归档作为新来源） | 尚未开始，`asset_sources` 表不存在 |

结论：三份**不合并**——它们是不同主题（模块化 / 多模式 / 新来源），重叠部分只在
`LumaContentCore` 契约层，已在这一层各写清楚；本文只保证每份文首都标注了落地状态。

## 清单

### A. 性能

- [x] **A1 `photo(id:)` / `anyPhoto(id:)` 加 ID 索引**
  - 原本：单张查询走 `photos.first(where:)`，10 万张库下每次 O(n)，`anyPhoto(id:)` 有 66 处调用。
  - 现在：`[UUID: PhotoItem]` 懒建索引，`photos` 的 `didSet` 清空；本地库累计 8 次查询后建索引，
    网盘按 `cloudModel.revision` 缓存，批量 `photos(forIDs:)` 直接复用。
  - 证据：`Store/Library/LibraryStore.swift`（`localPhotoIndex` / `cloudPhotoIndexCache`）、
    `LibraryStore+Query.swift`（`localPhoto(id:)` / `buildLocalPhotoIndex()` / `cloudPhoto(id:)`）。

- [x] **A2 `visibleStateKey` 改成 `Hashable` 结构体**
  - 原本：每次访问拼 30 段字符串，含 `String(describing: sidebarItem)`，17 处调用，滚动时每帧分配。
  - 现在：`VisibleStateKey: Hashable`（30 个字段），`SectionsCacheKey` / `StackPlanCacheKey` /
    `ViewerKey` 全部键在该结构体上；关键词封面缓存键也换成了结构体
    （`KeywordCoverToken`），仓库里不再有 `String(describing:)` 参与缓存键。
  - 证据：`LibraryStore+QueryKeys.swift`、`LibraryStore+Query.swift`、`LibraryStore+Viewer.swift`、
    `Features/Revisit/RevisitView.swift`、`LibraryStore+Organize.swift`。

### B. 重复

- [x] **B1 空状态统一**
  - 原本：36 处手写 `var emptyState`，与 `LumaEmptyState` / `EmptyStateView` 三套并存。
  - 现在：空态一律 `LumaEmptyState`；保留的 `var emptyState` 只是转发（加载分支留在外层）。
    `EmptyStateView` 作为「按当前入口分派文案」的薄封装保留，4 处使用
    （图库网格 / 地图 / 网盘 / 系统相册），内部同样走 `LumaEmptyState`。
  - 证据：`UI/Shared/LumaStateViews.swift`（`LumaEmptyAction.isDefaultAction` /
    `LumaEmptyActionShortcut`），36 个 `emptyState` 属性里已无自绘空态。

- [x] **B2 日期 / 相对时间统一**
  - 原本：`isDateInToday` 25 处、`今天/昨天` 与 `N 天前` 各自手写、`DateFormatter()` 83 处。
  - 现在：`isDateInToday` 降到 18 处且都只用于「是否今天」布尔判断；文案统一走
    `DateText.relativeDayOffset` / `relativeMoment` / `dayWithWeekday` / `monthDayWeekday` /
    `daysSince` / `slashDayFormatter`；per-call `DateFormatter` 大幅收敛。
  - 证据：`Sources/LumaDomain/Models.swift`（`DateText`）。

- [x] **B3 海报卡片共享 token**
  - 原本：`CatalogPosterCell` / `CinemaPosterCard` / 网络影院卡片各有一套尺寸与描边。
  - 现在：`LumaPosterMetrics`（圆角、描边、悬停描边、双层阴影、悬停时长、竖版比例）一处定义，
    三处卡片只从 token 取值。
  - 证据：`Sources/LumaUI/LumaDesign.swift`、`Cinema/CinemaPosterCards.swift`、
    `Catalog/CatalogChannelComponents.swift`、`NetworkCinema/NetworkCinemaHubPages.swift`。

### C. 遗留

- [x] **C1 超限文件拆分（8 个）**
  - 按类型拆分的 8 个文件：`TVHubView` 6587 → 10 个文件；`VideoPlayback` 4557 → 7 个；
    `PhotoViewer` 2861 → 9 个；`IPTVBrowserModel` 2503 → 11 个；`PhotoEditor` 2365 → 3 个；
    `CloudStoragesCinemaView` 2267 → 5 个；`LibraryStore+SystemLibrary` 2259 → 3 个；
    `SidebarView` 2230 → 4 个。
  - 验收：`find Sources -name "*.swift" -exec wc -l {} +` 最大文件 1969 行
    （`Features/Cinema/CinemaToolbarConsole.swift`），全部 ≤ 2000。

- [x] **C2 散落 `Task` 字段收口**
  - 原本：`Store` / `Services` 里 50 个 `var xxx: Task<` 散在各模型，
    `LibraryStore+SourceJobs.swift` 写着「后续再逐个替换」。
  - 现在：新增 `StoreTaskCenter`（52 个槽位的 `Slot` 枚举 + `adopt` / `task` / `isRunning` /
    `finish` / `cancel` / `cancelAll`），50 个字段全部迁移，`var xxx: Task<` 字段清零；
    任务创建仍留在调用点，`Task { }` 的 Actor 上下文不变；退出时
    `cancelAllBackgroundTasks()` 一次收干净。
  - 证据：`Store/Shared/StoreTaskCenter.swift`、`LibraryStore+Maintenance.swift`
    （`cancelAllBackgroundTasks()`）、`LibraryStore.swift`（终注销 observer）。
  - 例外：`Services/Cloud/Pan115Drive.swift` 的 `static var versionTask: Task<String, Never>?`
    是「同一次版本请求去重」的静态原语（带 `NSLock`，返回 `String`），不属于长耗时后台任务，
    保留原样；视图内 `@State` 任务（`CinemaMatchSheet` / `CatalogChannelComponents` /
    `VideoScrubThumbnails` / `MapCanvas`）随视图销毁，也不进任务中心。

### D. 合理性

- [x] **D1 `LibraryStore` 观察粒度（第一刀：toast）**
  - 原本：237 个 `@Published`，`toast` 这种高频瞬时值也会让 92 个观察文件重算。
  - 现在：`ChromeModel` 承接 toast；`store.showToast(_:)` 转发，`ToastView` 只观察 `ChromeModel`。
  - 证据：`Store/Shared/ChromeModel.swift`、`UI/Components/ToastView.swift`、
    `App/LumaApp.swift`（`.environmentObject(store.chrome)`）。
  - 说明：面板开关仍有 `$store.xxx` 绑定依赖，暂不迁，避免改动面失控。

- [x] **D2 `PersonAvatarLoader` 注入出口**
  - 现在：`PersonAvatarRegistry`（`cachedProvider` / `loadProvider`）由组合根注入；
    `PersonAvatarRequest` 移到 `LumaDomain`，`Features` 里不再直接引用 `PersonAvatarLoader`（18 处清零）。
  - 证据：`Sources/LumaDomain/PersonAvatarRequest.swift`、`Sources/LumaUI/PersonAvatarRegistry.swift`、
    `Services/Media/PersonAvatarLoader.swift`、`App/LumaApp.swift`。

- [x] **D3 `Components.swift` 拆分**：已拆成 4 个文件（上一轮完成）。

- [x] **D4 EXIF 拍摄时间解析三合一**
  - 原本：`ImportRules`、`SystemPhotosLibrary`、`SystemIndex+Query` 三份同样的
    `yyyy:MM:dd HH:mm:ss` 解析，各自 `DateFormatter()` 现建现用；导入 / 系统索引都是
    「每张照片一行」的路径，万张库等于上万次 formatter 分配。
  - 现在：新增 `LumaCore/EXIFDate.swift` 作为唯一入口，静态缓存一份 formatter，
    `NSLock` 包住「设置时区 + 解析」（`DateFormatter` 可跨线程，但 `timeZone` 是可变状态）。
  - 证据：`Sources/LumaCore/EXIFDate.swift`、`Services/Import/ImportService.swift`、
    `LumaPersistence/SystemPhotosLibrary.swift`、`LumaPersistence/SystemIndex.swift`；
    断言仍在 `Tests/LumaCoreChecks/ChecksImport.swift`（含时区语义校验）。

### E. 大图库时间轴（2026-11-26 修复）

十一万张图库进入「所有照片」后走 SQL 分页窗口（常驻 600 张 + 虚拟占位），
出现「右侧没有滚动条 / 快速上下滑大面积空白」。原因是虚拟占位是纯透明的，
而换页条件要求「已贴住底部」才允许决策——进页面立刻快速滚动时这个条件永远不成立，
时间轴换页被永久关掉。修复：

- 三个时间轴网格的滚动条改为常驻（`.scrollIndicators(.visible)`）。
- 落位条件去掉「必须仍贴住底部」，进页面约 0.4 秒后就能响应换页。
- 本地图库换页完成后显式落到新窗口中间那张（`timelineJumpLandingID`），
  不再依赖压缩占位与真实窗口的像素换算（两者高度不成比例，可能停在窗口外）。
- 取页任务被取消时复位 `isWindowLoading`，避免标记卡死、换页永久被挡。
- 视野落在占位区时显示「正在定位到这一段照片…」；窗口为空时显示加载态并兜底重试。

## 性能基线

`python3 Tools/dev/ui_perf.py --scenes grid-square --seconds 3`，图库
`/Volumes/后山人/李佳龙图库.photoslibrary`，可见照片 **112,003** 张（索引完成后）：

| 场景 | 轮次 | FPS | p50 | p95 | p99 | 每轮解码缩略图 |
| --- | --- | --- | --- | --- | --- | --- |
| grid-square（视野在已加载窗口、真实解码） | pass1 | 27.7 | 34.1ms | 66.9ms | 85.4ms | ~203 张（外部盘） |
| grid-square（同上） | pass2 | 34.9 | 25.9ms | 50.8ms | 60.8ms | ~203 张 |

说明（重要，之前记错过一次）：
- 早先记录的「120 FPS / p95 8.3ms」是在**视野落在虚拟占位区、没有真实单元格**时测到的，
  那正是「整屏空白」的 bug 状态，不代表加载真实照片的成本，已作废。
- 上面这组才是真实成本：每 3 秒滚动约 5,400pt，新进入视野的约 200 张要现解缩略图，
  库在外接盘上，`grid.quick` p50 ≈ 22–44ms，是当前帧率的主要瓶颈（解码，不是布局 / 查询）。
- 虚拟占位区的字典/排名计算是常数级，不参与逐帧分配。

### F. 任务中心（2026-11-26）

**F1 fire-and-forget 按需纳入**

- 系统图库的批量写操作原来是裸 `Task { }`：移动 / 删除几百张、提取整层相簿、清理空文件夹时
  界面没有任何反馈，跑完也无从回看。
- 现在统一走 `LibraryStore.runSystemLibraryJob(_:)`：登记为 `SourceJobKind.organize`（「整理」，
  不可取消，PhotoKit 本身也不给进度与取消），任务条、浮层、历史记录都能看到。
  覆盖 7 处：提取相簿、清理空文件夹、加入相簿、移出相簿、移到最前 / 最后、拖拽排序、移到最近删除。
- 有意**不纳入**的裸 `Task`：重命名 / 新建 / 单张收藏这类秒回操作（否则任务记录被刷满）、
  资源目录的 spotlight / 热榜预加载与详情抓取（<1s，且调用点已有局部 loading 态）。

**F2 展示性能**

- `TimelineView(.periodic 1s)` 原来包住整个「进行中」列表，每秒把所有卡片连同
  扫描摘要、数字格式化一起重算。现在只包「已耗时」文本与网盘扫描摘要两小块。
- 任务记录最多 200 条，原来嵌套 `VStack` 会一次实例化全部行；现在摊平成
  `JobFeedRow` 一维列表交给 `LazyVStack`，只建可见行。
- 浮层每帧要「进行中 / 记录 / 连接检测」三份数据，原来分别调三个接口各做一次合并排序；
  新增 `sourceJobFeed(finishedLimit:checkLimit:)` 一次算完。
- 记录行时间从逐行 `date.formatted` 换成缓存的 `DateText.timeFormatter`。

**F3 辨识度**

- 新增 `JobKindStyle`：24 种任务归成 6 组配色（读库蓝 / 刮削紫 / 计划青 / 传输橙 / 体检绿 / 美化粉）
  与固定图标，任务条、进行中卡片、记录行共用同一套映射。
- 进行中卡片：左侧种类色带 + 图标徽标 + 同色进度条与百分比；记录行：结果图标改成带底色圆点，
  来源行的种类图标同样上色。
- 头部新增概览：「N 个进行中 / M 个失败」，打开浮层先看到结论再看明细。

### G. 观察粒度：LibraryStore 切到 `@Observable`（2026-11-26）

**问题**

- `LibraryStore` 有 236 个 `@Published`，100 个文件用 `@EnvironmentObject var store`。
  `ObservableObject` 的粒度是「对象级」：`viewerID` / `selection` / 任一 `isLoading*` 变化，
  所有观察 `store` 的视图都会重算，这比任何单点微优化都更贵。

**改法**

- `LibraryStore` / `SelectionModel` / `ViewerModel` 改为 `@Observable`（去掉 249 个 `@Published`）。
  SwiftUI 改按「视图 body 实际读到的属性」建立依赖。
- 迁移注入：162 处 `@EnvironmentObject ... store: LibraryStore` → `@Environment(LibraryStore.self)`；
  SelectionModel / ViewerModel 共 11 处同样处理；`.environmentObject(store*)` → `.environment(store*)`。
- `$store.x` 绑定 47 处：在用到的地方加局部 `@Bindable var store = store`
  （`LumaApp` 里的 `@State` 投影本身就能给 Binding，无需改）。
- `LumaApp`：`@StateObject private var store` → `@State private var store`。
- 删除 3 处 `objectWillChange.send()`（地点解析 ×2、系统图库后台地理补齐 ×1）：
  这些派生数据（`geoPhotos` / `placeClusters`）的 getter 会读 `contentRevision` 与缓存键，
  在 `@Observable` 下已经是真实依赖。
- `LibraryPhotoGridBridge`：原来 `Merge3(store / settings / selection 的 objectWillChange)`；
  现在设置仍是 ObservableObject 走 Combine，Store 与选择模型改用
  `withObservationTracking(store.thumbSize / stackRevision / selection.ids)` 并每次重新挂载。
- `@ObservationIgnored`：`lazy` 服务（`networkCinemaModel` / `playbackProgressStore` /
  `sourceHub` / `playbackCoordinator` / `sourceContentCache` / `ingestService` /
  `aiToolRegistry` / `metadataEnrichers`）与 `deinit` 里访问的 observer / watcher
  （`@Observable` 不能把 `lazy var` 变成计算属性，`deinit` 也不能碰 actor 隔离的跟踪属性）。
- 子模型当时暂留：`CloudBrowserModel` / `CatalogBrowserModel` / `IPTVBrowserModel` /
  `NetworkCinemaModel` / `AppSettings` 在本轮先保持 ObservableObject，另立 §I 迁移。
  迁移前为了让 `store.cloud*` 这批转发属性仍能刷新，曾加过 `cloudRevision`
  （订阅 `cloudModel.objectWillChange` 推进）、15 个转发 getter 读它；
  现在这些桥接已随 §I 一起删除。

**效果**

- 改 `viewerID` 只重算读它的查看器；改 `selection` 只重算读选择的网格 / 菜单；
  改某个 `isLoading*` 只重算对应的那一块。
- 记录一行历史：视图依赖是「实际读到的属性」，不再靠「任何 Store 变化」。
- 回归：`python3 Tools/dev/ui_perf.py --scenes grid-square --seconds 3` →
  73.6 / 67.3 FPS（p50 8.3ms，缩略图 p95 23.3ms，缓存基本命中）；无崩溃报告。
  该组数据缩略图已预热，不能与上文「冷缓存 27–35 FPS」直接比较。

### H. 胶囊 / 卡片 Token 与组件（2026-11-26）

**问题**

- `Capsule()` 自绘 400+ 处，圆角、内边距、描边宽度各写一套；浅色 / 深色 / 强调色适配散落在各视图里，
  同一个「筛选胶囊」在不同页面长得不一样。

**改法**

- 新增 `Sources/LumaUI/LumaSurfaces.swift`：
  - `LumaInk`：三级墨色、发丝线、五档中性填充、强调色洗底 / 描边、`onTint` 自动前景。
  - `LumaControlMetrics`：胶囊 8/3、筛选项 8/4、发丝线 0.6、强调线 0.8、卡片圆角 10 / 内边距 10。
  - 组件：`lumaChip` / `LumaBadge` / `lumaCardSurface` / `lumaGlassPill` / `lumaPill` / `lumaPillSurface`。
- 迁移：
  - 任务中心（`SourceJobStatusBar`）：筛选胶囊、状态徽标、卡片底、进度槽；
  - 空态按钮（`LumaStateViews`）：主 / 次按钮统一走 `lumaPill` + `LumaInk.onTint`；
  - 关于页 GitHub 胶囊、图库顶栏 5 个玻璃胶囊与地点搜索框。
- 全仓 71 处 `Capsule().strokeBorder` 的描边宽度改为 token（0.5/0.6 → `hairline`，0.8/1 → `border`），覆盖 33 个文件。
- 保留：照片 / 视频画面上压的白 / 黑半透明胶囊是有意的对比色，不强行换色；装饰性进度条也不动。

**规范落点**

- `docs/ui-design-system.md` §11：Token 表、选择规则、深浅色 / 强调色、响应式、性能与迁移规则。
- `AGENTS.md` §18：硬规则与验收清单项。

### I. 子模型 `@Observable` 与超大 body（2026-11-26）

**问题**

- 上一轮只迁了 3 个核心模型，`AppSettings`(82) / `CatalogBrowserModel`(69) /
  `CloudBrowserModel`(41) / `IPTVBrowserModel`(38) / `NetworkCinemaModel`(18)
  仍是 ObservableObject：改一个设置项、翻一页频道，都会让所有读这些对象的视图整块重算。
- 另有一些 body 一次读多个属性：导入 / 扫描进度每完成一项就刷新，
  会把整张图库页（含工具栏、网格）一起重算。

**改法**

- 5 个模型全部改 `@Observable`，共移除 248 个 `@Published`：
  `AppSettings`（82）、`CatalogBrowserModel`（69）、`CloudBrowserModel`（41）、
  `IPTVBrowserModel`（38）、`NetworkCinemaModel`（18）。
  - `@ObservationIgnored`：`deinit` 里访问的 `activationObserver` / `terminateObserver` /
    `localCinemaWatcher` / `cinemaPrewarmedStream` / `recordingTimer`。
  - `IPTVBrowserModel` 三个用逗号声明的缓存键拆成独立属性（宏只接受单变量）。
- 85 个文件的注入 / 绑定迁移：
  `@EnvironmentObject` → `@Environment(Type.self)`（约 130 处）、
  `.environmentObject(x)` → `.environment(x)`（27 处）、
  `$settings.x` → `Bindable(settings).x`（124 处），以及少量 `@Bindable` / `@State`。
- 删除 §G 遗留的 `cloudRevision` / `cloudObservation` 桥接与 15 处 getter 里的占位读取；
  `LibraryPhotoGridBridge` 去掉 Combine 订阅，把 `settings.smallCoverRadius` / `accentColor` /
  `metadata` / `photoOpenMode` / `motion` 纳入 `withObservationTracking`。
- body 拆分（按「变化频率 × 重建范围」排序）：
  - `GalleryStatusOverlay`：导入 / 网盘扫描 / 系统图库读取 / 相似范围胶囊独立成视图，
    进度刷新只重算这一条，不再带上工具栏与网格（原 `GalleryView.body` 274 行）。
  - `PhotoInfoContent`：拆成 `PhotoInfoOrganizeSection` / `PhotoInfoSmartTagsSection` /
    `PhotoInfoKeywordSection` / `PhotoInfoAlbumSection` / `PhotoInfoOtherSection`，
    分析索引、相簿、网盘挂载各自更新只重算对应区块（原 body 290 行）。
- 评估后暂不动：`PhotoContextMenu.menuItems`(294) / `SettingsView.generalTab`(266) /
  `assistantTab`(269) / `CinemaToolbarConsole.body`(200) 都是事件驱动（右键菜单 / 设置窗口 / 悬停），
  长度只影响类型检查时间，不影响逐帧重算；如遇编译变慢再拆。
- 下一个候选：`VideoPlayerModel`(24) + `PlaybackSession`(4) 仍是 ObservableObject，
  `currentTime` 每 0.25 秒推进会让整个 `VideoPlayerStage` 重算；迁移后进度行可独立刷新。

**验证**

- `swift build` 通过；`LumaCoreChecks` / `LumaDataChecks` / `LumaContentChecks` 全部通过。
- `./build.sh` 重新打包 `Luma.app`（release + 本地签名）。

## 进度记录

| 项 | 状态 | 备注 |
| A1 / A2 | 已完成 | 索引 + `Hashable` 缓存键 |
| B1 / B2 / B3 | 已完成 | 空态 / 日期文案 / 海报 token |
| C1 / C2 | 已完成 | 8 个超限文件拆分；`StoreTaskCenter` 收口 50 个任务字段 |
| D1 / D2 | 已完成 | toast 拆出；人物头像注入出口 |
| D3 | 已完成 | `Components.swift` 拆分，上一轮 `67dc06a` |
| D4 | 已完成 | EXIF 拍摄时间解析三合一（`EXIFDate`），逐行 formatter 分配消除 |
| E | 已完成 | 大图库时间轴：常驻滚动条、换页落位、占位提示、取页失败兜底 |
| F | 已完成 | 任务中心：系统图库批量写纳入「整理」任务；耗时刷新收窄、记录懒加载、单次取数、种类配色 |
| G | 已完成 | `LibraryStore` / `SelectionModel` / `ViewerModel` 切 `@Observable`：249 个 `@Published` 移除、162 处注入迁移 |
| H | 已完成 | 胶囊 / 卡片 token 与组件（`LumaSurfaces`）；71 处描边收口，任务中心 / 空态 / 顶栏已迁移 |
| I | 已完成 | 5 个子模型切 `@Observable`（248 个 `@Published` 移除、85 个文件注入迁移）；图库状态胶囊与信息面板拆块 |
