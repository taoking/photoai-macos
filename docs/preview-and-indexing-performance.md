# 预览页空白与索引缓慢诊断报告

日期：2026-09-04。分支：`agent/phase-17-photo-culling`。
基线：`swift build` 通过，`swift test` 97 tests / 18 suites 全绿。

本报告只诊断两个用户报告的问题：**照片详情页切换到预览页面空白**、**导入照片索引很慢**。
所有数字都来自本机实测，不是估算；未实测的推断均标注为"推断"。

## 0. 现场环境

当前唯一可用来源位于安卓 MTP 挂载盘：

```text
aft-mtp-mount@macfuse0 ... (macfuse, nodev, nosuid, synchronous)
/Users/tao/Library/Application Support/DroidMount/Mounts/Android/内部存储设备/DCIM/101MSDCF
```

| 项目 | 实测值 |
| --- | --- |
| Catalog 总资产 | 8,055 项（ARW 3,987 / JPG 4,068） |
| 平均单文件大小 | 35.5 MB（ARW 单张 68.6 MB） |
| 索引覆盖的总字节 | 286 GB |
| 来源状态 | 4 个来源中 **3 个 `missing`**（2,717 项资产不可读），仅 MTP 上的 101MSDCF（5,338 项）为 `ready` |
| MTP 读取文件前 1 MB | **约 0.6 秒** |
| MTP `listdir`（5,560 项） | 0.912 秒 |
| `catalog.json` 体积 | 5.96 MB |

MTP 是无随机访问的慢速传输层，`synchronous` 挂载进一步放大了每一次读取的代价。
下面所有问题都在这个前提下被放大到用户可感知的程度。

## 1. 预览页空白

### 1.1 根因（决定性）：`kCGImageSourceCreateThumbnailFromImageAlways` 强制全图解码

出现在 6 处，覆盖 App 全部读图路径：

| 位置 | 用途 | 请求尺寸 |
| --- | --- | --- |
| `ThumbnailStore.swift:165` | 图库网格缩略图 | 480 |
| `PhotoPreviewStore.swift:108` | 大图预览页 | 2400 |
| `ImageProcessingPipeline.swift:219` | 编辑器屏幕预览（非 RAW 分支） | 调用方指定 |
| `SearchAndOCR.swift:240` | OCR 输入图 | 2000 |
| `CullingWorkflowStore.swift:149` | AI 选片清晰度/人脸信号 | 512 |
| `CleanupWorkflowStore.swift:334` | 相似照片感知哈希 | 32 |

该 flag 的语义是"**忽略内嵌预览，永远从完整图像重新渲染**"。对 68.6 MB 的 ARW，
它意味着整文件经 MTP 传输 + 完整 RAW 解码。冷文件实测（每项换用不同的未缓存文件）：

| 路径 | 现状（含 `Always`） | 仅 `IfAbsent` | 倍数 |
| --- | --- | --- | --- |
| 缩略图 480，冷 ARW | **30.04 s** | 0.441 s | 68× |
| 预览 2400，冷 ARW | **36.09 s** | 0.350 s | 103× |
| 缩略图 480，冷 JPG | 0.811 s | 0.001 s | 800× |
| 扫描期 EXIF 读取（`CopyPropertiesAtIndex`） | 0.22–0.33 s / 文件 | — | — |

点开一张 ARW，预览页需要**黑屏等待约 36 秒**——这就是用户看到的"空白"。

### 1.2 内嵌预览尺寸差异（决定修复方式）

不能简单删掉该 flag。同一批文件实测内嵌预览的实际输出尺寸：

| 请求 | ARW（原生 7008×4672） | JPG（原生 7008×4672） |
| --- | --- | --- |
| 480 | 480×321 ✅ | **120×160 ❌** |
| 2000 | 1080×1616 ✅ | **160×120 ❌** |
| 2400 | 1616×1080 ✅ | **160×120 ❌** |

Sony ARW 内嵌一幅约 1616 px 的 JPEG 预览，够用；而 JPEG 只内嵌 160×120 的 EXIF 缩略图，
无论请求多大都只返回它。**若直接删除 `Always`，4,068 张 JPG 会全部退化为 160×120**：
网格变糊、预览页糊成一团、OCR 直接失效。

