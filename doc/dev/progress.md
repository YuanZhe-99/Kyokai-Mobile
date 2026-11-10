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
- 收起的工具栏箭头可拖动（松手贴边、记住位置）；光标大小可调（设置里带预览和大中小参考）
- 设置：导航栏位置（全部底部 / 宽屏侧边 / 全部侧边，侧边可选左右）；折叠屏展开时设置左右两栏；网络的服务器一行一个输入框（回车加下一个）；关于：版本 0.1.0、Kyokai Core 版本、许可证（AGPLv3）和开源许可证
- 偶发无画面：旧 SurfaceView 销毁时不再夺走新 view 的 surface；4 秒内解码器一帧没收到就改用纹理输出
- SSH 终端、远程桌面、VNC（设备详情页的三个按钮），登录表单与保存的登录信息，主机密钥固定与信任

## 还没有实现

1. **SFTP 文件**：在 SSH 连接上浏览、上传、下载（桌面版 `internal/gui/sshfiles.go`），需要把非界面部分搬进客户端库，再做文件面板和 Android 的文件选择。
2. **NanoKVM USB**：桌面版能经被控端连着的 NanoKVM 操作另一台电脑（`doc/en-us/remote-services.md` 的 NanoKVM USB 一节，`internal/gui/nanokvm.go`），手机端还没有；需要看它走的是哪条通道（隧道还是会话里的 Raw 画面），再决定放进客户端库还是 core。
3. **剪贴板图片和文件**：Kyokai 会话只互通文字。
4. **从首页唤醒睡眠中的设备**（Wake），以及离线设备的唤醒入口。
5. **多会话标签**：平板上同时开两个会话并切换（现在只能从"会话"页回到某个会话）；SSH/RDP/VNC 会话也还没列进"会话"页。
6. **AI 任务历史**：只显示当前任务。
7. **RDP 动态分辨率**（`SetDisplay`）和 H.264（Android 上没有 VideoToolbox，RDP 走 RemoteFX 等编码）。
8. **登录密钥导入**：带口令的密钥、ECDSA 密钥。
9. **M6 收尾**：TalkBack 标签和最小触控尺寸、首帧时间和耗电测量、发布用 CI（GitHub Secrets 签名）、README 和用户文档。
10. **core 改动合回 Kyokai main**：现在在子模块的 `android` 分支上。
11. 本机缺 clang，桌面目标的 `cargo check` 和 `go test`（cgo 部分）跑不了，靠 Kyokai 的 CI。
