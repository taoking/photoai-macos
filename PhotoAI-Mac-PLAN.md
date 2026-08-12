# PhotoAI Mac — macOS 27 智能照片管理与 RAW/LUT 编辑 App 开发计划

> 工作名：**PhotoAI Mac**  
> 建议仓库：`taoking/photoai-macos`  
> 建议 Bundle ID：`com.taoking.PhotoAIMac`  
> 最低系统：**macOS 27+**  
> 开发环境：**Xcode 27+ / Swift 6.x / SwiftUI + 必要的 AppKit**  
> 产品原则：**On-device First / Non-destructive / Local-first / Desktop-first**

---

## 1. 项目定位

PhotoAI Mac 不是 iOS PhotoAI 的简单放大版，而是面向 Mac 桌面工作流重新设计的照片管理与编辑应用。

核心使用场景：

1. 本地目录、移动硬盘、SSD、SD 卡中的照片管理。
2. JPEG / HEIF / RAW 的非破坏编辑。
3. `.cube` LUT 管理与应用。
4. 星级、Pick / Reject、批量筛选。
5. 批量复制调整参数、同步调整、批量导出。
6. Metadata / OCR / People / AI 搜索。
7. 重复照片、相似照片和 RAW+JPEG Pair 整理。
8. 后续 AI 辅助选片。
9. Apple Photos / iCloud Photos 作为可选数据源。
10. 后续视频管理、LUT、智能片段分析。

第一版不追求完整替代 Lightroom / Capture One，而是先完成：

```text
导入 / 索引
→ 管理
→ 快速筛选
→ RAW / JPEG 编辑
→ LUT
→ 批量处理
→ 导出
```

---

## 2. 与 iOS PhotoAI 的关系

已有 iOS 项目：

```text
taoking/photoai-ios
```

现有 iOS 工程中的以下部分优先评估复用：

```text
Domain
RAW
LUT
Search
Persistence
AnalysisCoordinator
CacheKey
TemporaryFileStore
部分 AI / Vision 抽象
```

Mac 版不得为了“共享代码”在 Phase 0 就大规模重构 iOS 工程。

正确顺序：

```text
1. 验证现有模块是否可在 macOS 27 编译和工作
2. Mac 项目先落地
3. 找到稳定共用边界
4. 再决定是否提取 photoai-core
```

长期目标可以演进为：

```text
photoai-core
├── Domain
├── RAW
├── LUT
├── Search
├── Similarity
├── Persistence
└── AI abstractions

photoai-ios
└── iOS / PhotoKit / Mobile UI

photoai-macos
└── FileSystem / Desktop UI / macOS workflow
```

---

## 3. 核心原则

### 3.1 不破坏原图

默认绝不修改原始文件。

原图：

```text
DSC01234.ARW
```

编辑只保存：

```text
EditRecipe
```

导出时重新渲染：

```text
Original
→ RAW Decode / Image Decode
→ Adjustment Recipe
→ LUT
→ Crop / Rotate
→ Output Render
→ Export
```

### 3.2 本地优先

默认：

- 不要求登录。
- 不依赖服务器。
- 不上传照片。
- 不要求第三方 API Key。
- AI / OCR / People 尽可能本地处理。
- Foundation Models 不可用时核心功能仍正常。

### 3.3 Desktop-first

Mac 版必须优先支持：

- 鼠标。
- 键盘。
- 触控板。
- 多窗口。
- 大屏幕。
- 快捷键。
- 拖放。
- Finder。
- 外接硬盘。
- 批量操作。

禁止照搬 iPhone 单栏 NavigationStack 体验。

---

# 4. 数据源

第一阶段数据源优先级：

```text
P0 Local Folder
P0 External SSD/HDD
P0 SD Card
P1 Drag & Drop
P2 Apple Photos
P2 iCloud Photos
```

## 4.1 本地目录

用户可以：

```text
Add Folder
Add External Drive Folder
Drag Folder
Open Recent Source
```

应用默认不复制原图，只建立索引。

## 4.2 文件重定位

不能只保存绝对路径：

```text
/Volumes/PHOTO/2026/DSC0001.ARW
```

建议组合：

```text
Security Scoped Bookmark
Volume Identifier
File Resource Identifier
Relative Path
Filename
File Size
Optional Content Hash
```

支持：

- 外置硬盘重连。
- 卷名变化。
- 文件夹移动后的重新定位。
- Missing File 状态。
- Locate Missing Folder。

---

# 5. Catalog

推荐建立独立本地 Catalog。

核心模型示意：