因此正确修复是"**内嵌优先 + 尺寸判定回退全解码**"：内嵌预览的长边达到请求值的一半
才采用，否则回退到 `Always` 全解码。这样 RAW 走 0.15–0.56 s 的快路径，JPEG 保持现有
画质与行为不变。代价是 RAW 全屏预览为 1616 px 而非 2400 px（后续可做"先内嵌、后台升级
全解码"的二段式加载）。

### 1.3 根因：被取消的解码结果被丢弃且不入缓存

`PhotoPreviewStore.swift:44-49`：

```swift
let image = await Task.detached(priority: .userInitiated) { await PhotoPreviewRenderer.render(request) }.value
guard !Task.isCancelled, let image else { return nil }   // 丢弃发生在 storeInMemory 之前
```

`Task.detached` 不继承取消，那 36 秒**照跑不误**，只是结果在写入内存/磁盘缓存之前被扔掉。
而 `PhotoViewerView` 带 `.id(shell.photoViewerItem)`（`AppShellView.swift:1218`），每次
← → 翻页都会重建子树并取消 `.task`。结果：左右浏览时每张都解码到底、每张都丢弃，
永远收敛不到有图状态，CPU 打满而页面恒为空白。

### 1.4 根因：没有 in-flight 去重

`PhotoPreviewStore` 缺少 `ThumbnailStore.inFlightKeys` 那样的去重表，
同一张照片的并发请求会各自启动一次完整解码。

### 1.5 根因：失败态本身就长得像空白

`AppShellView.swift:1452-1462` 的失败态是 `Color.black.opacity(0.92)` 叠一个白色
`ContentUnavailableView`。当前 2,717 项属于 `missing` 来源，点开即是这个近乎全黑的空页，
且没有"重新定位文件夹"的操作入口。

### 1.6 加剧因素：单击即进预览

`AppShellView.swift:1955-1963`，无修饰键单击网格 cell 会直接 `presentPhotoViewer`。
普通选中操作就会掉进慢预览页，命中率极高。建议改为双击进入、单击仅选中。

### 1.7 加剧因素：预览/筛选退出时漏了缩略图重连

`AppShellView.swift:79-87` 只对 `isEditorPresented` 调用
`thumbnails.refreshVisibleSubscribers()`。历史上"返回图库全空白"的修复从未扩展到
PhotoViewer 与 Culling 这两个同构覆盖层，因此从预览页返回时网格也可能留白。

## 2. 索引很慢

### 2.1 根因：单线程 + 每个文件都读 EXIF

`CatalogScanner.swift:11-47` 串行遍历枚举器，`makeAsset` 对每张图调用
`ImageMetadataReader.read`（`CatalogScanner.swift:72`），实测 0.22–0.33 s/文件。
`CatalogStore.swift:527` 的 `withThrowingTaskGroup` 只 `addTask` 了一次，
是"只有一个任务的任务组"，没有任何并行。

5,338 文件 × 约 0.28 s ≈ **20–30 分钟**，且全程只用一个核心。

### 2.2 根因：每张照片新建一个 `DateFormatter`

`CatalogScanner.swift:186`。实测 5,338 次纯分配 = 0.48 s。改 `static let` 即可归零。

### 2.3 根因：全程零进度反馈，且无增量提交

`CatalogStore.swift:510` 设 `scanProgress = 0` 之后再无更新，直到扫描结束才清空；
结果只在最后 `merge` 一次性提交（`CatalogStore.swift:537`）。
用户面对的是 20–30 分钟内没有任何数字变化、一张照片都不出现——主观上就是"卡死"。
中途取消则前功尽弃。

### 2.4 根因：重扫无增量

`merge()`（`CatalogStore.swift:574`）保留了用户字段，但昂贵的 EXIF 读取此时已对全部
文件做完。按 `modifiedAt` + `fileSize` 命中即跳过，重扫可省掉接近 100% 的 I/O。

### 2.5 根因（次要，但影响筛片手感）：`persist()` 在主线程重写整份 Catalog

