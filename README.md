# PhotoAI Mac

本地优先、非破坏性的 macOS 照片管理与 RAW/LUT 编辑应用。

当前仓库已完成 Phase 0–12.5，并在独立 Draft PR 中实现 Phase 15：提供一个以 macOS 27 为最低系统的原生 SwiftUI 桌面图库，可对用户主动选择的本地文件夹建立非破坏性索引，显示真实低分辨率 RAW/JPEG 缩略图，并提供选择、评分、Pick/Reject、收藏和筛选工作流。编辑器支持非破坏性 `EditRecipe`、JPEG / HEIF / RAW 预览、裁剪、旋转、`.cube` LUT 与强度控制，并可导出全分辨率 JPEG；批处理支持复制/粘贴/同步调整、可取消导出及预设。搜索支持本地结构化条件、可暂停 OCR 和 Foundation Models 不可用时的确定性回退。人物库提供本地 Media Intelligence 分组、每人的本地人脸主预览与其余样本数量、来源照片定位、人物名称搜索、重命名、合并与隐藏；人物名称保存为独立、可恢复的本地记录。清理与智能选片都只生成本地、可解释的建议；移至废纸篓、Pick 标记均需明确确认。Apple Photos 作为独立可选源，只有用户主动操作后才会授权、读取或惰性请求缩略图；浏览不会下载 iCloud 原件。用户可多选项目并把原始资源显式复制到其选择的本地文件夹，成功写入后才进入本地 Catalog。Catalog 具备稳定资产身份、版本迁移、原子写入与最后有效快照恢复；大图库相似性分析通过时间窗口与候选桶限定比较范围。

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

## 品牌资源

PhotoAI Mac 使用深靛蓝底色上的“镜头光圈 × AI 星芒”标志。PNG 母版位于 `Resources/Brand/PhotoAI-Logo.png`，macOS bundle 图标位于 `Resources/PhotoAI-Mac.icns`；SwiftPM 运行时资源位于 `Sources/PhotoAIMac/Resources/PhotoAI-Logo.png`，用于 Dock/应用切换器及侧边栏品牌区。

本机验证结果与未验证项见 [docs/sdk-spike.md](docs/sdk-spike.md)，阶段验收见 [Phase 1](docs/phase-1-validation.md)、[Phase 2](docs/phase-2-validation.md)、[Phase 3](docs/phase-3-validation.md)、[Phase 4](docs/phase-4-validation.md)、[Phase 5](docs/phase-5-validation.md)、[Phase 6](docs/phase-6-validation.md)、[Phase 7](docs/phase-7-validation.md)、[Phase 8](docs/phase-8-validation.md)、[Phase 9](docs/phase-9-validation.md)、[Phase 10](docs/phase-10-validation.md)、[Phase 11](docs/phase-11-validation.md)、[Phase 12](docs/stability-validation.md)、[Phase 12.5](docs/phase-12.5-validation.md) 与 [Phase 15](docs/phase-15-apple-photos-validation.md)。

## 隐私

应用设计遵循本地优先原则。请勿向仓库提交用户照片、RAW 素材、证书、签名配置、API Key 或个人路径。