```swift
PhotoAsset {
    id
    sourceID

    bookmarkData
    volumeIdentifier
    fileIdentifier
    relativePath

    filename
    fileExtension
    fileSize
    contentHash

    captureDate
    width
    height

    cameraMake
    cameraModel
    lens
    focalLength
    aperture
    shutterSpeed
    iso

    latitude
    longitude

    mediaType
    rawType

    rating
    flag
    favorite

    ocrText
    aiCaption
    tags

    editRecipeID

    createdAt
    updatedAt
}
```

辅助模型：

```text
PhotoSource
PhotoAsset
EditRecipe
Album
AlbumItem
PersonRecord
PersonAsset
Tag
AssetTag
SimilarityGroup
LUTRecord
ExportPreset
AnalysisState
```

---

# 6. 导入与后台分析

必须采用分层扫描。

禁止用户一添加目录就对全库执行：

```text
RAW full decode
OCR
AI caption
Face analysis
Similarity
```

推荐：

```text
P0 File enumeration
P1 Basic metadata
P2 EXIF
P3 Thumbnail / embedded preview
P4 OCR
P5 Face / People
P6 Similarity
P7 AI semantics
```

高成本分析必须：

- 有界并发。
- 可取消。
- 可暂停。
- 可恢复。
- 可查看真实进度。
- 不阻塞 UI。
- 不无限增长内存。
- 单张失败不能导致整个目录失败。

---

# 7. UI 结构

推荐主界面：

```text
┌────────────┬──────────────────────────────┬──────────────┐
│ Sidebar    │                              │ Inspector    │
│            │                              │              │
│ Library    │          Photo Grid          │ Metadata     │
│ Folders    │                              │ Histogram    │
│ Albums     │                              │ Rating       │
│ People     │                              │ Tags         │
│ Search     │                              │ Camera       │
│ Cleanup    │                              │ Lens         │
│            │                              │ Location     │
└────────────┴──────────────────────────────┴──────────────┘
```

Editor：

```text
┌────────────┬──────────────────────────────────┬──────────────┐
│ Sidebar    │                                  │ Adjustments  │
│            │                                  │              │
│            │            Preview               │ Light        │
│            │                                  │ Color        │
│            │                                  │ Curve        │
│            │                                  │ Detail       │
│            │                                  │ LUT          │
│            │                                  │ Crop         │
├────────────┴──────────────────────────────────┴──────────────┤
│                         Filmstrip                           │
└────────────────────────────────────────────────────────────┘
```

---

# 8. Library

必须支持：

```text
All Photos
Recent Imports
Favorites
RAW
Videos
Missing Files

Folders
Albums
Smart Albums
People
Search
Cleanup
```

Grid：

- Lazy loading。
- 缩略图缓存。
- 滚动时不读取 full resolution。
- 可调整 thumbnail size。
- Selection。
- Shift 多选。
- Command 多选。
- Context Menu。
- Drag & Drop。
- Quick Look 风格预览。

Inspector：

```text
Filename
Capture Date
Dimensions
Camera
Lens
Focal Length
Aperture
Shutter
ISO
File Size
File Type
Location
Rating
Flag
Tags
People
```

---

# 9. 筛片工作流

优先实现：

```text
1–5 Star
Pick
Reject
Favorite
```

快捷键建议：

```text
← / →        Previous / Next
Space        Large Preview
1–5          Rating
0            Clear Rating
P            Pick
X            Reject
U            Unflag
G            Grid
E            Editor
Cmd + E      Export
Cmd + C      Copy Adjustments
Cmd + V      Paste Adjustments
```

目标场景：

```text
1000 张旅行照片
→ 快速预览
→ Pick / Reject
→ 评分
→ Filter 4–5 Star
→ 批量调整
→ Export
```

---

# 10. 编辑器

第一阶段支持：

```text
Exposure
Contrast
Highlights
Shadows
Whites
Blacks

Temperature
Tint
Saturation
Vibrance

Sharpness
Noise Reduction

Crop
Rotate
Straighten

LUT
LUT Intensity
```

后续：

```text
Tone Curve
HSL
Color Mixer
Dehaze
Vignette

Linear Gradient
Radial Mask
Brush Mask
Subject Mask
Sky Mask
```

---

# 11. RAW

首版以 Core Image 为核心：

```text
CIRAWFilter
CIImage
CIContext
```

所有 macOS 27 / Xcode 27 Beta API 必须先通过本机 SDK Spike 验证，不得凭记忆假定 API。

优先真实验证：

- Sony ARW。
- DNG。
- Apple ProRAW（若测试素材可得）。

测试结果必须区分：

```text
Compiles
Opens
Preview works
Full-resolution render works
Export works
```