`CatalogPersistence.swift:29-41` 每次保存都要：读旧文件 → **完整解码校验** → 写 `.bak`
→ pretty-printed + sortedKeys 编码 → 写入。对 5.96 MB 的 catalog，用 `JSONSerialization`
实测：解析 0.026 s + 编码 0.078 s + 两次原子写 0.003 s ≈ 0.11 s；走 `PhotoAsset` 的自定义
Codable 只会更慢（推断 2–4×）。它挂在每一次评分/标记/备注修改上并同步跑在 main actor，
筛片时每按一次星星都要停顿。

### 2.6 根因：缩略图队列是串行的

`ThumbnailStore.swift:56` 是串行 `DispatchQueue`。叠加 1.1 的 30 s/张，
满屏 20 张 ARW 需要约 10 分钟才能填满。

### 2.7 根因：预览磁盘缓存无淘汰

`PhotoPreviewStore` 将 2400px 图以未压缩 TIFF（约 15 MB/张）写入
`~/Library/Caches/PhotoAI-Mac/PhotoViewer/`，没有任何清理策略。
浏览完这个 8,055 项图库会写出超过 100 GB。

### 2.8 遗留数据

`~/Library/Application Support/PhotoAI-Mac/` 下存在 **356 MB 的 `catalog.archive.sqlite`**
（含 `-shm`/`-wal`）与 `ArchivePreviews/`（258 项），来自当前源码树中已不存在的 Phase 14
SQLite 方案，属于死数据。

## 3. 修复优先级

| # | 修复项 | 影响 | 状态 |
| --- | --- | --- | --- |
| 1 | 6 处改为内嵌优先 + 尺寸判定回退全解码 | RAW 路径 68–103×，两个问题同时缓解 | 本轮 |
| 2 | `PhotoPreviewStore` 先入缓存再判取消 + in-flight 去重 | 消除翻页永不收敛的空白 | 本轮 |
| 3 | 扫描并行化 + `DateFormatter` 静态化 + 实时进度 + 分批 merge | 索引从 20–30 min 降到分钟级 | 待办 |
| 4 | 重扫按 mtime/size 跳过未变文件 | 重扫接近零成本 | 待办 |
| 5 | `persist()` 防抖 + 移出主线程；`.bak` 校验不必每次全量解码 | 消除评分停顿 | 待办 |
| 6 | 单击改双击进预览；`missing` 来源提供"重新定位"入口 | 降低误入慢路径与空白页 | 待办 |
| 7 | 预览缓存改有损编码并加容量上限 | 避免 100 GB 级缓存膨胀 | 待办 |
| 8 | 清理 Phase 14 遗留 SQLite 数据 | 回收 356 MB | 待办 |

## 4. 本轮修复（优先级 1+2）与验证

### 4.1 修复 1：内嵌预览优先 + 尺寸判定回退

新增 `Sources/PhotoAIMac/DownsampledImageDecoder.swift` 作为全 App 唯一的降采样解码入口，
并替换了原先散落的 6 处 `kCGImageSourceCreateThumbnailFromImageAlways`：
`ThumbnailStore`、`PhotoPreviewStore`、`ImageProcessingPipeline`、`SearchAndOCR`、
`CullingWorkflowStore`、`CleanupWorkflowStore`。

判定规则：内嵌预览的长边达到请求尺寸的 50% 即采用，否则回退到完整解码。
阈值取 0.5 而非 1.0，是为了让 ARW 的 1616 px 内嵌预览可以服务 2400 px 的大图预览请求。

**注意：不能简单删除该 flag。** 报告 1.2 节的实测显示 JPEG 只内嵌 160×120 的 EXIF 缩略图，
无论请求多大都只返回它；直接删除会让本机 4,068 张 JPG 全部退化为 160×120 并使 OCR 失效。

### 4.2 修复 2：`PhotoPreviewStore` 先入缓存 + in-flight 去重

- `image(for:)` 改为经由一个按 `cacheKey` 去重的解码任务；解码结果在任何情况下都先写入
  内存与磁盘缓存，再返回给调用方，不再因调用方已取消而丢弃。
- 相同 `cacheKey` 的并发请求共享同一次解码。
- 新增 `decodeCount` 供测试断言实际解码次数。

### 4.3 实测验证：修复后（真实 MTP 冷文件，使用发布代码）

