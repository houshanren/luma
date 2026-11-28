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

`python3 Tools/dev/ui_perf.py --scenes grid-square --seconds 3`，在一个十万级本地图库上实测（索引完成后）：

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

### J. 播放链路 / 网格宿主收尾与场景拆分（2026-11-26）

**问题**

- `VideoPlayerModel`(24) / `VideoPlaybackUI`(19) / `PlaybackSession`(4) 仍是 ObservableObject：
  `currentTime` 每 250ms 推进一次，整条 `VideoPlayerStage`（画面层 + OSD + 控制条）跟着重算。
- LumaUI 的 `PhotoGridHost` 与 `ChromeModel` 还在用 `objectWillChange.send()` 手工广播；
  `LibraryPhotoGridBridge` 每次刷新都把它们整体失效。
- `LumaApp.body` 728 行（Window + 全部菜单命令）集中在一次类型检查里。
- 系统图库的结构写（新建 / 重命名 / 删除相簿与文件夹）是裸 `Task { }`，换库 / 退出时收不干净。

**改法**

- 播放链路：
  - 三个模型改 `@Observable`（`PlaybackCore` / `Viewer`），`PlaybackSession` 的
    `engine.$duration` + `$currentTime` 合并订阅换成 `withObservationTracking` 重新挂载，
    节流语义不变。
  - 视图 `@ObservedObject` → `let`；`controls()` 里唯一需要 Binding 的音量滑杆用局部 `@Bindable`。
  - `VideoToolbarOptions` 的 5 个 `onReceive(model.$x)` → `onChange(of: model.x)`：
    菜单只在倍速 / 循环 / 静音等离散值变化时重建，不会被时间轴带动。
  - `NowPlayingCenter` 的 Combine 订阅换成 Observation：状态变化立即刷新，
    播放时间仍按 1 秒节流写系统「正在播放」。
- 网格宿主：
  - `PhotoGridHost` / `LibraryPhotoGridBridge` / `ChromeModel` 改 `@Observable`，
    删除 `objectWillChange.send()`；LumaUI 7 处 `@EnvironmentObject host` → `@Environment(PhotoGridHost.self)`。
  - 堆叠数据依赖闭包属性：桥接只在 `stackRevision` 变化时重装 `stackBadges` / `isStackExpanded` 等闭包，
    其它参数（缩略图档位 / 圆角 / 强调色 / 选中）各自失效各自那部分视图。
- 场景拆分：`LumaApp.body` 内的命令按「应用 / 照片 / 视频 / 视图」拆成 4 个
  `@CommandsBuilder` 计算属性，body 只保留 4 个 Window 与 4 行命令引用。
- 任务收口：新增 `StoreTaskCenter.Slot.systemStructureWrite(UUID)` 与 `attach`（不取消同槽位旧任务），
  21 处系统图库结构写改走 `runSystemStructureWrite`，并发发起互不打断，换库 / 退出统一取消。

**仍待收口**

- 其余 `Task { }`（约 320 处）多为缩略图加载、UI 延时与一次性请求；任务中心已覆盖
  系统写、导入、扫描、AI、影院 / 电视 / 资源加载等长任务。后续按「可取消且跨页面存活」筛选后再纳入。

**验证**

- `swift build` 通过；三套 checks 全部通过；`Luma.app` 启动无崩溃。

### K. 图库观感对齐系统「照片」：马赛克缩放、年 / 月秒切、暖启动快照（2026-11-26）

**问题**

- 缩略图最小只到 56pt，铺不出系统「照片」那种马赛克墙；小格子仍画元数据、悬停光效与阴影。
- 缩放时每帧都在写 SQLite：`thumbSize.didSet` 里直接 `persistViewPreference` + `persistThumbSizes`，
  捏合 / 拖滑杆时一帧一次写盘，缩放明显发滞。
- 缩放跨越缩略图档位时，格子会用低清快速层覆盖已有大图，视觉上像「重新加载」。
- 年 / 月总览每次切换都要对整库重新聚合，期间显示转圈。
- 二次启动虽然命中文件缓存，但首屏仍要等分页查询返回才铺图。

**改法**

- 缩放范围 `56...360` → `28...360`；按钮 / ⌘+ / ⌘- 改走 `thumbSizeLadder`
  （28 / 36 / 48 / 64 / 84 / 110 / 144 / 188 / 246 / 320 / 360），小尺寸细步、大尺寸粗步。
