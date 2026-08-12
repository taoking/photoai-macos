# Phase 2 — Catalog + Folder Source 验证

执行日期：2026-08-12  
环境：Xcode 27.0 Beta（27A5228h）、macOS 27.0 SDK、Apple Silicon。

## 实现范围

- 通过 `NSOpenPanel` 添加本地文件夹；只保存 Security-Scoped Bookmark、显示名和最后已知路径，不复制原图。
- 在后台任务中递归枚举 JPEG、HEIF、PNG、TIFF、常见 RAW 与视频扩展名；跳过隐藏文件与 package 内容。
- 读取文件大小、修改日期、像素尺寸和可获得的 EXIF/TIFF 相机元数据；不会解码并缓存全分辨率图片。
- 使用 `~/Library/Application Support/PhotoAI-Mac/catalog.json` 持久化 Catalog；文件不在仓库内。
- 重扫时保留已有的评分、Flag 与收藏字段，为 Phase 3 做准备。
- 书签和最后已知路径均无法定位时明确标记来源为「文件夹缺失」；其他扫描异常标记为「无法访问」。

## 自动化验证

```text
DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test
# Test run with 12 tests in 4 suites passed
```

Catalog 测试覆盖：

- 仅索引受支持的扩展名，且扫描前后 fixture 字节完全一致。
- 文件夹添加、索引及 JSON 持久化可被新建的 `CatalogStore` 恢复。
- 已创建书签的目录被移除后，来源状态变为 `missing`。

## 人工验收与隐私

- 空 Catalog 显示「添加照片文件夹」入口，文件夹入口显示安全书签的本地索引说明。
- 用户在调试实例中主动选择本地测试来源后，应用显示已索引网格与元数据摘要；未执行导出、复制、移动、删除或原图写入。
- 为保护隐私，本记录不包含所选目录、照片文件名、数量、相机信息或任何 OCR 内容。

## 尚未验收的边界

- 未对实际外置盘拔插、卷名变更或文件夹移动做人工测试；当前实现会将无法解析的书签降级为明确的缺失状态。
- Phase 3 才会实现真实缩略图缓存、选择、评分/Pick/Reject 和 Inspector 中的选中照片元数据。