| 路径 | 修复前 | 修复后 | 输出尺寸 |
| --- | --- | --- | --- |
| 缩略图 480，冷 ARW | 30.04 s | **0.681 s** | 480×321 |
| 预览 2400，冷 ARW | 36.09 s | **0.550 s** | 1616×1080 |
| OCR 2000，冷 ARW | — | 0.324 s | 1616×1080 |
| 选片 512，冷 ARW | — | 0.500 s | 512×342 |
| 感知哈希 32，冷 ARW | — | 0.628 s | 32×21 |

JPEG 路径做了同规格（约 3.0 MB）冷文件的交错受控 A/B，确认**无回归**：

| | 平均耗时 | 输出尺寸 |
| --- | --- | --- |
| 旧实现（`Always`） | 1.658 s | 320×480 |
| 新实现（内嵌优先 + 回退） | 1.500 s | 320×480 |

多出的一次内嵌探测复用同一个 `CGImageSource`，代价落在 MTP 抖动噪声内。

> 取样提醒：首轮曾测得 JPEG 6.6 s，是因为误用了 13.5 MB 的文件与 3.5 MB 的文件对比；
> 上表为同规格受控重测的结果。

### 4.4 自动化回归

- `swift build`：PASS。
- `swift test`：PASS，**103 tests / 19 suites**（修复前 97 / 18，本轮新增 6 项）。
  整套测试耗时从 28.10 s 降到 1.84 s——OCR 两项测试各自从约 28 s 降到 1.6 s，
  是修复 1 在真实解码路径上的直接体现。
- `Scripts/build-debug-app.sh`：PASS，`.build/PhotoAI-Mac.app` 已用当前源码重新组装并临时签名。
- `git diff --check`：PASS。

新增测试 `Tests/PhotoAIMacTests/PreviewDecodingTests.swift`（6 项）：

| 测试 | 覆盖 |
| --- | --- |
| `embeddedPreviewIsRejectedWhenTooSmallForRequest` | 160×120 内嵌缩略图被拒；1616 px 内嵌预览被接受 |
| `decoderReturnsRequestedResolutionWhenNoUsableEmbeddedPreviewExists` | 无可用内嵌预览时回退全解码并给出请求尺寸 |
| `decoderDoesNotUpscaleImagesSmallerThanRequest` | 原图小于请求时不放大 |
| `decodedPreviewIsCachedEvenWhenTheCallerWasCancelled` | 调用方已取消时解码结果仍入缓存 |
| `concurrentRequestsForTheSamePhotoDecodeOnlyOnce` | 并发请求只解码一次 |
| `cachedPreviewIsServedWithoutDecodingAgain` | 二次请求直接命中缓存 |

其中后两项已通过"临时回滚为修复前语义"验证过确实会失败
（`decodeCount == 1` 与 `cachedImage != nil` 两处断言均不满足），确保不是空测试。

### 4.5 尚未验证

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| 真机 UI 点击验证（点开 ARW 是否秒出预览、翻页是否连续） | **NOT RUN** | 调试包已就绪，需在本机实际操作确认 |
| RAW 全屏预览降为 1616 px 的观感是否可接受 | **NOT RUN** | 需人工判断；如不可接受，可加"先内嵌、后台升级全解码"的二段式加载 |
| AI 选片/相似清理分数因改用内嵌预览产生的变化 | **NOT RUN** | 分数在组内仍然一致，但绝对值与修复前不同 |

## 5. 本轮修复（优先级 3–5）与验证

### 5.1 修复 3：扫描并行化 + 静态化日期解析 + 真实进度 + 首次导入增量显示

- `CatalogScanner` 拆成两步：先 `candidateFileURLs` 只枚举路径并按扩展名过滤（不碰图像内容），
  再由新增的 `scanConcurrently` 按 CPU 核数（上限 8）并行读取元数据，分块回报 `ScanBatch`。
  并行版本刻意换了名字：它与同步版只差若干带默认值的参数，同名重载在 async 上下文里会被
  静默解析成并行版，调用方看不出自己用的是哪个。
- 新增 `EXIFDateParser` 手写解析 `yyyy:MM:dd HH:mm:ss`，替换掉每张照片新建的 `DateFormatter`
  （实测 5,338 次分配约 0.48 秒）。`DateFormatter` 同时也不是 `Sendable`，无法在并行扫描中共享。
