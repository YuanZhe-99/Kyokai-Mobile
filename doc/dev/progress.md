# 实现进度

更新于 2026-11-10（0.1.3）。

## 构建

- `bash tool/build_core.sh`：Rust core（约 4–10 分钟）
- `bash tool/build_clients.sh`：Go 客户端库 `libkyokai_clients.so`（SSH、SFTP、RDP、VNC、密钥导入，Kyokai 的 `cmd/kyokai-clients`）
- `bash tool/build_apk.sh`：签名的 arm64 APK（约 46 MB）
- 协议参考：`doc/dev/api-control.md`、`api-media.md`、`api-services.md`
- 使用说明：`doc/user-guide.md`、`doc/user-guide.zh.md`
- 实机测试清单：`doc/test-checklist.md`
- CI（`.github/workflows/ci.yml`）：检查、测试、从子模块构建 core、客户端库和 APK；`v*` 标签发布 Release。0.1.0、0.1.1、0.1.2 已发布；0.1.3 已提交，未打标签

## Kyokai 子模块

Android 的改动（core 的 Android 构建、`android.*` 调用、`cache_dir`、剪贴板历史的 `paths`；客户端库 `cmd/kyokai-clients`；MediaCodec 的 H.264）已合进 Kyokai main（d9dae02），`android` 分支与 main 相同。

## 已在实机验证

启动、网络、设备列表、连接与登录、Kyokai 桌面画面（第 4 版修好画面高度后）、键盘输入、触摸板（屏幕触控板模式和键盘触摸板）、折叠屏笔记本模式、SSH 终端、远程桌面、VNC（含登录表单与保存的登录信息、主机密钥固定与信任）。

## 已实现、待实机验证

实机测试的步骤见 `doc/test-checklist.md`。

- 画面贴顶
- 收起的工具栏箭头可拖动（松手贴边、记住位置）；光标大小可调（设置里带预览和大中小参考）
- 设置：导航栏位置；折叠屏展开时设置左右两栏；网络的服务器一行一个输入框；关于：版本、Kyokai Core 版本、许可证
- 偶发无画面：旧 SurfaceView 销毁时不再夺走新 view 的 surface；4 秒内解码器一帧没收到就改用纹理输出
- 0.1.1：
  - Activity 重建（进程和 core 还在）时不再报"the core is already started"：接管正在运行的 core，关掉旧界面留下的会话
  - SFTP 文件（SSH 的"文件"）：浏览、上传、下载、重命名、删除、新建文件夹，传输进度和取消
  - NanoKVM USB：设备详情的 NanoKVM 按钮（主机有 NanoKVM 时），`session.connect nanokvm`；MJPEG 画面用 BitmapFactory 画到 surface
  - 剪贴板：图片双向（core 的 `android.clipboard` 新增 `png`；主机的图片经 `ClipProvider` 放进手机剪贴板）；剪贴板历史（会话页和桌面菜单）；文件在 0.1.3 才接收
  - 唤醒：设备详情和设备列表的唤醒按钮（主机有 `wake` 特性时）、画面休眠时的唤醒按钮；没有打开的桌面时开一个只有 `control-input` 的短会话发 `wake`
  - 多会话：桌面菜单里切换到另一个打开的画面；会话页列出桌面、AI、NanoKVM、SSH、远程桌面、VNC
  - AI 任务历史：连接期间主机显示过的任务按 id 保存，AI 面板的历史按钮（0.1.3 起跨重启保存）
  - 远程桌面动态分辨率：画面区域变化时 `display`（RDP `SetDisplay`）
  - 密钥导入：带口令的密钥、ECDSA P-256/P-384（经客户端库的 `key.import`，Go 的 x/crypto/ssh）
  - M6：TalkBack 标签（图标按钮的提示、远程画面、缩放标签的 48 dp 目标）；首帧耗时（诊断页和视频详情）；README 和使用说明

- 0.1.2：
  - NanoKVM 不再被"此设备无权查看主机屏幕"挡住（NanoKVM 的画面来自采集卡，不看主机的 `view-screen`）
  - 键盘的系统布局可手动选（键盘左上角的标签：自动、Windows、macOS、Linux），按设备和连接方式（Kyokai、NanoKVM、RDP、VNC）分别记住；NanoKVM 自动时按 Windows
  - 按 Shift 时数字和符号键显示 Shift 后的字符；macOS 下单独开 Option 时显示 US 布局的 Option 层（Option+Shift 另一组）

- 0.1.3：
  - AI 任务历史跨重启保存（应用偏好里，每台主机最新 100 个，不含步骤），历史里可清除
  - 剪贴板文件：桌面会话请求 `files` 权限；core 在 Android 上把收件夹放在应用缓存（`kyokai_start` 的 `cache_dir`），收完后查看器历史带 `paths`；应用把文件移到缓存的 `received`（本次运行内保留，下次启动清掉），剪贴板历史里可保存或分享
  - 远程桌面的 H.264（AVC420/444）：客户端库的 `rdp/codec/h264` 在 Android 上用 NDK 的 AMediaCodec 解码到 AImageReader，YUV_420_888 拷成 NV12；设备没有 H.264 解码器时不声明 AVC

## 还没有实现

1. **耗电测量**：需要实机跑一段时间看电池统计；首帧耗时已有数字。
2. 本机缺 clang，桌面目标的 `cargo check` 和 cgo 部分的 `go test` 跑不了，靠 Kyokai 的 CI（客户端库的纯 Go 部分用 `CGO_ENABLED=0 go test` 可以跑）。
3. 从手机发文件到主机（Android 剪贴板里是 content URI，不是路径）。
