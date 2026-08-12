# Phase 12.5 验证记录：Catalog Identity & Scale Hardening

## 范围

本阶段只完成 Catalog 身份稳定性与大图库相似性分析的加固。Phase 13（发布准备）保持暂停；不创建 release 或 tag。

## 已实现

- Catalog 重扫时按 `sourceID + relativePath` 识别同一照片，复用原有 `PhotoAsset.id`，并保留评分、标记、收藏、选中状态、编辑配方和 OCR 结果。
- 增加 Catalog → People → Rescan → Restart 回归：重扫后人脸仍可定位到原照片。
- 人物卡片主预览按脸部面积及稳定次序选择；“其余照片”按不同来源照片计数，而非人脸样本数。
- Cleanup 与 Culling 先以拍摄时间窗口、感知哈希签名和受限候选桶生成候选，再做相似度判断；无拍摄时间的项目不会进入全库两两比较，只有完全相同视觉哈希可形成线性链接。
- 真正的 Sony `.ARW` 集成测试只在 `PHOTOAI_RUN_REAL_RAW=1` 且 `PHOTOAI_REAL_RAW_PATH` 指向可读 `.ARW` 时运行；否则会明确显示 `SKIPPED`，不会以替身素材报告通过。
- OCR 恢复会覆盖“刚暂停、取消尚未完成”的竞争窗口，并覆盖延迟暂停后的恢复。
- GitHub Actions 只做源码空白检查与阶段文档存在性检查，明确不声称执行 macOS 27 / Xcode 27 beta 运行时测试或真实 RAW 验证。

## 自动化验证

本机环境：macOS 27 Golden Gate beta、Xcode 27 beta。

| 命令 | 结果 |
| --- | --- |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test --filter 'CatalogTests|PeopleStoreTests|SimilarityCandidatePlannerTests|SearchAndOCRTests|RealRAWWorkflowTests'` | 通过，19 tests / 5 suites；真实 Sony ARW 集成测试明确 `SKIPPED`（未设置测试开关与样本路径）。 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test --filter 'CleanupWorkflowTests|CullingWorkflowTests|SimilarityCandidatePlannerTests'` | 通过，8 tests / 3 suites。 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer swift test` | 通过，53 tests / 15 suites；真实 Sony ARW 集成测试明确 `SKIPPED`。 |
| `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' test` | `TEST SUCCEEDED`，53 tests / 15 suites；真实 Sony ARW 集成测试明确 `SKIPPED`。 |

## Release Gate

| Gate | 状态 |
| --- | --- |
| 重扫后资产身份、人物关联和本地状态稳定 | 已验证 |
| 人物预览次序与关联照片计数 | 已验证 |
| Cleanup / Culling 不进行全库 O(n²) 比较 | 已验证 |
| 无拍摄时间项目不会进入全库比较 | 已验证 |
| 真实 RAW 不会产生虚假 PASS | 已验证（显式 RUN / SKIPPED） |
| OCR 暂停/恢复竞争 | 已验证 |
| GitHub Actions 不夸大本机验证覆盖范围 | 已配置 |
| Phase 13、release、tag | 不在本阶段范围 |

Release Gate 当前为 **NOT READY**：该阶段交付止于 Draft PR；真实 Sony ARW 的运行仍需要在具备可公开测试样本或受控本机样本的环境中显式开启。