- `PhotoCell` 增加马赛克档位（格子 < 56pt）：不画元数据、悬停光效、堆叠 / 收藏 / 评分角标与阴影，
  视频只留一枚小图标，加载中也不显示转圈——只画照片本身，和系统「照片」最小档观感一致。
- `thumbSize` 落盘改为停手 0.35 秒后写一次（`StoreTaskCenter.viewPreference` 槽位），
  缩放过程只改内存值。
- 缩略图加载：记录当前解码档位 `loadedPixel`；缩小不重新解码、已有图不被低清层覆盖，
  只有放大到更高档位才重新取图。
- 年 / 月总览：新增 `yearBucketCache` / `monthGroupCache`（键 = 查询 + 内容版本）；
  切换分组先命中缓存立即出图，首次加载年后后台预取月份（`overviewPrefetch` 槽位）。
- 首屏快照：分页图库第一页落地后，把最多 600 张照片异步写入图库设置表
  （`window.snapshot.meta.v1` / `window.snapshot.payload.v1`）；下次启动先铺快照再被真实查询替换，
  快照 ≤ 30 天且查询键必须匹配。
- 分页窗口随缩放变大：`windowPageSizeForCurrentZoom` 在 <48 / <76pt 时取 2400 / 1200，其余 600。
  固定 600 张在马赛克档只够铺半屏，剩下全是虚拟占位（表现为上下大片空白）。
  现在不再参与 `pagedKey`：缩放不触发取页，停手后由 `ensureWindowCoverageForZoom` 追加补齐（见 §L）。
- 官方资源复用（`.photoslibrary`）：网格缩略图已直接读 `derivatives/<首字符>/<UUID>_1_105_c.jpeg`，
  视频封面读 `_1_102_o.jpeg`，路径由 `Photos.sqlite` 的 `ZASSET.ZUUID / ZDIRECTORY` 在索引阶段算好；
  本次新增编辑成品复用：`ZADJUSTMENTTIMESTAMP` 非空的项目，查看器 / 大图优先读
  `resources/renders/<首字符>/<UUID>_1_201_a.heic|jpeg`（视频 `_2_100_a.mov`）。
- 暂不采用：`derivatives/thumbs/*.ithmb`（旧版打包缩略图，解析成本高）、
  `<UUID>.THM`（32px，只够最小档，清晰度不足）、`cvt/`（视频多帧，留作胶片条 / 悬停预览的后续素材）、
  `caches/analytics`（与图片无关）。

**验证**

- `swift build` 通过；三套 checks 全部通过；`Luma.app` 重新打包并启动。

### L. 滚动 / 缩放热路径收口：去掉逐帧重算与缩放取页（2026-11-26）

**问题**

- 上下拖动发卡：`updateVisibleDateSpan` 每滚动 8pt 就遍历 `frameCache.frames`（马赛克档可达 2400 条）
  求日期范围，并写 `store.visibleDateSpanText`（`@Observable`）→ 顶栏副标题变化 →
  `GalleryView.body` 连同整棵网格每帧重算。
- 缩放更卡并弹提示：`pagedKey` 带 `#w<pageSize>`，捏合每跨一档就让 `.task(id:)` 重新取一页，
  `replace: true` 整表替换 600 / 1200 / 2400 张照片，期间顶部弹加载转圈、格子全部重建。
- 缩略图中间的「正在定位到这一段照片…」胶囊是 `.overlay` 默认居中，滚动进虚拟占位时挡在画面中央。

**改法**

- 删除 `updateVisibleDateSpan` 与 `visibleDateSpanText`：顶栏副标题改为只读已加载窗口首尾两张
  （O(1)，仅换页时更新），不再有逐帧遍历与逐帧 `@Observable` 写入。
- 删除两处居中的「正在定位…」胶囊与顶部 `isPagedWindowLoading` 转圈浮层：滚动 / 缩放过程不再弹提示。
- `pagedKey` 去掉 `#w`：缩放不触发取页与整表替换。新增 `ensureWindowCoverageForZoom()`，
  在缩放停手 0.26 秒后（`scheduleZoomWindowFill`）按缺口 `replace: false` 追加，
  已有 PhotoItem 与单元格身份保持不变；取页途中被跳过时由 `loadedWindowPhotos.count` 变化补做。