- `scanProgress` 由 `[UUID: Int]` 改为 `[UUID: CatalogScanProgress]`（已扫描 / 总数 / 比例）。
  **此前这个属性从未被任何界面读取过**——`FolderSourceList` 只显示一句静态的"正在后台扫描…"，
  这正是长时间扫描"看起来卡死"的直接原因。现在列表显示真实计数与进度条。
- 首次导入时按批把照片追加进图库，边扫边出现；重扫已有来源仍在结束时统一 `merge`，
  避免与既有条目重复。批次按任务完成顺序到达，因此导入过程中的排序不是最终排序，
  扫描结束时的 `merge` 会统一排序。

### 5.2 修复 4：重扫跳过未变文件

`CatalogStore.rescan` 把上一次该来源的索引按 `relativePath` 交给扫描器；
`makeAsset` 在读取 EXIF **之前**比对 `fileSize` 与 `modifiedAt`，命中就直接复用旧记录。

### 5.3 修复 5：Catalog 写入移出主线程并合并

- 新增 `CatalogWriter` actor，编码与写盘都在它上面执行；主线程只做一次 O(1) 的数组引用拷贝。
- `persist()` 只记录 `pendingSnapshot`；写入进行中的后续改动仅替换它，不排队重复写整份 Catalog。
- `.bak` 的解码校验改为**每进程仅一次**：只有来自上一次运行的主快照才可能是崩溃留下的半截文件，
  本进程自己编码写出的主快照按构造即有效。
- 写入变成异步后，"改完立刻从磁盘读回"的调用方必须先 `await flushPendingPersist()`。
  这是一次明确的契约变更，4 个既有测试已相应更新。

### 5.4 实测验证（真实 MTP 冷文件，48 个 ARW 一组，两组互不重叠）

| 项目 | 实测 |
| --- | --- |
| 串行读 EXIF，48 个冷 ARW | 34.59 s（0.721 s/文件） |
| 并行（8）读 EXIF，48 个冷 ARW | **6.79 s（0.142 s/文件），加速 5.09×** |
| 重扫快路径（仅 stat），48 个文件 | **0.003 s** |

按 5,338 个文件的实际来源外推：

| 场景 | 修复前 | 修复后 |
| --- | --- | --- |
| 首次导入 | 约 64 分钟，无任何进度显示 | 约 13 分钟，显示实时计数与进度条，照片边扫边出现 |
| 重扫（文件未变） | 约 64 分钟 | **约 1.2 秒**（0.9 s 枚举 + 0.3 s stat） |

MTP/macFUSE 并未把并发请求完全串行化，因此并行在这块盘上确实有效；
本地 SSD 与外置硬盘的收益只会更大。

写入合并实测：连续 20 次评分改动，实际落盘 **1 次**（测试中直接断言）。

### 5.5 自动化回归

- `swift build`、`swift test`（**109 tests / 21 suites**）、`Scripts/build-debug-app.sh`、
  `git diff --check` 均 PASS。

新增测试：

| 测试 | 覆盖 |
| --- | --- |
| `matchesTheDateFormatterItReplaced` | 手写 EXIF 解析与被替换的 `DateFormatter` 在 12 组输入上逐个等价（含全 0、非法月日、24 时、错误分隔符） |
| `concurrentScanMatchesSerialScanAndReportsProgressToCompletion` | 并行结果与顺序同串行一致；进度单调递增且收敛到总数 |
| `unchangedFilesReuseThePreviousIndexInsteadOfRereadingMetadata` | 大小与修改时间未变时复用旧记录（用只可能来自 EXIF 的 `cameraModel` 哨兵验证跳过） |
| `changedFilesAreReadAgainInsteadOfReused` | 文件变化时必须重新读取 |
| `catalogStoreFeedsThePreviousIndexBackIntoRescan` | 验证 `CatalogStore` 确实把上一次索引接线给了扫描器 |
| `rapidMetadataChangesCoalesceIntoASingleWrite` | 20 次连续改动合并为 1 次整表写入，且最终值正确落盘 |