不能仅因为 API 编译成功就声称“支持某 RAW 格式”。

---

# 12. 非破坏 EditRecipe

示意：

```swift
struct EditRecipe {
    var exposure: Double
    var contrast: Double
    var highlights: Double
    var shadows: Double

    var temperature: Double
    var tint: Double

    var saturation: Double
    var vibrance: Double

    var sharpness: Double
    var noiseReduction: Double

    var crop: CropRecipe?
    var rotation: Double

    var lutID: UUID?
    var lutIntensity: Double
}
```

要求：

- 原图不可改变。
- Reset 可恢复。
- Copy / Paste Adjustments。
- 多选 Sync Adjustments。
- Recipe 支持版本迁移。
- Preview 和 Export 使用同一语义 pipeline。
- Preview 可以降分辨率。
- Export 必须 full resolution。

---

# 13. LUT

首版：

```text
.cube
```

支持：

- 单个导入。
- 多选导入。
- 拖放。
- LUT 文件夹导入。
- Favorites。
- Recent。
- Search。
- Category。
- Preview thumbnail。
- LUT Intensity。
- Missing LUT repair。

渲染流程：

```text
Decode
→ Base Adjustment
→ Color Adjustment
→ LUT
→ Final Adjustment
→ Crop / Rotate
→ Output
```

---

# 14. Batch

Mac 版核心能力。

必须支持：

```text
Multi Select

Copy Adjustments
Paste Adjustments
Sync Adjustments

Batch Rating
Batch Flag
Batch Tag

Batch Export
```

批量导出：

```text
Format:
JPEG
HEIF
PNG

Quality
Resize
Long Edge
Short Edge
Original Size

Color Space
Metadata policy
Output Folder
Filename Template
```

后续可增加：

```text
TIFF
Watermark
Sequence Number
Subfolder Template
```

---

# 15. Search

第一层必须永远可用：

```text
Filename
Folder
Date
Camera
Lens
ISO
Aperture
Focal Length
Rating
Flag
RAW
Favorite
Tag
People
OCR
```

自然语言：

```text
2026 年新疆拍的 RAW
索尼 70-200 拍的 5 星照片
ISO 3200 以上的夜景
包含“小王”的截图
```

架构：

```text
User Query
→ SearchQueryInterpreter
→ Structured PhotoSearchQuery
→ Local Catalog
→ Results
```

实现：

```text
FoundationModelsSearchInterpreter
FallbackSearchInterpreter
```

AI 不可用时禁止影响 Catalog Search。

---

# 16. OCR

Vision OCR 用于：

- 截图文字。
- 文件。
- 路牌。
- 菜单。
- 票据。
- 照片文字搜索。

要求：

- 后台任务。
- 可取消。
- 有状态记录。
- OCR 文本默认只保存在本机。
- Release log 不打印完整 OCR 文本。

---

# 17. People

目标：

```text
Face Analysis
→ Entity
→ PhotoAI PersonRecord
```

PersonRecord 不直接依赖单个 analyzer entity：

```swift
PersonRecord {
    id
    displayName
    analyzerEntityIDs
    representativeAssetID
    isHidden
}
```

支持：

```text
People Grid
Rename
Merge
Hide
Representative Photo
Person Detail
Search by Person
```

macOS 27 Media Intelligence API 必须 Phase 0 实测。

---

# 18. Similarity / Cleanup

Cleanup：

```text
Exact Duplicate
Near Duplicate
Similar Photos
Screenshots
RAW + JPEG Pair
Edited Export Duplicate
Large Files
```

禁止自动删除。

删除流程必须：

```text
User selects
→ Review
→ Confirm
→ File operation
```

默认优先：

```text
Move to Trash
```

而不是直接永久删除。

外置盘 / 权限错误必须明确提示。

---

# 19. AI Culling

后续阶段。

目标：

```text
Burst / Similar Group
→ Face Quality
→ Sharpness
→ Eye State
→ Exposure
→ Composition Signal
→ Similarity
→ Recommend
```

输出：

```text
Recommended
Alternatives
Reasons
```

AI 只做推荐：

**绝不自动 Reject / Delete。**

---

# 20. Apple Photos

在本地文件工作流稳定后再加入。

支持：

```text
Apple Photos Source
Albums
Favorites
iCloud assets
```

必须保持：

```text
FileSystem Source
PhotoKit Source
```

为两个独立 Adapter。

Domain 不直接持有：

```text
PHAsset
CIImage
Vision Observation
```

等 heavyweight framework object。

---

# 21. Video Roadmap

视频不进入第一版 MVP。

后续：

```text
Video Library
Thumbnail
Metadata
LUT
Trim
Color
Transcode
Proxy
Highlight Analysis
```