- 预取档位跟随当前网格缩放（`prefetchGridQuick(maxPixel:)` / PhotoKit 预取同档），
  马赛克墙预取 128px，不再预热 192px 造成缓存错位。
- 新增 `ThumbnailDecodeGate`（actor 闸门，2～8 并发）：一屏上千个格子不再同时读盘解码，
  按格子出现顺序稳定出图，首屏几百毫秒内开始逐块填充（「出来一些显示一些」）；
  排队期间被滚走 / 缩放取消的格子直接放弃，不浪费读盘。马赛克档不再叠加预取，避免抢 IO。
- 缩略图分层：马赛克档（格子 ≤ 36pt）先取微缩略图层——本地 `_t.jpg`（64px，约 3KB）
  或官方图库自带的 `<UUID>.THM`（32px，约 1KB）；缺失时才读 100～300KB 的 derivative，
  解完顺带把 64px 小图写进本地缓存，下次整墙几乎瞬间铺满。微缩略图层走独立闸门（24 并发）。
  小图带新鲜度校验（比主缩略图旧就不用），避免编辑后显示旧画面。
- `PhotoCell` 马赛克档不再生成 `help` / `accessibilityValue` 文案（日期格式化在捏合每一帧都会对全墙求值），
  悬停也不逐点记录指针位置。

**验证**

- `swift build` 通过；三套 checks 全部通过；`Luma.app` 重新打包。

### M. 月视图拼贴排版（2026-11-26）

**问题**

- 月视图此前只有「首 4 天一张大卡 + 其余等宽网格」，整月看起来仍是两段式网格，不是系统「照片」
  那种每天大小不一、组合各异的拼贴。

**改法**

- 每张「某日」卡片只展示当天的一张代表照片（不再把 4 张塞进一张卡），大小与组合由拼贴决定；
  卡片封面解码档位跟随卡片尺寸，大卡不再把 220pt 小图放大到糊。
- 每天按当天照片数取权重（≥12 张 3 格、≥4 张 2 格、其余 1 格），把连续几天按权重凑成一行
  （`unitsPerRow` 随窗口宽度 4～6 格），行内宽度按权重分配。
- 首日照片多、后两天各一张时走「大卡 62% + 右侧两张堆叠」的经典组合；其余行为 1/2/3/4 张的
  等宽或比例组合，行高按组合变化（单张大卡通栏更高、四张并排更矮），拼起来就是拼贴。
- 直连模式（索引直连）同样支持：`directDayBuckets` 按「查询 + 月份」只查该月的时间区间，
  月总览的 Section 出现时才加载（`StoreTaskCenter.monthDays` 槽位 + `directMonthDaysCache`），
  数据到达前先显示该月大卡占位，到达后替换成逐天拼贴，不会整页等待。
- 卡片高度继续跟随缩略图缩放档位（`mosaicZoom`）；窄窗口（< 560pt）仍退回等宽网格。

### N. 百万级图库的性能实测与收口（2026-11-26）

**测量环境**：一个百万级本地系统图库，`Photos.sqlite` 约 27GB，外接 USB SSD。以下都是 `sqlite3` 直接对库实测（冷缓存第一次最慢）。

**实测结论（优化前）**

| 场景 | 实测 | 根因 |
| --- | --- | --- |
| 首次打开图库 | **2 分 16 秒** | `computeDirectCounts` 对 26GB 主表做一次全列聚合（二十多个 CASE + `COUNT(DISTINCT)` + LEFT JOIN） |
| 月视图某个月（2022-12，5.0 万张） | **86 秒** | `directDayBuckets` 把 `directSelect`（两个 LEFT JOIN、六十多列）塞进窗口函数，且没有 `INDEXED BY`：SQLite 用 `ZTRASHEDSTATE` 索引整库扫 + 临时表排序 |
| 年 / 月下钻、收藏按年 | **76 秒** | `directSQLSummary` 的 `COUNT(*)` 带时间区间却未指定日期索引，同样退化成整库扫 |
| 年月总览卡片样本 | 421 个月各查一次库 | `directMonthGroups` 逐月 `directPhotos(ids:)`，421 次往返都排在同一条连接的锁后面 |
| 网格滚动 | 每格两次读盘 + 两次解码 + 一次写盘 | 快速层（192px）在本地没有小文件时仍会先完整解码一次主图，再解一次目标档位 |
| 月拼贴连续下翻 | 反复「整表清空 → 全部重查」 | 逐天缓存超过 48 个月就 `removeAll()` |