### 5.6 尚未验证

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| 真机完整导入 5,338 项 | **NOT RUN** | 需约 13 分钟的真实设备占用；上表为 48 文件实测外推 |
| 首次导入过程中的网格填充观感 | **NOT RUN** | 批次按完成顺序到达，导入中的排序与最终排序不同，需人工确认可接受 |
| 退出 App 时仍有待写入快照的情况 | **NOT RUN** | 当前没有终止钩子；写入在改动后立即发起，窗口极小但非零 |

## 6. 第三轮修复（剩余待办）与验证

### 6.1 单击改双击进入预览

`CatalogAssetCell` 与 `ApplePhotosAssetCell` 此前无修饰键单击就直接打开大图预览，
"在网格里挑一张"这种最普通的操作也会掉进解码路径。现在单击只负责选中，
双击才进入预览；同时补上右键菜单与 `accessibilityAction`，让键盘（Space）、
鼠标右键与 VoiceOver 都有不依赖双击的入口。

### 6.2 missing 来源的重新定位入口

新增 `CatalogStore.relocate(_:to:)`：换新书签与路径、保留 `sourceID` 与 `relativePath`，
随后重扫。因为资产身份由 `sourceID + relativePath` 决定，重新定位后资产 ID 稳定，
评分、标记、调整配方与人脸关联都不丢。入口出现在两处：`FolderSourceList` 中
`missing` / `inaccessible` 来源的行内按钮，以及「缺失文件」页顶部的横幅。
指向已被索引的文件夹会被拒绝，避免同一批文件被索引两次。

### 6.3 预览磁盘缓存改 JPEG 并加容量上限

新增 `PhotoPreviewCacheMaintenance`：以 JPEG（质量 0.85）替代未压缩 TIFF，
按总字节预算（默认 2 GB）淘汰最久未读取的文件，并无条件清除旧版本遗留的 `.tiff`。
启动时后台执行一次维护，回收上一次运行留下的超额缓存。

### 6.4 缩略图队列改为有界并发

`ThumbnailStore.renderingQueue` 由串行 `DispatchQueue` 改为
`maxConcurrentOperationCount = min(6, 核数)` 的 `OperationQueue`：
串行会让满屏 RAW 只能逐张解码，而不设上限则会在快速滚动时堆出大量并发解码。

### 6.5 退出前落盘

新增 `PhotoAIAppDelegate`，`applicationShouldTerminate` 返回 `.terminateLater`，
等 `flushPendingPersist()` 完成后再放行。Catalog 写入改异步后，
这是保证最后一次评分或标记不会在退出瞬间丢失的必要一环。

### 6.6 归档遗留数据

源码树对 `sqlite` / `archive` / `ArchivePreviews` **零引用**（唯一 grep 命中是发布脚本里
一句无关的英文提示），Phase 14 的相关提交在当前分支已无对应代码，确认为孤儿数据。
按项目自身的非破坏性原则**移入废纸篓**而非删除，可随时"放回原处"还原：

| 项目 | 实际体积 |
| --- | --- |
| `catalog.archive.sqlite`（含 `-shm` / `-wal`） | 576 MB |
| `ArchivePreviews/` | 1.0 GB |
| 合计回收 | **约 1.6 GB** |

> 报告第 2.8 节此前记为 356 MB，是按当时的文件大小估的；实际清理时 sqlite 已增长到
> 576 MB，且 `ArchivePreviews/` 远大于预期。`catalog.json`、`catalog.json.bak`、
> `people.json` 与 `catalog.json.phase14-pre-sqlite.bak` 都是现役数据或真实备份，未触动。

### 6.7 顺带修掉的真实缺陷：`.scanning` 跨重启存活

清理时发现真实 `catalog.json` 里有一个来源停在 `status: "scanning"`——
App 在扫描途中被退出，而扫描期的持久化把这个**运行时瞬时状态**写进了快照，
下次启动就会看到一个永远停在"正在扫描"的来源。
`CatalogSnapshot.migrateInPlace()` 现在在读取时把 `.scanning` 一律归位为 `.ready`。

### 6.8 自动化回归

- `swift build`、`swift test`（**117 tests / 24 suites**）、`Scripts/build-debug-app.sh`、
  `git diff --check` 均 PASS。

新增测试：

