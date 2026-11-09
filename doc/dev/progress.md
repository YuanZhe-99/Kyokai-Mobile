# 实现进度

更新于 2026-11-09。

## 当前状态

- 第一版 APK 已构建并签名（kyokai 证书，arm64，约 38 MB）：`bash tool/build_core.sh` 构建 core（约 10 分钟），`bash tool/build_apk.sh` 构建 APK。
- `flutter analyze lib test` 零问题；`flutter test` 17 项全过（键盘、设备 ID、状态解析、视口缩放换算）。
- 语言：英文、简体、繁体（台湾）、日文。
- Kyokai 子模块的 android 分支已提交 core 改动（e9adb9e），包括 `store.start_over` 之后丢失密钥的修复。
- 实机测试清单：`doc/test-checklist.md`。

## 待办

1. 根据实机测试反馈修问题。**无画面**（第 1 版：HEVC、2 fps，状态正常，但画面区域空白）：第 2 版加了解码器日志、"显示视频详情"里的 fed/decoded 计数和换解码器的回退，等实机日志定位。
2. 触摸板手感，参考 libinput 和 macOS / Windows 精确式触摸板的常见做法：
   - **指针加速**：按手指速度算增益的曲线（低速 1:1 方便精确点选，高速放大），速度取最近几次事件的平滑值；小数部分累积，不丢亚像素位移。
   - **轻点**：位移不超过约 8 dp、时长不超过约 180 ms 才算点击，否则算移动；双指轻点右键，三指轻点中键。
   - **轻点后按住拖动**（tap-and-drag），抬手后有短暂宽限可以继续拖。
   - **双指滚动**：按位移换算行数并累积余数，抬手后带惯性（指数衰减），新手指落下时立即停住；横向、纵向各自锁定方向。
   - **防误触**：分体键盘中间的小触摸板忽略边缘起手的触点，双指捏合不触发滚动。
   - 指针速度设置作用于整条曲线；为曲线和点击判定写单元测试。
2. M5：Go 客户端库（SSH/SFTP、RDP、VNC），导出层放在 Kyokai 的 `cmd/kyokai-clients`；本机有 Go 1.27.0（windows/arm64）。设备详情页的 SSH/RDP/VNC 目前只提示"此版本尚未提供"。
3. 本机缺 clang，桌面目标的 `cargo check` 跑不了；Kyokai 的 CI 会检查。
4. file_picker、share_plus 用的是 Kotlin Gradle 插件，Flutter 以后的版本会不再支持，到时需要升级。