关键背景：`SQLiteDatabase` 用一把 `NSRecursiveLock` 串行化同一个连接上的所有查询，
所以任何一条 86 秒的查询会把翻页、侧边栏、时间轴定位全部堵住——这就是「月/年聚合慢，其它也跟着卡」。

**改法**

- **首屏不再扫主表**：`computeDirectCounts` 只在旧图库缺索引时兜底。首次打开改走两段只读索引：
  - `computeDirectIndexedCounts`（约 6 秒）：已编辑（`Z_Asset_forRecentlyEdited`）、
    最近查看（`Z_AdditionalAssetAttributes_forRecentlyViewed` 范围查询）、导入项目
    （`..._byImportedByBundleIdentifierIndex`）、总大小（`..._byOriginalFileSize` 覆盖索引求和）、
    值得重看（日期索引数「够老的总数」再减去最近看过的重叠部分）。
  - `computeDirectScanCounts`（约 12 秒）：截屏 / 录屏 / 最近保存（`Z_Asset_forAllPhotosFilteredBySavedAssetType`
    覆盖索引一次流式扫描）、带定位（`Z_Asset_forPlacesAlbum` 覆盖索引）。
  - 两段各自完成后就落盘 + 刷新界面；只有补齐过才写指纹，中途失败下次仍会重试。
- **月视图逐天分组两段式**：先用窄查询（只取主键 / 天键 / 当天总数）在 `Z_Asset_byDateCreatedIndex`
  上做窗口聚合，再按主键批量补详情（`directPhotosByPK`）。同一个月 86 秒 → 0.28 秒。
  月拼贴每天只展示一张代表照片，样本只要 1 张（`sampleLimit: 1`）。
- **带时间区间的计数走日期索引**：`directSQLSummary` 在有 `startDate` / `endDate` 时显式
  `INDEXED BY Z_Asset_byDateCreatedIndex`，并保留去提示重试。50k 张的月份 76 秒 → 0.05 秒。
- **总览样本合并查询**：`directMonthGroups` / `directYearBuckets` 把所有周期的样本 UUID 汇总后
  按 400 个一批取回（`directOverviewPhotosByID`），421 次往返 → 1～6 次。
- **缩略图不再重复解码**：`PhotoThumbnailLoader` 只在本地已有 192px 小文件时才走快速层，
  没有小文件就一次解到目标档位（少一次随机读 + 一次解码）。
  缓存小文件改由 `ThumbnailCacheWriter` 串行低优先级写入，滚动时不再同时开上千个写任务抢盘。
- **逐天缓存先进先出淘汰**：`directMonthDaysOrder` 记录写入顺序，超过 48 个月只淘汰最旧的，
  换查询前缀才整体作废，连续下翻不再反复清空重查。
- 至此单条查询最长的是两条覆盖索引扫描（各约 5 秒，且只在首次打开跑一次），
  不再有 26GB 主表的全表聚合。

**缩略图来源实测（同一图库）**

| 项 | 实测 |
| --- | --- |
| `resources/derivatives/<分片>/`（`_1_105_c`，长边约 1024px） | 570,479 个，只覆盖约 42% 的资产 |
| 缺 `_1_105_c` 的项目 | 首屏最新 200 张里约 65%；库中段约 98% 都没有 |
| **`resources/derivatives/masters/<分片>/`（`_4_5005_c`，长边约 520px，约 36KB）** | **实测 800 个随机图片全部命中（100%）、200 个随机视频命中 199 个** |
| 原始文件 | 1.1–1.8MB JPEG（`originals/<shard>/<UUID>.jpeg`） |
| `ZEMBEDDEDTHUMBNAIL*` | 指向原图内部的内嵌 JPEG（160px、5–11KB），但仅约 17% 的项目有 |

> 结论修正：之前把「`derivatives` 只有 42%」当成「六成项目没有官方缩略图」，
> 是因为只统计了主分片目录，漏掉了 `masters/`。
> 官方其实给**全库**都生成了 5005 档网格缩略图，`_1_105_c` 只是详细查看用的更大一档。

也就是说，**旧实现滚动时最贵的一步是「明明有 5005 档却不用，硬从原图现场生成缩略图」**：
旧实现固定生成 1200px / q0.9（编码 + 写盘最慢的一档），生成完还要把刚写的文件再读一遍再解码。

