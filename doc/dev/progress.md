# 实现进度

更新于 2026-11-09。

## 当前状态

- 第一版 APK 已构建并签名（kyokai 证书，arm64，约 38 MB）：`bash tool/build_core.sh` 构建 core（约 10 分钟），`bash tool/build_apk.sh` 构建 APK。
- `flutter analyze lib test` 零问题；`flutter test` 17 项全过（键盘、设备 ID、状态解析、视口缩放换算）。
- 语言：英文、简体、繁体（台湾）、日文。
- Kyokai 子模块的 android 分支已提交 core 改动（e9adb9e），包括 `store.start_over` 之后丢失密钥的修复。
- 实机测试清单：`doc/test-checklist.md`。

## 待办

1. 根据实机测试反馈修问题。
2. M5：Go 客户端库（SSH/SFTP、RDP、VNC），导出层放在 Kyokai 的 `cmd/kyokai-clients`；本机有 Go 1.27.0（windows/arm64）。设备详情页的 SSH/RDP/VNC 目前只提示"此版本尚未提供"。
3. 本机缺 clang，桌面目标的 `cargo check` 跑不了；Kyokai 的 CI 会检查。
4. file_picker、share_plus 用的是 Kotlin Gradle 插件，Flutter 以后的版本会不再支持，到时需要升级。
