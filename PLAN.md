# Kyokai-Mobile 迁移计划

把 Kyokai 的控制端搬到 Android 手机、平板和折叠屏上。Flutter 写界面，Kyokai 的 Rust core 原样复用。
本文件只是计划，尚未开始实现。

## 1. 范围

**做（控制端）**

- 设备：首页设备卡片和实时状态、按 Device ID / IP / 域名连接、唤醒（Wake）
- 登录：临时密码、永久密码（OPAQUE）、Ed25519 密钥；信任设备、已保存的密码和密钥
- 网络：最多 8 个 EasyTier 网络的配置、路线探测与选择
- 桌面：视频、声音、指针、键盘（Map）、剪贴板、多显示器、画质/编码/帧率、会话操作（锁定、Ctrl+Alt+Del、屏蔽输入、隐私模式）
- AI 任务：在被控端上发起、回复、批准/拒绝、暂停、停止（任务本身仍在被控端运行）
- 设备自带服务：SSH 终端、SFTP 文件、RDP、VNC
- 身份备份/导入、设置、四种语言（英、简中、繁中、日）

**不做**

- 被控端的一切：`host.serve`、访问设置、本机密码、连接请求、屏幕采集、输入注入、agent sidecar、特权 helper
- 桌面专属：`kyokai` 命令行、local API、撕出窗口、首次引导动画、应用内自更新
- iOS（本期只做 Android）

## 2. 现状

| 部分 | 状态 |
|---|---|
| 设计稿 | 完成：手机 / 折叠屏 / 平板的首页和远程画面，键盘（全尺寸、分体、三页、按被控端系统换布局） |
| `third_party/kyokai`（`android` 分支） | core 为 Android 改过（编解码器在 Android 上留空、剪贴板改由 App 提供、十几处 cfg 补齐），改动未提交；还没有产出过 `.so` |
| `tool/build_core.sh` | 已写，未跑通完整构建 |
| `lib/core.dart` | FFI 绑定草稿；写的 ABI 版本是 8，需要和 core 现在的版本核对 |
| `lib/keyboard.dart` | 设计稿之前写的草稿，要按设计稿重写 |
| `android/…/Video.kt` `Sound.kt` `MasterKey.kt` | 草稿，未在设备上运行过 |
| `lib/main.dart` | 还是 Flutter 模板 |

整个仓库没有任何提交。

## 3. 架构

桌面版是三层：Go 界面 → Go 引擎（`kyokai-svc`，经 local API）→ Rust core。手机上压成一个进程：

```
Flutter (Dart)  界面、状态、键盘、手势
   │ dart:ffi
   ├── libkyokai_core.so   Rust：身份、EasyTier、会话、登录、隧道、AI 任务的转发
   ├── libkyokai_clients.so  Go：RDP、VNC、SSH/SFTP 客户端（见 4.1）
   │ MethodChannel / Texture
   └── Kotlin：MediaCodec 解码到 Flutter Texture、AudioTrack、Keystore、剪贴板、前台服务
```

- 没有引擎进程，也没有 local API：App 直接调 `kyokai_call`，每次调用放在独立 isolate 上。
- 视频不走 core 里的软解：core 把码流经 `kyokai_media_read` 交出来，Kotlin 用 MediaCodec 硬解后直接画到 Texture。
- 密钥库的主密钥放 Android Keystore，状态目录用 App 私有目录。

Dart 侧的分层：

| 目录 | 内容 |
|---|---|
| `lib/core/` | FFI 绑定、包类型、调用封装、错误 |
| `lib/data/` | 设备、网络、会话、凭据的模型和仓库（轮询 `status`、订阅 media 包） |
| `lib/ui/shell/` | 主题、自适应导航（底部药丸 / rail）、分栏判断 |
| `lib/ui/home/` `lib/ui/device/` | 首页、设备详情 |
| `lib/ui/viewer/` | 画面、手势、工具条、小地图、AI 面板 |
| `lib/ui/keyboard/` | 键盘组件和三张映射表（Kyokai 扫描码 / RDP 扫描码 / VNC keysym） |
| `lib/ui/services/` | SSH 终端、文件、RDP、VNC |
| `lib/ui/settings/` | 网络、身份、密钥、外观、语言 |

## 4. 需要先定的事

### 4.1 RDP / VNC / SSH 客户端怎么来（最大的一项）