**改法（缩略图层）**

- **缺 `_1_105_c` 时回退到 `masters/` 的 `_4_5005_c`**（`LibraryPaths.systemMasterThumbnailPath`），
  网格档位 ≤512px 直接用这一档出图；`tinyThumbnail` 也在解原图之前先试它。
  实测 8 并发把这一档解到 192px 是 **3,035 张/秒**，而读 2MB 原图只有 **85 张/秒**（快 36 倍），
  一屏 60 格从约 0.7 秒降到约 0.02 秒。
- 现场生成改为 **1024px / q0.85**（网格最大档位就是 1024），并**直接返回本次解码结果**，
  不再「生成 → 重读文件 → 再解码」。
- 同一次解码**顺带写出 64px 小图**；`tinyThumbnail` 增加兜底：本地小图、官方 THM、5005 档都没有时，
  才直接从原图解一张 64px 并落盘。

**打开相簿仍慢的真正原因：PhotoKit 被 `isSystemScope` 挡住了**

2.1.0 打开同一个相簿不卡，靠的不是本地缩略图，而是 `PhotoKitThumbnailProvider`
（`PHCachingImageManager` + 按窗口预取 200 张）：系统自己维护全量缩略图缓存，
连 iCloud / 共享相簿都能直接给图，一次请求通常几毫秒。

实测确认这台机器完全够用：

| 项 | 实测 |
| --- | --- |
| `PHPhotoLibrary` 打开的库 | 1,368,117 项，与 `Photos.sqlite` 完全一致（`2disk.photoslibrary` 就是系统照片图库） |
| 授权状态 | `.authorized` |
| `ZASSET.ZUUID` ↔ `localIdentifier`（`UUID/L0/001`） | 40 / 40 全部命中 |

但 `usesPhotoKitThumbnails` 原来的条件是
`isSystemScope && isNativeContainer && isAvailable`，而 `SidebarItem.isSystemScope`
只包含 `.systemLibrary` / `.systemAlbum` 这类侧边栏入口，**不包含 `.album(id)` / `.folder(id)` / `.person(id)`**。
于是打开任何一个具体相簿时条件为假，整屏退回逐格读盘解码 —— 这正是「全部照片」不卡、相簿卡的原因。

改法：

- `usesPhotoKitThumbnails` 改为 `isNativeContainer && isAvailable`：
  只要当前打开的是原生 `.photoslibrary`，相簿 / 文件夹 / 人物里的项目同样是系统图库资产，就该走 PhotoKit。
- `PhotoThumbnailLoader` 里把 PhotoKit 分支提到本地微缩略图层之前（与 2.1.0 的顺序一致）；
  本地 64px / THM / 5005 档只在 PhotoKit 取不到时兜底。

**关于「后台缩略图预热」**

不需要做。全量预热 80 万张要连续读约 1.6TB 原图（本机 USB SSD 约 200MB/s，纯 IO 两小时以上）、
再写出十几 GB 缓存，而收益只是把「首次 0.02 秒」变成「0」。既然官方 5005 档已经 100% 覆盖，
预热等于把同一份数据从原图重算一遍，纯属重复劳动。

**对标系统「照片」的取舍**

- 系统「照片」网格更快，靠的是 `resources/derivatives/thumbs/*.ithmb` 里预生成的金字塔缩略图
  （本机 3356 / 4133 / 4532 共约 27GB，`thumbnailConfiguration` 记录格式表 `[5005, 4532, 4133, 3356]`，
  帧长固定：3356 = 1,382,756 帧 × 1052B、4133 × 4124B、4532 × 14428B，分别对应 32 / 64 / 120px）。
  实测帧内数据不是 JPEG，也不是可用的像素流（帧内相邻字节差 ≈ 随机数据），
  又没有公开的压缩与索引规范，暂不解析。
- 现在 `_4_5005_c` 已覆盖全库且单格只要一次 36KB 读盘 + 一次解码，解析 ithmb 的边际收益很低。
- `derivatives/<shard>/<UUID>.THM`（32px，约 1KB）在本库只覆盖约 8%，仍作为马赛克墙的微缩略图层使用。

### O. 图库搜索改用 FTS5 全文索引（2026-11-27）

