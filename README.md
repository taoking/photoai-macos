# PhotoAI Mac

本地优先、非破坏性的 macOS 照片管理与 RAW/LUT 编辑应用。

当前开发分支基于已完成的 Phase 16 照片管理能力实现 Phase 17 专业筛选工作流：提供一个以 macOS 27 为最低系统的原生 SwiftUI 桌面图库，可对用户主动选择的本地文件夹建立非破坏性索引，显示真实低分辨率 RAW/JPEG 缩略图，并提供大图浏览、快速筛选、A/B 同步比较、非 AI 连拍分组、评分、Pick/Reject、统计和索引筛选工作流。编辑器支持非破坏性 `EditRecipe`、JPEG / HEIF / RAW 预览、裁剪、旋转、`.cube` LUT 与强度控制，并可导出全分辨率 JPEG；照片管理导出会直接复制所选原文件、保留 RAW 与扩展名，可导出 Pick、五星或当前结果并保持来源目录结构，提供冲突安全命名、进度和取消。评分与标记支持批量 Command+Z 撤销。搜索支持本地结构化条件、可暂停 OCR 和 Foundation Models 不可用时的确定性回退。人物库提供本地 Media Intelligence 分组、每人的本地人脸主预览与其余样本数量、来源照片定位、人物名称搜索、重命名、合并与隐藏；人物名称保存为独立、可恢复的本地记录。清理与智能选片都只生成本地、可解释的建议；移至废纸篓、Pick 标记均需明确确认。Apple Photos 作为独立可选源，只有用户主动操作后才会授权、读取或惰性请求缩略图；浏览不会下载 iCloud 原件。Catalog 具备稳定资产身份、版本迁移、原子写入与最后有效快照恢复；大图库筛选、筛选会话导航和相似性候选规划都不会在界面切换时重新扫描磁盘。

## 构建与测试

```sh
swift build
swift test
swift run PhotoAIMac
```

若需以本地 `.app` bundle 形式进行 UI 验收，请用脚本重新编译、组装并临时签名当前源码，避免误开旧二进制：

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ./Scripts/build-debug-app.sh
open .build/PhotoAI-Mac.app
```

该调试 bundle 不会写入仓库。

## Release 打包

当前版本为 `0.1.0 (1)`。以下命令会执行 Release 配置构建，组装包含应用图标与 SwiftPM 品牌资源的 `.app`，进行 ad-hoc 签名，并在 `dist/` 生成未公证压缩包、SHA-256 和构建信息：

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  ./Scripts/create-release-artifacts.sh
```

产物不含 Developer ID 签名或 Apple 公证，适合作为本地 Release 候选；通过公网分发前仍需正式签名与公证。脚本不会覆盖已有同名产物，可通过 `PHOTOAI_RELEASE_OUTPUT_DIR` 指定新的输出目录。

## 品牌资源

PhotoAI Mac 使用深靛蓝底色上的“镜头光圈 × AI 星芒”标志。PNG 母版位于 `Resources/Brand/PhotoAI-Logo.png`，macOS bundle 图标位于 `Resources/PhotoAI-Mac.icns`；SwiftPM 运行时资源位于 `Sources/PhotoAIMac/Resources/PhotoAI-Logo.png`，用于 Dock/应用切换器及侧边栏品牌区。

本机验证结果与未验证项见 [docs/sdk-spike.md](docs/sdk-spike.md)，阶段验收见 [Phase 1](docs/phase-1-validation.md)、[Phase 2](docs/phase-2-validation.md)、[Phase 3](docs/phase-3-validation.md)、[Phase 4](docs/phase-4-validation.md)、[Phase 5](docs/phase-5-validation.md)、[Phase 6](docs/phase-6-validation.md)、[Phase 7](docs/phase-7-validation.md)、[Phase 8](docs/phase-8-validation.md)、[Phase 9](docs/phase-9-validation.md)、[Phase 10](docs/phase-10-validation.md)、[Phase 11](docs/phase-11-validation.md)、[Phase 12](docs/stability-validation.md)、[Phase 12.5](docs/phase-12.5-validation.md)、[Phase 15](docs/phase-15-apple-photos-validation.md)、[Phase 16](docs/phase-16-photo-management-validation.md) 与 [Phase 17](docs/phase-17-culling-validation.md)。

## 隐私

应用设计遵循本地优先原则。请勿向仓库提交用户照片、RAW 素材、证书、签名配置、API Key 或个人路径。