这三个客户端在桌面版里是 Go 写的，不在 Rust core 里：`internal/rdp` 约 1.3 万行（自带全部编解码），`internal/rfb` 约 7 千行，SSH 用 `x/crypto/ssh` + `pkg/sftp`。

**已定：方案 A。**

- **方案 A（采用）：把 Go 代码编成 Android 的 `.so` 复用。** `rdp` 和 `rfb` 只依赖 `bgra`、`outbox` 两个小包，和界面无关，可以直接编。因为它们在 `internal/` 下，导出层必须放在 Kyokai 仓库里（例如 `cmd/kyokai-clients`），对外用和 core 一样的"调用 + 读包"式 C 接口。代价：APK 多一个 Go 运行时（约 5–8 MB），构建多一条 NDK + cgo 链。
- **方案 B（不采用）：用 Dart 重写。** SSH 有现成的 `dartssh2` + `xterm`，但 RDP 和 VNC 没有可用的 Dart 实现，等于重写两万行协议和编解码，之后还要和桌面版两边一起维护。

### 4.2 core 的 Android 改动放哪

现在在子模块的 `android` 分支上且未提交。建议整理后合进 Kyokai 的 `main`（全部在 `cfg(target_os = "android")` 后面，不影响桌面），子模块指向 `main` 的某个提交，免得长期维护一条分叉。

### 4.3 其他默认值（没有异议就按这个）

- 最低 Android 8.0（API 26）；ABI 只出 `arm64-v8a`（没有模拟器可用，见第 6 节）
- 界面直接依赖 MyApps-UI（如果它能作为 Flutter 包引用）；不能的话把主题和分栏规则抄一份进 `lib/ui/shell/`
- 状态管理用 Flutter 自带的 `ChangeNotifier` / `ValueListenable`，不引入框架
- 许可证跟 Kyokai 一样：AGPL-3.0-only

## 5. 里程碑

每个里程碑结束时交付一个 APK 和一张检查清单，由作者在手机上验证，通过后提交一次。

### M0 地基

- core 在 `arm64-v8a` 上构建出 `.so`，App 加载、核对 ABI 版本、`kyokai_start` 成功
- Keystore 主密钥、状态目录、日志
- core 改动提交并合回 Kyokai（见 4.2）；本仓库首次提交
- CI：构建 core、`flutter analyze`、`flutter test`、出 APK
- 第 6 节的测试配套：正式签名（MySeriesData 的 `kyokai_key.jks`，照 MyAnime 的 `key.properties` 接法）、诊断页、日志导出、构建号

**完成标准：** 真机上 App 启动后显示本机的 Device ID。

### M1 外壳、网络、设备

- 主题（种子色生成明暗两套）、自适应导航、分栏规则
- 网络配置（增删改 EasyTier 网络）
- 首页设备卡片和实时状态；折叠屏/平板的列表 + 详情
- 按 ID / 地址连接；三种登录方式；信任设备、保存的密码

**完成标准：** 加入一个 EasyTier 网络，看到桌面端的设备和状态，用密码登录成功建立会话（还没有画面）。

### M2 桌面画面（最小可用）

- MediaCodec 解 H.264 / HEVC 到 Texture；码率、帧率、延迟、路线的状态显示
- 指针两种模式：触控板（相对移动）和触摸（点哪按哪）；双指滚动、捏合缩放、平移、小地图
- 键盘组件按设计稿重写：三页、修饰键（点一下锁一次 / 双击常驻 / 按住）、Map 扫描码、按被控端系统换布局
- 手机竖屏和横屏两种布局

**完成标准：** 手机上能看到 Windows 和 macOS 被控端的桌面，用屏幕键盘打开应用、输入中文（走被控端输入法）、按出 Ctrl+C / ⌘C。

### M3 桌面画面（完整）

- 声音；剪贴板的文字和图片
- 多显示器切换；画质 / 编码 / 分辨率 / 帧率；会话操作
- 宽屏键盘的全尺寸和分体模式（分体中间的触控板）；折叠屏和平板布局；多会话标签
- 外接键盘和鼠标（蓝牙 / USB）
- 前台服务保活、断线重连、路线切换

**完成标准：** 平板上同时开两个会话；切到后台五分钟再回来会话还在。

### M4 AI 任务

- 任务面板：发起、对话、批准 / 拒绝、暂停、停止、历史
- 手机上是底部抽屉，宽屏是右侧面板

**完成标准：** 从手机发起一个任务，看着它在被控端执行，批准一次、中途停止一次。

### M5 SSH、文件、RDP、VNC