**问题**：直连模式的文本搜索是四列 `LIKE '%词%'`（文件名 / 原始文件名 / 标题 / 相机），
前后通配符用不上任何索引，等于对百万行全表扫描；带搜索词的分页与计数各跑一遍。

**优化前实测（首屏 200 行）**

| 查询 | 实测 |
| --- | --- |
| `img` | 124 秒 |
| `dsc` | 108 秒 |
| `上海` | 135 秒 |
| `canon` / `iphone` / `sony` | 约 120 秒 |
| 不存在词 | 105 秒（同样扫全表） |

**做法**：在本机应用目录建一张 FTS5（`tokenize='trigram'`）索引，
把「文件名 + 原始文件名 + 标题 + 相机厂商 / 型号 + 镜头」铺平成一行文本。

- **索引放本机**：`resources/system-search/Search-<哈希>.sqlite`。
  图库常在外置盘，边读 26GB 的 `Photos.sqlite` 边把 900MB 索引写回同一块盘会退化成随机读写。
- **两字词（中文最常见）**：trigram 至少要 3 个连续字符，实测 `上海` 直接 MATCH 返回 0。
  入库时把文本逐字符插空格（`上海外滩` → `上 海 外 滩`），查询同样插空格（`"上 海"`），
  这样任意 ≥2 字的词都能走索引；单字无法构成 trigram，退回对**本地索引**的 LIKE（约 0.36 秒）。
- **不跨库 JOIN**：实测跨库 JOIN 主表 10 万行要 13.5 秒，不可用。先由 FTS 取主键集合
  （上限 2 万，覆盖 100 页 × 200 行），再在 `Photos.sqlite` 上做 `Z_PK IN (...)` + 日期排序。
- **建索引不阻塞界面**：后台低优先级、每 5000 行一批、每批让出 0.15 秒 IO；
  独立只读连接读 `Photos.sqlite`，不占用主连接那把锁。建完 `optimize` + `wal_checkpoint(TRUNCATE)`
  回收 WAL（否则磁盘占用会翻倍）。
- **指纹失效重建**：`v2-<Photos.sqlite 大小>-<修改时间>`，导入 / 删除照片后自动后台重建。
- **建立期间**：主界面搜索直接返回空并显示「正在建立搜索索引… N%」，建好后自动刷新，
  不再退回两分钟的全表 LIKE；跨图库搜索这类离线入口仍保留 LIKE（`searchIndexStrict = false`）。

**优化后实测**

| 项 | 实测 |
| --- | --- |
| 建索引 | 156 秒 / 1,368,267 行 / 主库 904MB |
| `上海`（2 字，MATCH） | **0.004 秒** |
| `img` / `dsc` / `canon` / `heic` | 0.06 / 0.03 / 0.08 / 0.001 秒 |
| 单字 `海`（LIKE 本地索引） | 0.36 秒 |
| 不存在词 | 0.000 秒 |

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
| J | 已完成 | 播放链路 / 网格宿主切 `@Observable`（`@Published` 77 → 28、`ObservableObject` 类 16 → 10、`@EnvironmentObject` 14 → 6）；`LumaApp` 命令拆分；21 处系统结构写纳入任务中心 |
| K | 已完成 | 图库最小缩放 28pt 马赛克档、缩放落盘防抖、缩略图档位不回头、年 / 月总览缓存 + 预取、首屏暖启动快照 |
| L | 已完成 | 去逐帧日期范围重算与居中提示浮层；缩放不再重取窗口（停手后追加补齐）；预取档位跟随缩放 |
| M | 已完成 | 月视图拼贴：按当天照片数分配卡片权重与行高，大卡 + 堆叠 / 等宽组合混排 |
| N | 已完成 | 百万级性能收口：首屏去掉 2 分 16 秒全表扫描；月视图 86 秒 → 0.28 秒；带日期区间计数 76 秒 → 0.05 秒；总览样本合并查询；缩略图层：现场生成 1024/q0.85 + 复用解码结果 + 顺带落 64px 小图、马赛克墙缺图从原图兜底、缓存写入串行化 |
| O | 已完成 | 图库搜索改用 FTS5 trigram 本地索引：任意词 120～135 秒 → 0.001～0.08 秒（两字中文 0.004 秒）；索引 904MB、后台建 156 秒不阻塞界面；索引未就绪时显示「正在建立搜索索引」而非两分钟全表扫描 |