未来可与：

```text
AutoCut
BeatCut
```

结合。

---

# 22. 性能目标

重点是真实日常图库。

目标：

```text
10,000 photos: normal use
50,000 photos: architecture should remain viable
```

不要为了测试而追求不现实的百万级数据规模。

必须关注：

- Grid 滚动。
- thumbnail memory。
- RAW preview memory。
- full-resolution export peak memory。
- DB query。
- Indexing cancellation。
- External drive disconnect。
- iCloud download。
- Analysis concurrency。

---

# 23. Phase 开发计划

## Phase 0 — SDK / Reuse Spike

目标：

验证 macOS 27 技术边界。

任务：

- 建立最小 macOS target。
- Xcode 27 编译。
- 验证 SwiftUI。
- 验证现有 PhotoAIDomain。
- 验证 Core Image RAW。
- 验证 LUT。
- 验证 Vision。
- 验证 Foundation Models availability。
- 验证 Media Intelligence availability。
- 输出 `docs/sdk-spike.md`。

验收：

```text
macOS target builds
existing reusable modules identified
API availability documented
unsupported / beta areas documented
```

---

## Phase 1 — App Shell

实现：

```text
NavigationSplitView / desktop layout
Sidebar
Library placeholder
Inspector
Toolbar
Menu Commands
Settings
Keyboard shortcuts framework
```

验收：

- App 可启动。
- 多窗口行为正常。
- Sidebar / Grid / Inspector 正常布局。
- 无 iOS 风格硬移植问题。

---

## Phase 2 — Catalog + Folder Source

实现：

```text
Add Folder
Security Scoped Bookmark
Directory Scan
PhotoSource
PhotoAsset
Metadata
EXIF
Missing source handling
Rescan
```

验收：

- 可添加本地照片目录。
- 重启后仍能访问。
- 外置盘断开不会崩溃。
- 重连可以恢复。
- 不修改原文件。

---

## Phase 3 — Library

实现：

```text
Thumbnail cache
Grid
Selection
Inspector
Filter
Rating
Pick / Reject
Favorites
Photo Detail
```

验收：

- 真实目录可流畅浏览。
- 快速滚动不读 full-resolution。
- 快捷键可用。
- Rating / Flag 持久化。

---

## Phase 4 — JPEG / HEIF Editor

实现：

```text
Non-destructive EditRecipe
Exposure
Contrast
Highlights
Shadows
WB
Saturation
Crop
Rotate
Reset
```

验收：

- Preview 与导出结果语义一致。
- 重启后 Recipe 存在。
- 原图未改变。

---

## Phase 5 — RAW + LUT

实现：

```text
CIRAWFilter pipeline
RAW preview
Full-resolution export
.cube LUT
LUT manager
LUT intensity
```

这是第一个正式可日用里程碑。

必须使用真实 RAW 素材测试。

验收：

- 至少真实 Sony ARW 工作流有明确结果记录。
- LUT preview / export 正常。
- RAW full-resolution export 无明显生命周期错误。
- cancel / close 不泄漏临时文件。

---

## Phase 6 — Batch Workflow

实现：

```text
Multi-select
Copy adjustments
Paste adjustments
Sync adjustments
Batch export
Export presets
```

验收：

- 50–100 张照片批量操作稳定。
- 失败单项可报告。
- 用户可取消。
- 不因一个文件失败中断整个 batch。

---

## Phase 7 — Search + OCR

实现：

```text
Metadata search
Structured query
Vision OCR
Fallback parser
Foundation Models interpreter
```

验收：

- AI unavailable 时仍可搜索。
- OCR 索引可暂停 / 恢复。
- Search 有明确条件解释。

---

## Phase 8 — People

实现：

```text
Face analysis
People Grid
Person Record
Rename
Merge
Hide
Person Search
```

验收：

- API 可用性真实记录。
- 用户命名不直接绑死单个 analyzer entity。
- People DB 可恢复。

---

## Phase 9 — Cleanup

实现：

```text
Duplicate
Similarity
RAW/JPEG pair
Screenshot
Edited-export relation
```

验收：

- 只推荐，不自动删除。
- Move to Trash 明确确认。
- 外置盘失败有错误状态。

---

## Phase 10 — AI Culling

实现：

```text
Similar grouping
Sharpness signal
Face quality
Recommendation
Reason
```

验收：

- 推荐可解释。
- 不自动删除。
- 不自动永久修改 rating / reject，除非用户主动确认。

---

## Phase 11 — Apple Photos Source

实现：

```text
PhotoKit adapter
Photos Library source
Albums
Favorites
iCloud
```

