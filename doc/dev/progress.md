# 实现进度

更新于 2026-11-09。

## 构建

- `bash tool/build_core.sh`：Rust core（约 10 分钟）
- `bash tool/build_clients.sh`：Go 客户端库 `libkyokai_clients.so`（SSH、RDP、VNC，Kyokai 的 `cmd/kyokai-clients`）
- `bash tool/build_apk.sh`：签名的 arm64 APK（约 46 MB）
- 协议参考：`doc/dev/api-control.md`、`api-media.md`、`api-services.md`

## 已在实机验证

启动、网络、设备列表、连接与登录、Kyokai 桌面画面（第 4 版修好画面高度后）、键盘输入。

## 已实现、待实机验证

- 触摸板（屏幕触控板模式和键盘触摸板共用 `lib/ui/viewer/touchpad.dart`）、折叠屏笔记本模式、画面贴顶
- SSH 终端、远程桌面、VNC（设备详情页的三个按钮），登录表单与保存的登录信息，主机密钥固定与信任

## 还没有实现

. **NanoKVM USB**：桌面版能经被控端连着的 NanoKVM 操作另一台电脑（`doc/en-us/remote-services.md` 的 NanoKVM USB 一节，`internal/gui/nanokvm.go`），手机端还没有；需要看它走的是哪条通道（隧道还是会话里的 Raw 画面），再决定放进客户端库还是 core。
1. **剪贴板图片和文件**：Kyokai 会话只互通文字。
2. **从首页唤醒睡眠中的设备**（Wake），以及离线设备的唤醒入口。
3. **多会话标签**：平板上同时开两个会话并切换（现在只能从"会话"页回到某个会话）；SSH/RDP/VNC 会话也还没列进"会话"页。
4. **AI 任务历史**：只显示当前任务。
5. **RDP 动态分辨率**（`SetDisplay`）和 H.264（Android 上没有 VideoToolbox，RDP 走 RemoteFX 等编码）。
6. **登录密钥导入**：带口令的密钥、ECDSA 密钥。
7. **M6 收尾**：TalkBack 标签和最小触控尺寸、首帧时间和耗电测量、发布用 CI（GitHub Secrets 签名）、README 和用户文档。
8. **core 改动合回 Kyokai main**：现在在子模块的 `android` 分支上。
9. 本机缺 clang，桌面目标的 `cargo check` 和 `go test`（cgo 部分）跑不了，靠 Kyokai 的 CI。