| 测试 | 覆盖 |
| --- | --- |
| `relocatingAMissingSourceKeepsAssetIdentityAndLocalState` | 重新定位后资产 ID、评分、标记、相对路径全部保留 |
| `relocatingToAFolderAlreadyIndexedIsRejected` | 拒绝指向已被索引的文件夹，且不破坏原有来源 |
| `diskCacheUsesLossyEncodingInsteadOfUncompressedTIFF` | 缓存文件为 `.jpg` 且远小于未压缩体积 |
| `diskCacheEvictsLeastRecentlyUsedFilesBeyondTheBudget` | 超预算时淘汰最久未用者，并清除 `.tiff` 残留 |
| `budgetEnforcementKeepsEverythingWhenUnderBudget` | 未超预算时不误删 |
| `terminationWaitsForPendingCatalogWrites` | 有待写入工作时请求延后退出并真正等待落盘 |
| `terminationIsImmediateWhenNothingIsPending` | 无待办时立即退出 |
| `scanningStatusNeverSurvivesReload` | `.scanning` 不会跨重启存活 |

### 6.9 尚未验证

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| 双击进入预览的真机手感 | **NOT RUN** | 单击/双击与既有 shift、command 多选的组合需人工确认 |
| 真机重新定位一个 missing 来源 | **NOT RUN** | 自动化已覆盖逻辑；真实盘符变化场景待确认 |
| 退出时的 `.terminateLater` 真机行为 | **NOT RUN** | 单元测试覆盖了委托逻辑，真实退出路径需人工确认 |

## 7. 需求变更：派生图从"缓存"升级为"索引"

### 7.1 变更内容

第 6 轮之后需求扩展：扫描过的照片，即使外置盘或临时卷退出，预览也要继续显示；
卷再次接回时又要对应回原文件。也就是说这个应用不只做预览，还要做**索引**。

这条需求改变了派生图的性质——它不再是"随时可丢弃的派生数据"，而是**卷离线期间
那些照片在本机的唯一表示**。据此调整了三条既有决策：

| 原决策 | 调整后 | 原因 |
| --- | --- | --- |
| 存 `~/Library/Caches/` | 存 `~/Library/Application Support/` | Caches 会被系统在磁盘压力下清除，且默认不进 Time Machine |
| 总量预算 + LRU 淘汰 | 取消，改为按来源显示占用、移除时清理 | LRU 会优先删掉长期离线的卷——恰恰是**无法重建**的那些 |
| 文件名含修改时间 | 只用 `assetID` | 外置盘/exFAT 重新接回时时间戳可能漂移，会让整卷缓存落空并留下孤儿文件 |

同时目标平台明确为**内置磁盘与外置 SSD**，MTP 降级为"能用但不为它优化"。

### 7.2 关键实测：一次解码可产出所有级别

n=6，真实照片，解出最大一级后在内存内缩放出其余级别：

| 原文件 | 解码得到 | 480 | 1280 | 1600 | 2400 |
| --- | --- | --- | --- | --- | --- |
| ARW | **1616×1080**（内嵌预览） | 56 KB | 290 KB | 409 KB | 405 KB |
| JPG | 2400×1600（全解码） | 56 KB | 301 KB | 432 KB | 851 KB |

ARW 请求 2400 实际只有 1616，**2400 这一级对 RAW 毫无意义**。

| 尺寸 | 单张均值 | 5 万张 |
| --- | --- | --- |
| 480 px | 52.4 KB | 2.50 GB |
| 1280 px | 273.3 KB | 13.03 GB |
| **1600 px** | **389.9 KB** | **18.59 GB** |
| 2400 px | 585.2 KB | 27.90 GB |

**结论：昂贵的是读文件加解码，不是编码。** 增加一个级别的代价是磁盘空间，不是时间。
这推翻了"大图预览要单独排队、优先级最低"的前提——它可以和缩略图在同一次解码里免费产出。

选定 1600 作为离线预览级别：它恰好对齐 Sony ARW 内嵌预览的原生尺寸，对 RAW 零损失；
2400 要多花 9.3 GB 却只对 JPEG 原图有意义。

### 7.3 空间预算（每万张，含 480 缩略图）