验收：

- Photos 与 FileSystem Source 互不耦合。
- Limited / iCloud / inaccessible 处理清晰。

---

## Phase 12 — Stability Hardening

重点：

```text
Large catalog
External drive disconnect
App restart
Crash recovery
RAW memory
Export cancel
Index cancel
DB migration
Missing file
Thumbnail corruption
LUT missing
```

输出：

```text
docs/stability-validation.md
```

---

## Phase 13 — Release

要求：

- README 完整。
- LICENSE 明确。
- CHANGELOG。
- GitHub 公共仓库。
- main 保持可构建。
- Release tag。
- unsigned `.app.zip`。
- SHA-256。
- BUILD-INFO。
- 不上传签名证书。
- 不上传 Team ID。
- 不上传 provisioning profile。
- 不上传用户照片。
- 不上传私人路径。

---

# 24. Git 工作流

项目必须建立独立公开仓库：

```text
taoking/photoai-macos
```

默认：

```text
main
```

每 Phase：

```text
agent/phase-0-sdk-spike
agent/phase-1-app-shell
agent/phase-2-catalog
...
```

流程：

```text
Phase branch
→ implementation
→ tests
→ validation notes
→ commit
→ push
→ draft PR
→ user / ChatGPT review
→ fix
→ merge
→ next phase
```

未经本阶段验收，不自动进入下一 Phase。

---

# 25. Commit 规范

推荐：

```text
feat:
fix:
refactor:
test:
docs:
build:
chore:
```

示例：

```text
feat: add folder catalog source
feat: add non-destructive raw editor
fix: cancel full resolution export safely
test: cover missing external volume recovery
docs: record macos 27 sdk validation
```

---

# 26. 测试要求

每个 Phase 都必须有自动测试和人工验收。

自动测试：

```text
swift test
xcodebuild build
xcodebuild test
```

根据 macOS 27 runtime 实际环境调整。

必须重点测试：

- Recipe persistence。
- LUT parser。
- Search parser。
- Catalog migration。
- Missing file state。
- Bookmark recovery。
- Analysis cancellation。
- Thumbnail cache key。
- Batch export failure isolation。
- Temporary file cleanup。

---

# 27. 隐私与仓库安全

禁止提交：

```text
Personal Team ID
Certificate
Provisioning Profile
Signed private builds
Private photos
RAW test images with personal content
Device identifiers
Full home directory paths
API keys
Secrets
```

fixture 使用：

```text
generated fixtures
public-domain images
synthetic metadata
tiny test assets
```

---

# 28. 本机签名与安装

Mac 本机个人使用，不需要把签名配置写入仓库。

Debug / local build 的：

```text
DEVELOPMENT_TEAM
PRODUCT_BUNDLE_IDENTIFIER
CODE_SIGN_IDENTITY
```

通过：

```text
environment
xcconfig ignored by git
command-line override
```

传入。

签名信息不得写进：

```text
project.yml
README real values
GitHub Actions
Release
```

---

# 29. GitHub Release

最终发布：

```text
PhotoAI-Mac-x.y.z-unsigned.app.zip
PhotoAI-Mac-x.y.z-SHA256.txt
BUILD-INFO.txt
```

如以后有 Developer ID，可再增加：

```text
signed
notarized
.dmg
```

但当前阶段不要为了 notarization 阻塞开发。

---

# 30. MVP 完成定义

MVP 推荐定义为 Phase 0–6 完成：

```text
Folder Catalog
External Drive
Photo Grid
Metadata
Rating
Pick / Reject

JPEG / HEIF Edit
RAW Edit
.cube LUT

Non-destructive Recipe
Copy / Paste Adjustments
Batch Export
```

此时必须已经能作为个人照片处理工具真实使用。

People / AI / Cleanup 属于之后增强，而不是阻止 MVP 发布的依赖。

---

# 31. 最终产品方向

```text
PhotoAI Mac
│
├── Library
│   ├── Folder
│   ├── External Drive
│   └── Apple Photos
│
├── Organize
│   ├── Rating
│   ├── Flag
│   ├── Album
│   ├── People
│   └── Tags
│
├── Search
│   ├── Metadata
│   ├── OCR
│   └── AI
│
├── Cleanup
│   ├── Duplicate
│   ├── Similar
│   └── RAW/JPEG Pair
│
├── Editor
│   ├── RAW
│   ├── Color
│   ├── LUT
│   └── Crop
│
├── Batch
│   ├── Sync Adjustments
│   └── Export
│
└── Future Video
    ├── LUT
    ├── Trim
    ├── Highlights
    └── AutoCut / BeatCut
```