- Go 客户端库 `libkyokai_clients.so`：导出层放在 Kyokai 仓库的 `cmd/kyokai-clients`，加上 NDK + cgo 的构建脚本
- SSH 终端（用 Kyokai 密钥登录，私钥不出 core）、SFTP 文件面板
- RDP、VNC：共用 M2 的画面和手势，键盘换成各自的映射表

**完成标准：** 对同一台设备分别打开 SSH、文件、RDP、VNC 各一次并能操作。

### M6 收尾

- 四种语言；身份备份 / 导入；唤醒；设置补全
- 无障碍（TalkBack 标签、最小触控尺寸）、性能（首帧时间、输入延迟、耗电）
- release CI（签名用 GitHub Secrets）、README 和用户文档


## 6. 测试

开发机是 ARM64 Windows，跑不了 Android 模拟器；唯一的设备是作者日常在用的手机。所以分工是：我出 APK，作者装上测，把结果告诉我。整个流程按"一次往返尽量拿到全部信息"来设计。

**我这边能验证的（每次出包前必须全过）**

- **单元：** 键盘映射表（每个键 × 三种被控端系统 × 三种协议）、修饰键状态机、手势到指针事件的换算、包解析
- **Widget / golden：** 390×844、904×1000、1280×800 三档下的首页、画面、键盘（全尺寸和分体）。折叠屏和平板布局只能靠这一层，没有真机
- **core 在本机跑：** 控制端的调用顺序（加网、列设备、登录、开会话、收视频包）先用 Dart 测试对着 Windows 版 core 跑通，再上手机。这样手机上出问题时，能排除掉"调用本身写错了"
- **构建：** `arm64-v8a` 的 release APK 能出包，`.so` 都在包里且能被加载（用 `aapt` / `readelf` 检查）

**作者在手机上验证的**

- 每个里程碑交付一个 APK，附一张检查清单：做什么、应该看到什么，逐条打勾
- 被控端用这台开发机（Kyokai 的 Windows ARM64 版），另外有 macOS / Linux 被控端时再各走一遍

**为这种分工专门做的东西（放进 M0）**

- **签名：** 从第一个包起就用正式签名 `kyokai_key.jks`（在 MySeriesData 仓库里，别名 `kyokai`，RSA 4096；密码和供 CI 用的 base64 在同目录的 `KyokaiKeystore.txt`），包名用正式的。新包直接覆盖安装，不用卸载、不丢配置，将来升到正式版也一样。接法照 MyAnime：本地放一个不入库的 `android/key.properties` 指向 MySeriesData 里的文件，CI 用 GitHub Secrets（keystore 的 base64、密码、别名）；密钥和密码都不进本仓库
- **诊断页：** 设置里一页，显示版本和构建号、core 的 ABI 版本、`.so` 加载结果、MediaCodec 支持的解码器、网络和路线状态
- **一键导出日志：** 把 App 和 core 的日志（不含密钥和密码）打包，通过系统分享发出来；崩溃时下次启动提示导出
- **画面内状态条：** 可开关的调试层，显示解码器、分辨率、帧率、丢帧、输入延迟，截一张图就够我判断
- **构建号写在首页角落：** 避免测的不是最新的包

## 7. 风险

| 风险 | 应对 |
|---|---|
| libvpx / libaom 在 Android 上没编过去，目前是留空 | VP9 / AV1 只在设备 MediaCodec 支持时启用，否则协商回 H.264 / HEVC |
| MediaCodec 基本不支持 4:4:4 | 手机端固定请求 4:2:0；被控端的协商逻辑要确认能降级 |
| core 从未在 Android 上跑过，EasyTier 无 TUN 模式在 Android 上的表现未知 | M0 / M1 最先验证这一条，不通就先停下来处理 |
| 只有一台在用的手机，没有折叠屏和平板，也没有模拟器 | 宽屏布局靠 golden 测试；手机横屏和系统分屏粗看；找到设备前，折叠屏和平板标为"未在真机验证" |
| 系统杀后台导致会话断开 | 会话期间挂前台服务和常驻通知 |
| 三套运行时（Dart、Rust、Go）让 APK 变大、构建变复杂 | 按 ABI 分包；Go 库只在 M5 引入 |
| 剪贴板传文件在 Android 上受存储权限限制 | 本期只做文字和图片，文件走 SFTP 面板 |
| 16 KB 页大小的新设备 | 两个 `.so` 都按 16 KB 对齐链接 |
