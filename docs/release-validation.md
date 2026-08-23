# PhotoAI Mac 0.1.0 Release 验证

## 发布范围

本次将 Phase 15 Apple Photos、编辑器返回图库空白修复及历史 Logo 恢复合并到 `main`，并生成 `0.1.0 (1)` Release 候选。

打包脚本会将 Release 可执行文件、`Info.plist`、`PhotoAI-Mac.icns` 和 SwiftPM 资源 bundle 组装成 `.app`，使用 ad-hoc 签名校验完整性，并输出压缩包、SHA-256 与 `BUILD-INFO.txt`。

## 验证命令

以下命令已在合并后的 `main` 上执行：

- `swift test`：通过，71 项测试 / 15 个套件；真实 Sony RAW 集成项因未设置显式环境变量而按设计跳过。
- `xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' -quiet test`：通过；仅有 Xcode 27 beta 已知诊断警告。
- `zsh -n Scripts/create-release-artifacts.sh`：通过。
- `Scripts/create-release-artifacts.sh`：Release 构建、应用组装及 ad-hoc 签名通过。
- `unzip -t PhotoAI-Mac-0.1.0-unsigned.app.zip`：通过，压缩数据无错误且不含 AppleDouble / `__MACOSX` 元数据。
- `shasum -a 256 -c PhotoAI-Mac-0.1.0-SHA256.txt`：通过。
- `codesign --verify --deep --strict --verbose=2 PhotoAI-Mac.app`：通过。
- 应用包内 `PhotoAI-Mac.icns`、SwiftPM 资源 bundle 和 `PhotoAI-Logo.png` 均存在，版本为 `0.1.0 (1)`，最低系统为 macOS 27.0。

## 分发限制

当前产物仅有 ad-hoc 签名，没有 Developer ID、Team ID 或 Apple 公证。Gatekeeper 拒绝直接运行该包属于预期行为；公网分发前仍需正式签名与公证。仓库尚未选择开源许可证，因此本轮不创建 Git tag 或 GitHub Release。
