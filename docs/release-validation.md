# PhotoAI Mac 0.1.0 Release 验证

## 发布范围

本次将 Phase 15 Apple Photos、编辑器返回图库空白修复及历史 Logo 恢复合并到 `main`，并生成 `0.1.0 (1)` Release 候选。

打包脚本会将 Release 可执行文件、`Info.plist`、`PhotoAI-Mac.icns` 和 SwiftPM 资源 bundle 组装成 `.app`，使用 ad-hoc 签名校验完整性，并输出压缩包、SHA-256 与 `BUILD-INFO.txt`。

## 验证命令

合并后记录以下命令的实际结果：

- `swift test`
- `xcodebuild -scheme PhotoAIMac -destination 'platform=macOS,arch=arm64' -quiet test`
- `zsh -n Scripts/create-release-artifacts.sh`
- `Scripts/create-release-artifacts.sh`
- `unzip -t PhotoAI-Mac-0.1.0-unsigned.app.zip`
- `shasum -a 256 -c PhotoAI-Mac-0.1.0-SHA256.txt`
- `codesign --verify --deep --strict --verbose=2 PhotoAI-Mac.app`

## 分发限制

当前产物仅有 ad-hoc 签名，没有 Developer ID、Team ID 或 Apple 公证。Gatekeeper 拒绝直接运行该包属于预期行为；公网分发前仍需正式签名与公证。仓库尚未选择开源许可证，因此本轮不创建 Git tag 或 GitHub Release。