| 离线预览档位 | 占用 | 5 万张 |
| --- | --- | --- |
| 关闭 | 0.5 GB | 2.5 GB |
| 1280 | 3.1 GB | 15.5 GB |
| **1600（默认）** | **4.2 GB** | **21.1 GB** |
| 2400 | 6.1 GB | 30.4 GB |

### 7.4 A 阶段：存储结构

```text
~/Library/Application Support/PhotoAI-Mac/Derived/
    <sourceID>/thumbnails/<assetID>.jpg    480 px
    <sourceID>/previews/<assetID>.jpg     1600 px
```

- `ThumbnailRequest` 与 `PhotoPreviewRequest` 合并为 `DerivedImageRequest`——
  它们描述同一个文件、走同一次解码，分成两个类型只会误导后来的人。
- 加载新增 `allowsRendering`：来源离线时只读缓存，不去碰读不到的原文件。
- 有缓存的离线照片正常显示并带"离线"角标；`未缓存 · 来源离线` 才是占位图。
- 启动时回收 Caches 下的旧布局。

### 7.5 B 阶段：全卷预热与三级回退

- 扫描完成自动把整卷排进后台预热，两级在同一次解码里产出。
- **已有缓存直接跳过**，因此天然可续跑：中断、退出、重启、重扫都不重做。
- 有交互解码在飞时预热主动让路，慢速卷上点开照片不会排在整卷预热后面。
- 大图预览三级回退：内存预览 → 已有缩略图放大顶上 → 实时解码就绪后替换。
  **空白页至此在结构上不可能出现**，而不是依赖"够快"。

### 7.6 C 阶段：卷生命周期与设置

- 监听 `NSWorkspace.didMountNotification`：记录路径重新出现的来源自动重扫恢复；
  换了盘符的仍走"重新定位"。
- 设置页可选离线预览级别（关 / 1280 / 1600 / 2400），每档标注实测占用。
- 预热的级别集合改为可注入，避免测试去改 `UserDefaults.standard` 污染真实偏好。

### 7.7 自动化回归

`swift build`、`swift test`（**137 tests / 33 suites**）、`Scripts/build-debug-app.sh`、
`git diff --check` 均 PASS。

新增测试（节选）：

| 测试 | 覆盖 |
| --- | --- |
| `prewarmingGeneratesEveryTierForTheWholeSource` | 整卷两级全部生成 |
| `photosStayVisibleAfterTheVolumeGoesAway` | **删掉原文件后照片仍可见**——离线索引需求的验收点 |
| `alreadyCachedAssetsAreCountedWithoutRedoingWork` | 已缓存跳过，续跑不重做 |
| `derivedImagesAreStoredPerSourceAndSurviveTheOriginal` | 按来源分目录落盘 |
| `offlineSourcesReadFromCacheWithoutTouchingTheOriginal` | 离线只读缓存 |
| `removingASourceDropsItsDerivedImages` | 移除来源清空其派生图 |
| `staleEntriesAreIgnoredWhenTheOriginalIsNewer` | 原文件更新后缓存判为过期 |
| `remountedSourcesRecoverAndUntouchedOnesStayMissing` | 接回的卷自动恢复，没接回的保持 missing |
| `onlyThumbnailsArePrewarmedWhenOfflinePreviewIsDisabled` | 关闭离线预览时只产出缩略图 |

顺带修复的测试卫生问题：`ThumbnailStore()` 的默认缓存路径改到真实 Application Support 后，
有 4 处测试会写进用户真实数据，已全部改为注入临时目录。

### 7.8 验证状态

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| 固态盘照片导入 | **PASS** | 用户实机反馈：已导入固态盘照片，效果良好 |
| 卷退出后离线浏览 | **NOT RUN** | 自动化已覆盖（删除原文件后仍可见）；真实拔盘场景待确认 |
| 卷接回后自动恢复 | **NOT RUN** | 自动化已覆盖路径恢复逻辑；真实挂载事件待确认 |
| 5 万张规模的预热耗时与占用 | **NOT RUN** | 本地盘实测单张约 0.04 s，6 路并发下 5 万张估算 10–15 分钟 |
| 双击进入预览的真机手感 | **NOT RUN** | 与 shift / command 多选的组合待确认 |
| 退出时 `.terminateLater` 真机行为 | **NOT RUN** | 单元测试覆盖委托逻辑，真实退出路径待确认 |
