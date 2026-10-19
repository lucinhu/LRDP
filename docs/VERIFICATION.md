# 验收记录

记录日期：2026-10-20。当前为开发预览。构建、真实协议和平台设备验收分别记录；
尚未进行与 aRDP Free 的同设备性能对比。

## 本机文字粘贴、桌面触控板与连接偏好

新增“更多 → 粘贴本机文字”，使用现有带确认的 CLIPRDR 文字发送和 Ctrl+V 流程。
明确操作优先读取本机文字，避免被待处理的远程文字替换；同步与发送期间避免重入。
没有文字或读取失败会提示，单次上限保持 16384 个 UTF-16 单元。
图片和文件剪贴板尚未接入，文件继续使用 RDPDR 中转站，见 [CLIPBOARD.md](CLIPBOARD.md)。

桌面接入 Flutter `PointerPanZoom` 手势流，支持双指竖向/横向滚动、慢速位移累计和
捏合缩放；“移动画面”模式平移本地视野。取消、后台、失去焦点或会话失活后结束手势，
普通鼠标滚轮和手机触摸流程保留。连接偏好展开区域增加顶部与侧边留白，避免浮动标签被裁。

- 149 项 Flutter 单元/布局检查通过，普通运行跳过 9 项需外部服务的协议检查；
  静态分析、3 项原生 CTest、9 项 Python 检查及隔离 RDP 基础连接检查通过。
- 三种语言的手机/桌面表单均在 200% 字号下检查标签真实绘制边界；旧布局复现
  分辨率标签顶部超出裁切区域约 11.5 像素，修复后边界完整。
- 合成桌面触控板与鼠标滚轮事件经过生产 worker、FFI 和真实 TLS 连接，由独立
  服务端核对 10 条横纵滚轮 PDU 的方向及次数；捏合和失活后没有额外滚轮或点击。
  这是输入链路验证，实体触控板与操作系统驱动仍待验收。
- 新粘贴按钮通过真实 CLIPRDR：服务端检查一份文字格式发布、一次完整中文 UTF-16
  数据和四个 Ctrl/V 扫描码事件。测试合成本机文字剪贴板返回值，未操作个人剪贴板。
- 当前 Linux 主入口 Release 在私有 Xvnc + Openbox 中通过 6 项实际窗口检查，
  覆盖拖动/松开、后续左/右/中键、原地多键释放、Escape 后点击及系统全屏恢复。
  文字协议套件的 5 项场景通过，包含直接中文 Unicode、服务端不支持 Unicode、
  输入栏粘贴、新本机粘贴按钮和取消发送。

本轮记录位于 `build/clipboard-trackpad/`，协议报告为 `build/trackpad-runtime/VERDICT.json`
与 `build/paste-runtime/flutter/VERDICT.json`，分发目录为 `build/distributions/clipboard-trackpad/`。
以其中 `BUILD_INFO.json` 对照实际源码与二进制。以下章节保留各自批次的历史记录，
不将此前 Android 模拟器结果当作本次 APK 的设备验收。当前 ARM64 真机、Windows
完整应用、macOS 和 iOS 仍待验收。

## 全屏、悬浮工具与界面语言（2026-10-19 批次）

连接默认进入全屏，在设置中可关闭“进入会话时全屏”。手机隐藏系统栏，桌面使用
对应窗口系统的全屏接口；退出全屏或返回电脑列表后恢复。Android 收起输入法后
按系统要求等待至少 1 秒再恢复沉浸显示，不会为了全屏而收起正在使用的输入法。

会话操作集中在可拖动、可收起的悬浮面板，保留键盘、输入模式、平移、适应画面、
全屏和更多操作；文件、剪贴板、组合键与断开位于更多菜单。面板位置和收起状态
随会话保留，旋转和窗口变化时限制在安全区域内。收起后为 56 像素按钮。
输入栏展开时暂时收起面板，关闭输入栏后恢复；画面仍可操作。返回列表保持连接，
按原有策略暂停，返回会话继续。Ctrl + Alt + Home 释放远程键盘并展开本地工具。

默认跟随系统语言，可选择简体中文、繁体中文和英语。三份完整消息目录与占位符
一致性检查通过，切换语言保留正在编辑的表单。消息数据同步离线加载；用户填写的
连接名称、路径和输入文字不进行翻译，原生技术诊断保持原文。见 `docs/LOCALIZATION.md`。

- 静态分析、136 个 Flutter 用例（普通运行跳过 8 个外部协议用例，协议检查另行记录）、3 个原生 CTest、
  9 个 Python 检查通过。悬浮面板覆盖拖动、收起、展开、旋转、大字体和画面点击；
  全屏平台请求覆盖迟到的进入/退出顺序及平台拒绝后的恢复。
- 当前 Linux 主入口 Release 在独立 Xvnc + Openbox 中通过 6 项实际检查：
  进入会话从原窗口变为 1440×1000 系统全屏，悬浮返回操作恢复原窗口尺寸；
  远端窗口拖动/松开、后续左/右/中键、多键释放及 Escape 后点击均通过。
  同一安装库还通过阻塞输入停止检查及 TLS/DISP 的分辨率变化检查。
- Android 主入口 ARM64 与 x86_64 Release 预览 APK 完成单 ABI、主入口、签名及
  16 KiB ELF/RELRO/ZIP 对齐检查。本轮设备检查使用独占的 API36 / x86_64 / 16 KiB 模拟器；
  具体运行结果记录在 `build/android-fullscreen-l10n-runtime/VERDICT.json`。
  实际通过 18 项流程，包含三种语言切换、全屏画面范围、悬浮工具拖动/收起/旋转、
  原 TCP 会话复用、NLA/Keystore 重启、真实触控、输入法保持、组合键及中文 Unicode/粘贴。
  [手机悬浮工具](screenshots/android-fullscreen-tools.png)、
  [横屏收起状态](screenshots/android-fullscreen-collapsed-landscape.png)及
  [Linux 全屏](screenshots/linux-fullscreen-tools.png)均为当前发布版的原始系统截图。
- Windows 新窗口全屏处理通过 clang-cl / Windows SDK 的插件 DLL 交叉编译；
  当前完整 Windows 应用、原生 MSVC、macOS/iOS 和 ARM64 手机真机仍待验收。

本轮报告前缀为 `build/fullscreen-l10n-`，最新分发目录为
`build/distributions/fullscreen-l10n/`，用其中 `BUILD_INFO.json` 对照源码、AOT、原生库和 APK。

## 自动分辨率与地址输入

新建连接默认“自动（适应画面区域）”，取远程画面实际可用的逻辑像素尺寸，
扣除工具栏和安全区域。首次握手使用此尺寸；后续窗口变化通过 DISP 通道调整，
连续变化等待 400 ms 后只发送最终尺寸。宽度按协议取偶数，尺寸限定 200–4096。
高密度手机使用逻辑像素，避免远程控件因使用整屏物理像素而过小。
输入法或手机输入栏展开时保持原分辨率，可继续触控；收起后恢复自动适配。
后台暂停调整，返回会话再提交最新尺寸。服务器未开放 DISP 时只能使用首次连接尺寸。
旧配置中明确保存的固定分辨率继续保留，可在“连接偏好 → 远程分辨率”切换为自动；
RDP 文件的 `dynamic resolution` 属性支持导入/导出，只有固定宽高的旧文件保留固定模式。

快速连接和编辑表单均显示“电脑地址与端口”，提供带端口示例和默认 3389 的说明，
可填写主机名、IP、`主机:端口` 或 `[IPv6]:端口`，手机使用 URL 键盘。

复现自动分辨率的真实协议检查：先按构建文档生成 `build/native/liblrdp.so`，
再运行 `python3 scripts/run_resolution_test.py`。该测试使用独立临时证书、回环 TLS 服务端、
生产 worker 和实际 DISP 通道，核对首次握手、合并调整、后台延后及重激活后的解码尺寸；
不连接用户远端，不使用个人桌面。报告为 `build/resolution-runtime/VERDICT.json`。
本轮真实回环检查通过：首次 802×602，后续 1000×700、720×960，服务端逐项核对实际
握手和两条 MonitorLayout PDU，客户端确认重激活后的画面尺寸且未新建连接。
此项变更初次检查另通过静态分析、131 个 Flutter 用例（普通运行跳过 8 个外部协议用例）、3 个原生 CTest
及原有隔离回环协议检查；报告位于 `build/auto-resolution-*.log`。
手机输入栏/旋转与大字体为 Flutter 布局回归；本次新增行为的 Android/ARM64、Windows、
macOS 与 iOS 真机验收仍待进行。前一轮主题、输入和手势设备报告保留各自构建摘要。

## 系统配色与高帧率

本轮最终源码通过静态分析、128 个 Flutter 单元/布局测试（普通运行跳过 7 个外部协议
用例）、3 个原生 CTest 和 9 个 Python 检查。新增回归覆盖旧明暗设置迁移、系统亮度变化
保留编辑中的连接、手动明暗覆盖、前台重读主题色、设置持久化，以及刷新率变化时原会话
原地调整帧率和释放系统刷新率偏好。

- Android API 36 / x86_64 / 16 KiB 的实际主入口 Release APK 通过 17 项流程。
  系统主色与 `system_accent1_600` 资源逐像素对应，自动明暗、手动浅色、返回自动、
  120 帧设置的进程重启保留均通过。既有 NLA/Keystore、原生画面、触控、IME 保持、
  组合键和中文 Unicode/粘贴回归也通过；[浅色](screenshots/android-system-theme-light.png)
  与[深色](screenshots/android-system-theme-dark.png)为本轮未修改的主 Release 实际截图。
- 独立 TLS 服务端以 240 帧/秒目标发送带序号的 320×240 画面。生产 worker 与 Flutter
  CPU 回退实际交付约 29.98 / 120.50 / 213.29 帧/秒，对应 30 / 120 / 240 的设置；
  还核对了画面像素序号、后台停止交付和返回继续。单帧背压保持，过期帧不排队追赶。
  这组数据覆盖小画面回环解码/交付吞吐量；实体高刷屏、高分辨率、耗电与端到端延迟待验收。
- Linux GTK 原生纹理与强制 GPU 故障回退分别通过真实 RDP 像素、XOR、缩放、暂停恢复、
  重建视图及三次重连/资源释放检查。当前 Linux 主入口 Release 还通过窗口图标/绘制、
  实际远端窗口拖拽和后续点击，以及正常/阻塞写入时的输入释放与取消检查。
- Windows 的新帧率调度插件、固定版本的配色插件及构建目录中的 API 兼容副本通过
  Linux 上 clang-cl / x64 Windows SDK 交叉编译。当前完整 Windows 主应用、原生 MSVC、
  macOS、iOS 和 ARM64 手机真机仍待验收。

Android 模拟器仅提供 60 Hz 屏幕，本轮没有把“可以选择 120/240”当作实体屏幕高刷实测。
实际帧率还取决于服务端更新和系统刷新率策略。FreeRDP 子模块仍无修改，C ABI 保持 v5。
本轮报告位于 `build/android-theme-refresh-runtime/VERDICT.json`、
`build/frame-rate-runtime/VERDICT.json` 与 `build/linux-mouse-runtime/VERDICT.json`；
分发时用 `build/distributions/theme-refresh/BUILD_INFO.json` 对照 APK、AOT、原生库和源码摘要。

## 已验证范围

| 项目 | 结果与范围 |
| --- | --- |
| 上游源码 | FreeRDP 3.32.2，提交 `97eff6ddfbbfaa8e42a126d362686bd001ff8bdc`，子模块源码无修改；适配均在 LRDP 仓库 |
| ABI 与线程 | ABI v5、24 个 C 导出（新增原生帧接口保持旧签名兼容）；每个会话一个 worker isolate，FreeRDP 连接线程串行处理原生操作；帧与光标独立背压 |
| Flutter 全量检查 | 静态分析无问题，128 项单元/布局用例通过；7 个外部协议用例在普通测试中跳过，基础会话/粘贴/认证/恢复/光标/键盘/高帧率另由实际回环服务运行 |
| Linux 发布版 | 当前 lib/main.dart 的 Release AOT、原生纹理插件与安装库 ABI v5 / 24 导出；私有显示实际窗口启动、128×128 图标逐像素一致；系统鼠标拖动、释放与后续点击通过。声音、AVC 图像、光标及 Flutter 粘贴的历史发布库证据保留各自原哈希 |
| Android 完整运行基线 | 前一构建（源码指纹 `36ece57b…`）的 API 36、x86_64、PAGE_SIZE=16384：四个用例、24 个阶段通过，包括 Keystore、文件、中文粘贴、AVC、光标、真实 IME/触控/旋转/DocumentUI/SharePlus、后台断网及换证书；声音与系统手势使用下方专项报告，不将前次基线当成新增行为的验收 |
| Android ARM64 包 | lib/main.dart 非调试 Release AOT 预览 APK；显式开发证书签名；ABI v5、ELF/RELRO/ZIP 的 16 KiB 对齐、签名、单 ABI 和主应用入口检查通过；未实测 ARM64 设备 |
| 对应源码包 | 应用源码、FreeRDP 快照、精确 FFmpeg 源码和配置已打包；排除 build/运行/Git 元数据，解压到独立目录后原生 CMake 配置通过 |
| 生命周期与内存 | CTest 创建/销毁、输入边界、重复启动与连接中取消；ASan/LSan/UBSan 生命周期、真实光标及粘贴六种场景通过。内存检查使用系统 FreeRDP 3.32.2，未对上游完整插桩 |
| 拖拽中断开 | 修复先中断传输导致 Ctrl/鼠标卡住的问题；私有 TLS 服务实际核对六种扫描码、三种 Unicode 单元和三个鼠标键的唯一释放及顺序，已释放按键不重复释放；Linux、ASan 和 Windows PE/Wine 正常及实际 TCP 堵塞取消通过，500 ms 宽限后停止写入；断网时不保证远端收到释放 |
| TLS 与 NLA | 回环服务证书未信任/错误指纹拒绝、精确 SHA-256 接受；一次性 SAM 身份验证错误密码拒绝、正确密码通过 CredSSP。实际用户账号未做错误密码试探 |
| 图像与 H.264 | 实际 RDP BGRA 初始/变化像素；最小静态 FFmpeg 9.0.2 解码实际 AVC420，并要求观察到该编解码协议，拒绝仅回退图像的假通过。AVC RGB 容差 4，其他模式 2，alpha 精确匹配；软件解码，非硬件加速 |
| 输入与文件 | 私有 X11 服务端实际按键/鼠标按下释放；RDPDR 1 MiB 双向逐字节一致、中文目录和文件名、Unicode 按键及目录越界拒绝 |
| 中文粘贴 | 服务端确认 FormatList 后由连接线程发送 Ctrl+V；精确中文 UTF-16 数据传输、提前数据请求、拒绝、无确认、无数据、取消六种真实 CLIPRDR 场景通过。超时后不自动重发，避免重复粘贴 |
| Flutter 粘贴 | 真实 worker 与手机输入栏：等待时禁止重复发送、收到确认才清空原文字；保留新输入及失败文字；重新连接/关闭/迟到结果不影响新会话 |
| 认证修复 | 中文认证/账号策略原因、折叠原始诊断；临时修改账号/域/密码后重新登录；私有 NLA 手机工作区实际收到画面；同地址沿用临时指纹，凭据不自动持久化 |
| 自动重连 | 真实 TCP EOF 后重新认证并获得新帧；五次退避、取消无新握手、证书变化停止重试；真实 ErrorInfo(LOGOFF_BY_USER) 分类 remote，不重试 |
| 会话更新 | 连接偏好/密码变更替换会话，展示元数据复用连接；后台暂停倒计时/帧传递，返回继续；证书确认按前台状态排队 |
| 光标 | 实际 TLS 指针 PDU、预乘 BGRA、AND/XOR、缓存、隐藏/默认、服务器位置、384×384；原生、Flutter、ASan、Windows PE/Wine 回归通过 |
| 手机界面 | 底部操作栏、触控板/直接触控、捏合、滚动、拖拽、右键、48px 操作目标；本地中文候选词提交、横屏键盘避让、连接表单/证书/认证弹窗的大字体布局回归 |
| Windows 核心 | MinGW x64 PE DLL、FreeRDP/OpenSSL/FFmpeg 静态链接，无额外 GCC/Winpthread/FFmpeg DLL；Wine 11.20 实际 TLS、WinPR SSPI/NLA、AVC 解码及像素、键鼠、1 MiB 文件、Unicode、光标与粘贴六种场景通过 |
| 桌面界面 | 删除宣传标语、宣传卡片、重复隐私徽章和无功能头像；默认连接列表、明确连接按钮；收藏/最近/搜索空状态及恢复列表操作；私有 GTK 窗口实际验证明暗主题、编辑、搜索与文件面板 |
| 应用图标 | 自有 SVG 生成 Android/iOS/macOS/Windows/Linux 资源；Android API 36 私有模拟器实际安装主应用并确认启动器新图标；Linux Release 窗口的 128×128 图标逐像素核对；Windows ICO 九种尺寸及 MinGW 资源编译通过，Apple 目录尺寸与 iOS 不透明 RGB 检查通过；Windows/Apple 实际显示仍待对应系统验收 |
| 视野与手势 | 放大后触控板光标边缘跟随、普通鼠标边缘持续平移、真实画面边界限制与旋转后约束；双击按住拖拽、双指轻点右键、竖向/横向滚动、捏合；触控/手机回归覆盖取消、后台、失焦与非活动会话；真实隔离 RDP 服务收到右键、双向竖向/横向滚轮、带左键的移动及准确位置释放；Android API 36 / x86_64 / 16 KiB 模拟器已由系统输入验证，ARM64 手机与 Apple 设备仍待验收 |
| 会话视图保留 | 手机返回列表、键盘收起与桌面标签切换分别保留缩放、光标和操作模式；布局/远程分辨率变化、旧位置序号、新连接及关闭重置的回归通过。静止鼠标被动进入和 Android 触摸悬停不改变触控板光标；Android 系统点击的实际远端坐标与离开前一致，模式与视野恢复且 TCP 连接未重建 |
| Android 系统手势 | 实际 Workspace/worker/FreeRDP：22 场景、47 阶段、1000 余个设备指针事件通过；新增触控板连续点按、触屏坐标点按与拖拽后点按，每组核对三次完整点击；系统多指触摸及临时内核虚拟鼠标，独立 X11 服务记录真实点击/滚轮/拖拽/释放；包含取消、后台、旋转、返回列表、视野/光标/模式恢复及鼠标边缘平移停止；原 TCP 端点/inode 保持，关闭后 TCP 释放；应用权限未改，root 仅供专用调试 AVD 的测试鼠标，设备已销毁；真机待验收 |
| Android 声音生命周期 | 前次 ABI v5 库：API 36 / x86_64 / 16 KiB 私有模拟器，实际 WorkspaceScreen、worker、Keystore 与 AudioManager；PCM16/PCM8 两轮共 29 阶段、36 次 LRDP 自身音轨观察通过；音轨持续消费 PCM 且观察窗口无新增欠载，后台/返回列表/临时与 duck 焦点请求后设备释放，回到原会话及焦点归还后恢复；宿主禁用声音输出，不等同于物理扬声器听测或 ARM64 真机 |
| 远程声音 | Linux PulseAudio、ASan 适配层、Windows PE/WinMM 经 Wine Pulse 驱动实际录回；48 kHz 双声道 500/1000 Hz、超过 45000 个有效帧、至少 90 个 10 ms 音调窗口及幅度/串音核对；启用、同时开启 RDPDR、关闭、不支持格式、PCM8、静态暂停/恢复、动态 RDPSND 暂停/恢复七种情况通过；暂停至少 2.5 秒静音、暂停段标记音不出现，恢复后收到新段声音，关闭后无残留设备，桌面连接仍可用 |

Linux 当前使用 Arch x86_64、Flutter 3.50.0-0.1.pre（`340ba4fd42`）、
Dart 3.12.0-201.0.dev、CMake 4.4.4、Clang 23 / GCC 16、OpenSSL 3.6.5。
FFmpeg 9.0.2 官方源码包固定摘要，关闭 GPL/version3/nonfree/网络/程序/自动探测；
四个已构建前缀为 Linux x64、Windows x64、Android ARM64/x86_64。

表内包括不同版本的历史回归；每份带库哈希的报告只证明对应二进制。
前次 ABI v5 输入停止变更已重跑 CTest、Linux 原生 TLS/NLA/AVC/键鼠/文件/注销/粘贴/光标，
以及 Linux、ASan 和 Windows PE/Wine 的七种声音场景；Flutter 普通测试的五项外部用例仍单独记录，不能计入 85 项通过。

前次会话视野保留变更未修改原生桥接层；六份平台/构建原生库与前次输入释放版本逐字节一致，
各原生报告按原库哈希关联。当时另重跑 CTest、Linux 真实隔离 RDP、Flutter 81 项、
Android 系统手势 19 场景 / 41 阶段和声音生命周期专项；主应用与对应源码包重新构建。

## Android 原生 Surface 与本次交付

本次对应源码、ARM64 APK 与 Linux 包位于 `build/distributions/android-native-video/`。
以其 `BUILD_INFO.json` 关联准确的源文件、AOT、JNI/桥接库和测试 APK 摘要。
上一轮 `native-video/` 和更早 `input-refinement/` 均保持原快照，不混用旧哈希报告。

- Android 使用 Flutter SurfaceProducer 与独立 EGL/GLES 上下文，从原生 BGRA 缓冲上传；
  着色器交换红蓝通道，画面字节不经过 Java/Dart。纹理 ID 0 的有效边界回归通过。
- API36 / x86_64 / PAGE_SIZE=16384，实际系统截图通过 11 个正常阶段、10 个故障回退阶段：
  非对称颜色角标确认通道和方向，黑/白/透明/XOR 光标、放大、隐藏/恢复、视图重建、
  Surface 重建、后台/前台、横屏。正常模式 Dart 整帧解码计数前后均为 0。
- 两种模式均做三次真实重连；会话读取器、EGL Surface/Context、GPU 纹理、注册项和
  空闲轮询归零，EGL 清理失败计数为 0。故障模式实际观察四次上传失败并恢复 CPU 图像。
  后台观察窗口内原生提交计数不增长；测试另发出系统后台内存清理信号。
- 默认原生 Workspace 的完整系统手势回归：22 场景、48 阶段，真实远端键鼠、双指滚动/
  右键、拖拽/取消、边缘跟随、内核鼠标、后台/旋转、返回原 TCP 会话和准确光标位置。
  新增初始画面直接从 Android 合成结果取样，几何依据真实原生宽高，不依赖 RawImage。
- 修正测试鼠标的坐标观察：InputDispatcher 历史坐标先应用系统显示矩阵，兼容旋转矩阵
  和省略单位矩阵的格式。返回会话的单击等待真实远端事件，避免只等 300 ms 与点击
  判定期相撞；点击数、准确坐标和不残留按键的断言保持严格。没有为此改动产品输入逻辑。
- 实际 **lib/main.dart Release AOT** 通过十项 OS 界面/输入场景：NLA、指纹与 Keystore
  重启复用、触控板/直接点击、真实窗口拖动不触发双击、松开后继续点击、右键、滚动、
  连接保持、Android InputConnection 字母/Shift/数字/符号/退格/回车，以及中文组合区
  显示中文时显式发送并完成准确 CLIPRDR UTF-16 / Ctrl+V。以首次原生成功提交日志确认
  默认 GPU 画面确已启用。无 root、无私有配置预填、非 debuggable，run-as 被拒绝。
- ARM64 另构建主入口 Release 预览 APK，显式开发证书签名；24 个基础 C 导出、7 个
  Android JNI 入口、AOT、签名、ELF/RELRO/ZIP 的 16 KiB 对齐通过。没有 ARM64 设备运行证明。
- 本次另修复连接表单在横屏 IME 仅剩约 122 px 时的 22 px 溢出：将保存/连接与关闭
  合并到顶部，保留可滚动输入区。普通和 1.4 倍字号的针对性测试通过，并使用实际 Android IME 检查。
- 历史四用例 Android 套件显式构建 CPU 兼容模式，核对实际文件、剪贴板、Keystore、
  光标、AVC 与故障恢复；它补充兼容路径，不能当成原生 Surface 的像素证明。
  Linux 另重跑原生纹理、故障回退与实际主入口 Release 系统鼠标。

直接证据：`build/android-video-runtime/{native,fallback}/VERDICT.json`、
`build/android-gestures-runtime/VERDICT.json`、`build/android-main-release-runtime/VERDICT.json`、
`build/android-runtime/VERDICT.json`、`build/video-ui{,-fallback}-runtime/VERDICT.json`。
手机像素/手势报告来自 Debug 集成宿主；主入口报告来自单独构建的 Release APK。
模拟器使用软件 GPU，不据此声称物理 GPU 速度、耗电改善或硬件 H.264 解码。
原生/手势与初版 Release 检查使用 3072 MB AVD；CPU Debug 完整套件在系统文件选择器
阶段被 Android lowmemorykiller 终止，保留日志 `build/android-video-low-memory-reproduction.log`。
后续功能验收改用同一专用 AVD 的 6144 MB 配置；不能据此宣称低内存进程终止后的恢复已通过。
较低 Android API、实体 ARM64 手机、Windows/Apple 应用和性能对比仍需各自验收。

## Linux 原生纹理与帧生命周期

本次 Linux 和对应源码快照位于 `build/distributions/native-video/`，以其中的
`BUILD_INFO.json` 为准。`input-refinement/` 的 Android APK 与输入修复报告保持原样，
不把它们作为新增帧缓冲代码的 Android 运行证明。本次未连接公网远程桌面。

- GDI 图像复制进有界原生缓冲后直接上传 GL；纹理活动期间画面字节不进入 Dart。
  三个缓冲槽、最多两个借用回调；慢渲染不会占住生产者锁。原有 CPU 图像路径继续可用。
- 私有 X11 系统截图核对实际 RDP 初始/变化像素、黑/白/透明/XOR 光标、2 倍缩放、
  暂停后画面不变、恢复最新帧、卸载/重建视图并复用纹理。活动阶段 Dart 整帧解码计数
  前后均为 0；另做三次真实重连，关闭后的会话纹理、EGL 上下文和读取句柄均归零。
- Debug 强制首次上传失败，实际观察失败后自动切回 CPU；同样通过六个截图阶段和
  三次重连。四次失败共用一个 1×1 引擎占位图，每会话资源归零，无清理失败；占位图
  随引擎 GL share group 释放。Release 不编入失败注入钩子。
- 修复 ELF 双份核心的符号互插问题：Dart 复用 SONAME，插件 `$ORIGIN` 指向同目录库，
  ELF 内部函数绑定到本库。子进程装载两份库并重复创建/关闭读取句柄的回归通过。
- Flutter 97 项普通测试、6 项外部跳过；原生及 ASan/LSan/UBSan CTest 各 3 项，
  包括填充步长、尺寸变化、失败重试、并发借用期间连续发布与销毁。Python 检查 9 项通过。
- Linux 当前核心实际 TLS/NLA、AVC420 解码和输入通过；Debug、ASan、安装 Release
  均核对鼠标拖动/松开/后续点击，以及 TCP 堵塞时及时停止。主入口 Release 在独立
  GTK/X11 窗口上另做系统鼠标回归。中文发送和键盘模拟继续使用真实协议夹具核对。
- 新 Windows PE 核心重新编译，Wine 下通过帧缓冲单元测试、TLS/NLA/AVC/键鼠/文件/
  Unicode、正常和堵塞输入停止。这不代表 Flutter Windows runner 或 Windows 原生纹理通过。

直接证据：`build/video-ui-runtime/VERDICT.json`、
`build/video-ui-fallback-runtime/VERDICT.json`、`build/linux-mouse-runtime/VERDICT.json`、
`build/input-stop-runtime/{native,asan,native-custom,wine}/VERDICT.json`、
`build/windows-runtime/winpr/VERDICT.json`。各报告按自身库/插件哈希关联；纹理截图来自
Linux Debug 集成宿主，主程序鼠标报告来自实际 lib/main.dart Release。
仍保留 GDI 到原生缓冲的复制；没有声称硬件解码、端到端零拷贝或手机性能已提高。

## 双击拖拽、中文和键盘模拟修复

本次交付在 `build/distributions/input-refinement/`，旧 `mouse-release/` 保留原快照。
以新目录的 `BUILD_INFO.json` 关联源码、APK、AOT、原生库和直接验收报告。

- 本地等待 300 ms 区分单击、双击和第二次按住拖拽。拖拽不预发第一次点击，只发送一次
  按住；快速双击仍发送两次完整点击。立即打开键盘时先完成待发送的远端输入框点击。
- 手机和桌面文字栏共用带确认粘贴；没有剪贴板通道时使用 Unicode 按键。显式发送会
  结束当前组合区，解决部分输入法显示中文后仍在组合而无法点击发送的问题。输入和
  选词不自动发送；取消/失败保留文字。Unicode 在先前 KDE 服务的限制仍适用。
- 英文键盘模拟把组合/提交、删除和回车转换为真实 Set 1 扫描码；提交不重复发送字母。
  支持字母、数字、符号、空栏退格及远程输入法；标点使用美式布局，本地中文选词使用文字模式。
- Android API36、x86_64、16 KiB 实际运行 **lib/main.dart Release AOT**：非 debuggable、
  run-as 被拒绝、无 root、无私有状态预填、客户端无额外权限。通过系统界面创建连接，
  随机凭据实际 NLA、证书和 Keystore 重启复用；通过系统触摸验证单击、拖动真实 X11 窗口
  不触发标题栏双击、松开后点击、右键、滚动和返回原 TCP 会话，共十项场景。
- 测试专用独立 IME 通过 Android InputConnection 发送组合、提交、删除和编辑动作，
  远端实际收到 `a/A/1/!/退格/回车`；中文保留组合区时点击发送，私有 CLIPRDR 服务核对
  完整 UTF-16 文字、唯一公布及 Ctrl+V 的四个扫描码。测试 IME 不进入客户 APK，测试后恢复并卸载。
- Linux 当前主入口 Release 系统鼠标到私有远端窗口的拖动、释放、后续点击、多键和 Esc 回归通过。
  原生安装库哈希仍为 `f42fc976…`，原有释放/堵塞报告继续按该库精确哈希关联。
- Flutter 94 项普通测试、静态分析、原生 CTest 两项、实际 TLS 键盘与中文粘贴/取消协议回归通过。
  ARM64 Release 包为构建验收；品牌输入法、实体手机、Windows/Apple 应用仍需各自设备验收。

直接证据：`build/android-main-release-runtime/VERDICT.json`、`build/keyboard-runtime/VERDICT.json`、
`build/paste-runtime/flutter/VERDICT.json`、`build/linux-mouse-runtime/VERDICT.json`。
发布预览使用显式开发证书签名，正式发布仍需自己的发布密钥。

## 鼠标释放和 Android 点击修复

旧版将 `MOVE|BUTTON` 合并发送。KRDP 按 `DOWN → MOVE → RELEASE` 分类，
会把无 DOWN 的合并释放事件识别为移动，造成窗口拖拽无法结束、后续点击失效。
已在采用相同分类的隔离 TLS 对端复现旧库失败。当前连接线程先定位，再逐键发送
独立按下/松开；正常操作和断开时的释放统一处理，不修改 FreeRDP。
参考 [KRDP InputHandler](https://invent.kde.org/plasma/krdp/-/blob/master/src/InputHandler.cpp)。

- 当前 Linux Debug、安装目录 Release、ASan 适配层和 Windows PE/Wine 都通过实际 TLS
  鼠标拖动/松开、后续左/右/中键点击和断开释放；正常场景收到零个合并按钮/移动 PDU。
  TCP 不读取场景仍要求输入队列连续满 300 ms，停止和销毁小于两秒。
- Flutter 新增四项实体鼠标回归：静止时多键变化、最终松开坐标、遗漏 Up 后的真实鼠标
  悬停恢复、失焦后不重新按下。85 项普通测试通过，五项外部服务用例单列。
- Linux `lib/main.dart` Release 经 GTK/X11 系统输入，连接私有 shadow 服务，真实 X11
  窗口松手后停止移动，后续三键点击、Esc 后点击和双键分开释放通过。
  这不是在实际 KDE/KRDP 桌面上的完整验收；其事件分类由上面的 TLS 对端单独核对。
- Android API 36 / x86_64 / 16 KiB 模拟器的实际系统输入通过 22 场景、47 阶段。
  新增触控板和直接触屏各三次点按、拖拽后再点按，核对完整按下/松开、坐标及无残留按键。
  ARM64 主应用 APK 另行构建检查，不据此声称 ARM64 真机已验收。

本次修复包与源码位于 `build/distributions/mouse-release/`，以该目录的
`BUILD_INFO.json` 为准；上一份完整快照保留在 `build/distributions-abi5-89fd8fba/`。
Windows 本次只重新构建并运行输入专项；旧 Windows 压缩包及声音、粘贴、光标等历史报告
仍对应各自原库哈希。Android 声音历史报告也不作为本次新库的声音验收。

## 用户授权服务的实际连接

在用户明确批准“仅本次信任”证书后，LRDP 核心使用精确 SHA-256 指纹建立 TLS 1.3，
实际解码 2560×1600 H.264 桌面。服务端桌面通知显示 KDE/KRDP。
协商选择 TLS（PROTOCOL_SSL），并未选择 NLA；不能将本次连接当成 Windows/NLA 互操作验收。

直接 Unicode 按键在该服务的 KRunner 输入框未接受中文；新增的“粘贴发送”完成
CLIPRDR 确认/数据/Ctrl+V 后，该框实际显示完整“LRDP 中文输入验证 你好”。
测试未执行搜索命令；随后已清空测试文字并关闭搜索框、断开连接。
该服务的文件重定向互操作未验证；RDPDR 的独立协议夹具通过不替代此项。

密码通过隐藏终端输入送入进程内存，未写入参数、环境、配置或日志。
地址、账号、实际桌面截图与诊断均只在被忽略的私有 build 目录，不能纳入源码或分发包。
公开截图仅来自 TEST-NET 示例配置或独立回环服务。

本次 Android 完整运行前，专用模拟器曾出现 Android 系统输入进程 ANR；
重启并恢复系统响应后重新执行完整流程通过。旧截图元数据误将 ABI 写为常量 3，
实际 worker 的 ABI v4 强制检查通过；报告注明此注记错误，后续截图改为读取实际 ABI。

## 复现与直接证据

按 [构建指南](BUILDING.md) 准备 FFmpeg/OpenSSL 及服务端测试依赖，依次运行：

```sh
flutter analyze
flutter test
ctest --test-dir build/native --output-on-failure
python3 scripts/run_protocol_test.py --nla
python3 scripts/run_protocol_test.py --auth-ui
python3 scripts/run_protocol_test.py --avc
python3 scripts/run_protocol_test.py --avc --flutter
python3 scripts/run_paste_test.py
python3 scripts/run_paste_test.py --flutter
python3 scripts/run_keyboard_test.py
python3 scripts/run_paste_test.py --asan
python3 scripts/run_protocol_test.py --recovery
python3 scripts/run_logoff_test.py
python3 scripts/run_file_test.py
python3 scripts/run_cursor_test.py
python3 scripts/run_cursor_test.py --flutter
python3 scripts/run_protocol_test.py --release
python3 scripts/run_android_test.py
python3 scripts/run_windows_test.py --sspi-provider=winpr
python3 scripts/run_cursor_test.py --wine
python3 scripts/run_paste_test.py --wine
python3 scripts/run_audio_test.py --build build/native
python3 scripts/run_audio_test.py --build build/native-asan
python3 scripts/run_audio_test.py --wine
python3 scripts/run_android_audio_test.py
python3 scripts/run_android_gestures_test.py
python3 scripts/run_input_stop_test.py
python3 scripts/run_input_stop_test.py --build build/native-asan
python3 scripts/run_input_stop_test.py --wine
```

所有测试 RDP 服务绑定回环地址，使用私有桌面；Android 使用 LRDP 专用模拟器和 ADB 5038。
勿并发运行使用相同输出目录、Wine 前缀或 Flutter 构建缓存的测试。
普通 Flutter 测试跳过需要外部服务的用例，需由上述回环命令单独验收。

直接报告在 `build/avc-runtime/*/VERDICT.json`、`build/paste-runtime/*/VERDICT.json`、
`build/cursor-runtime/*/VERDICT.json`、`build/audio-runtime/*/VERDICT.json`、
`build/input-stop-runtime/*/VERDICT.json`、
`build/android-audio-runtime/VERDICT.json`、`build/android-gestures-runtime/VERDICT.json`、`build/windows-runtime/winpr/VERDICT.json`。
`build/android-gestures-runtime/SESSION_VIEW_PROOF.json` 记录离开前/返回后的变换、
客户端实际发出的坐标和远端实际点击；`mode-return.json` 核对操作模式及原 TCP 连接。
带库哈希的报告仅适用于对应二进制；`build/distributions/BUILD_INFO.json` 记录本次最终打包信息。

## Android 7.1 / API25 兼容性专项

2026-10-19：使用独立 `LRDP_API25_x64`、Android 7.1.1 Google APIs r18、
x86_64、内核实际 4 KiB 页，ADB 5038 / emulator-5556，shell UID 2000。
测试最终使用 3072 MiB 模拟内存；初次 4096 MiB 启动曾保持黑屏且不响应 guest
命令，保留原记录后改为 3072 MiB 并启用内核日志，使用同一用户数据完成启动。
这不构成对首次启动问题根因或低内存恢复的结论。

- 原生 Surface 显示 11 阶段、故障回退 10 阶段通过，包含不对称颜色标记、
  黑/白/透明/XOR 光标、远端更新、冻结、重新挂载、Surface 重建、缩放、
  实际 Home/返回、旋转与每组 3 次重新连接。正常原生模式 Dart 解码帧为 0→0；
  每组关闭后的原生对象、上下文、Surface、纹理、注册数及计时器均归零。
- 实际非调试 `lib/main.dart` Release 的 10 项 OS 输入流程通过：NLA 与证书确认、
  触控板/直接触屏点击、双击按住窗口拖动不触发双击、松手后的点击、双指右键/滚动、
  系统 InputConnection 的字母/Shift/符号/退格/回车、原 TCP 会话恢复、
  进程重启后的 Keystore 密码/指纹复用、中文组合文字结束后收到 CLIPRDR 确认再 Ctrl+V。
- 主入口使用既有 Android 原生显示交付中的同一个 x86_64 APK，SHA-256 为
  `fc70b61b502a97b3bb5c34c2d15a6b001e3b6bb75c02df3e30a563bf3cd57a88`；
  `liblrdp.so` 为 `1fa501f8550247d611804222b600105eac8c9ffe77f7ba742331ecaef82d3daf`。
  该 Release 对应 `android-native-video/` 的源快照 `0774bb0e…`，没有因为旧系统测试
  修改应用或放宽其权限。新的 Debug 显示 APK和测试工具的输入哈希另行记录。

本次实际差异集中在测试工具：旧系统没有 getconf/sha256sum、覆盖显示尺寸后的
截图仍用物理尺寸、UIAutomator 的 `/dev/stdout` 不返回 XML、空编辑框不返回提示。
分别改用内核页信息、公开安装代码的哈希、WindowManager 显示坐标映射和 stdout
文件描述符；字段通过可见路由、编辑框顺序/密码标志或键盘模式控件定位，API25
主入口记录了 15 次旧字段定位。没有读取或预填 Release 的应用私有数据。
测试专用 IME 降至 API24，并按 API 选择广播接收器注册；系统触摸驱动按可用类
选择 InputManagerGlobal 或旧 InputManager。两者不进入客户 APK。

报告在 `build/android-api25-video-runtime/{native,fallback}/VERDICT.json` 和
`build/android-api25-main-release-runtime/VERDICT.json`。这只增加 API25 x86_64
模拟器的功能证据，不能代替 API24、ARM64 真机、实际 GPU、音频焦点或 TalkBack
验收，也不构成性能/耗电或优于 aRDP Free 的结论。FreeRDP 源码保持未修改。

更新测试工具后，使用原有 `LRDP_API36_16k`、API36 / x86_64 / 16 KiB
重新完成同样的 11 个原生显示阶段、10 个故障回退阶段、每组 3 次重连，
以及上述同一主入口 Release APK 的全部 10 项流程。正常模式 Dart 解码为 0→0，
关闭后的资源计数归零；主入口全部采用现代系统的语义定位，旧字段定位次数为 0。
记录独立保存在 `build/android-compat-api36-video-runtime/{native,fallback}/VERDICT.json`
和 `build/android-compat-api36-main-release-runtime/VERDICT.json`，未覆盖此前交付证据。

这次 API36 冷启动曾出现系统界面的“System UI isn't responding”窗口，遮挡首次
显示截图；保存窗口和层级记录并选择系统的 Wait 后，重新运行完整流程通过。
这不是应用崩溃或实际 GPU 稳定性结论。两个专用模拟器验收后均移除测试应用和
测试 IME 并停止，ADB 5038 服务保持原状；未接触个人设备或再次连接公网主机。

## 小屏、大字号与输入模式菜单

2026-10-19：修正两处 Flutter 输入界面。手机输入面板和桌面文字对话框可滚动，
在大字号和输入法占用较多空间时仍能查看完整提示、找到操作按钮。手机模式菜单
改用避开输入法的菜单，触摸选择时保留输入焦点，外接键盘仍可导航选择。
此前实际系统截图中，“键盘模拟”选项会落在输入法后方；仅保留焦点并不能解决遮挡。

- 106 项 Flutter 测试通过，6 项依赖外部环境的测试跳过；静态分析无问题。
  新增 200% 字号的连接列表、分组、编辑、设置、横竖屏输入提示与菜单位置回归，
  列表检查 Android 触摸目标和标签；这些布局检查不等于 TalkBack 验收。
- 原生 CTest 3 项、Python 工具测试 9 项通过；隔离 TLS/RDP 的实际键盘测试核对
  字母、Shift、数字、符号、退格和回车，组合输入不重复发送，按下/松开配对。
- 同一个非调试 `lib/main.dart` Release APK，在 API36 / x86_64 / 16 KiB
  专用模拟器上，普通字号 10 项及小屏 200% 字号 12 项全部通过。小屏为
  320×568 / 568×320 逻辑尺寸，测试输入法至少占 160 dp；两种方向均实际选择
  两个输入模式，检查菜单在输入法上方、完整错误提示可滚动阅读、收起按钮可操作，
  不支持的本地中文组合没有发出远端按键。两组均核对 NLA、证书确认、原生呈帧、
  点击/拖动释放/右键/滚轮、原 TCP 会话恢复、重启后的 Keystore 复用及中文发送。
  中文通过实际 InputConnection 组合文字、CLIPRDR UTF-16 确认和随后 Ctrl+V 验证。
- x86_64 APK SHA-256：
  `d2fbb9dd13a9aee7e44b650b6d325cf601e729d92f92c182328c3654d82a79bc`；
  `liblrdp.so`：`85c1b9aabc0c25d9f24e7a679ad4f73d6134cc02dffd99a4e1a419a2818379f0`。
  ARM64 Release 预览包也已构建并通过 APK/ELF/ZIP 16 KiB 对齐检查，SHA-256 为
  `b34804b35feefc93394cdd5fc6126838e31708a50835ac5123168e008fededa7`，
  ARM64 真机尚待验收。两包使用明确启用的本地开发证书签名。

报告位于 `build/android-large-text-{default,main-release}-runtime/VERDICT.json`，
分发包、对应源码及证据归档位于 `build/distributions/large-text/`。
完整提示截图：[竖屏](screenshots/android-large-text-keyboard-portrait.png)、
[横屏](screenshots/android-large-text-keyboard-landscape.png)；菜单截图另收入证据归档。

本轮测试专用输入法增加最小高度，避免把一行高的输入法窗口当作完整键盘布局。
首次启用测试输入法曾返回 255，工具改为等待 Android 实际列出已安装的输入法再启用；
失败记录保留，之后完整流程通过。冷启动的系统界面 ANR 也保留独立记录，
在专用 AVD 上选择系统 Wait 后才重新运行。测试不使用 root、run-as、私有配置预填或
额外应用权限；退出恢复字号、显示尺寸/密度与旋转设置，移除测试输入法并关闭专用 AVD。
FreeRDP 源码未修改；本轮功能证据仅覆盖上述模拟器与布局测试，厂商输入法、实体
ARM64/GPU、TalkBack/VoiceOver 和其余平台应用仍按各自范围验收。

## 手机键盘展开时操作远程画面

2026-10-19：手机远程画面的触摸区域保持当前输入连接，键盘模拟使用不绘制的
输入控件；界面只显示工具栏和“显示键盘”，系统返回键隐藏输入法后可以再次打开。
长提示在工具栏区域滚动，保留远程画面的触摸区域。

- Flutter 111 项通过，6 项依赖外部环境的用例跳过，静态检查无问题。
  新增横竖屏 × 文字/模拟模式的四项回归，覆盖键盘展开时点击、按住拖动、
  双指滚动以及操作后继续输入。禁用焦点保护的原实现会在四项中全部失败；
  原大字号长提示布局的画面仅有 0–10 逻辑像素，新增回归要求至少保留 48。
- 原生 CTest 3 项、Python 工具测试 9 项及隔离 TLS/RDP 键盘协议测试通过。
  没有修改 FreeRDP 或原生适配层；原生库哈希与上一版一致。
  补充回归确认重新显示键盘时先附加输入客户端，再请求系统显示；旧顺序会失败。
- 实际非调试 `lib/main.dart` Release APK 已在专用 API36 / x86_64 / 16 KiB
  模拟器通过普通字号 12 项及小屏 200% 字号 14 项。小屏逻辑尺寸为
  320×568 / 568×320；测试输入法至少占 160 dp。两种模式都通过系统触摸执行轻点、双指右键、
  双指滚动和按住拖窗，独立核对服务端收到的事件及释放后的指针掩码为零；
  每步后输入法仍可见且继续接收 InputConnection 输入。模拟模式没有可见
  EditText，系统返回键收起后，“显示键盘”再次展开输入法。
  既有 NLA、证书、原生呈帧、会话保持、Keystore 重启复用及中文组合发送流程也通过。
- x86_64 APK SHA-256：
  `3b4c280f92d86b51f93ac8ed95561d55cd279157f2fa015535a26b6edec692d5`；
  ARM64 Release 预览包：
  `c5c3f6f8918e9a8648e87ab2c4f12aa41a71488cc75bfec1bdbf403e55a4bdbb`。
  两包通过 APK/ELF/ZIP 16 KiB 对齐检查，使用明确启用的本地开发证书签名。

小屏报告：`build/android-ime-control-main-release-runtime/VERDICT.json`。
普通字号报告：`build/android-ime-control-default-runtime/VERDICT.json`。
[文字输入操作后](screenshots/android-ime-control-text.png)、
[隐藏输入框的键盘模拟](screenshots/android-ime-control-keys.png) 为系统截图；
底部灰色区域是隔离测试输入法，用于真实 InputConnection 验收，不是产品键盘皮肤。
横屏验收发现，“显示键盘”直接请求系统显示时，可能早于编辑控件附加输入连接。
旧包实测的 `mServedInputConnection` 为空、编辑类型为 0、IME 布局边界高度为 0，
尽管输入法已经绘制，却没有给应用提供避让范围。现通过
`EditableTextState.requestKeyboard()` 先附加客户端再显示；新包旋转后及系统返回后
均由真实 InputConnection 操作确认连接可用。长提示下的远程区域，竖屏为 162
物理像素高，横屏为 104；模式菜单和完整提示均有系统截图。

本轮另保留应用启动命令返回 255、执行中断、键盘用例之前的 NLA 失败及重启后
System UI 无响应的记录；
System UI 在启动 LRDP 前选择系统“等待”，以 API36 的 UI 层级确认通知栏及返回
恢复响应后才进入完整验收。辅助预检曾用旧系统的 XML 输出路径而未取得层级，
已纠正并单独留存停止的运行；这些中途记录不算通过报告。
本轮不使用 root、私有配置预填或额外应用权限，仅操作 ADB 5038 / emulator-5556
上的专用 AVD 与隔离回环 RDP 服务；没有重连公网主机。
分发包、对应源码与证据归档位于 `build/distributions/phone-keyboard/`。
ARM64 实体手机、厂商输入法、TalkBack/VoiceOver 和其他平台应用仍待对应验收。

## Windows 原生像素缓冲纹理专项

2026-10-19：使用 Flutter 引擎内容哈希
`616aa037ef00bf7a8c62500da7dec7f1c21ad59b` 的官方 Windows x64 Debug DLL，
MinGW 编译实际 LRDP 插件 DLL，运行独立 Dart 显示入口、真实 `RdpSession` worker
和 `lrdp.dll`。两端使用私有 X11 桌面和回环 TLS RDP 服务，验收图像来自系统截图。

- 正常原生纹理与实际上传失败回退各 6 阶段：初始颜色、远端变化、隐藏、保持隐藏、
  重新挂载后恢复、2 倍缩放。核对两个不对称红蓝标记、黑/白/透明/反相光标，
  以区别颜色通道错误、上下颠倒、停留旧帧和 XOR 合成错误。
- 两组各 3 次重新连接；原生模式 Dart 解码帧为 0→0，CPU 回退为 1→3，失败计数为 4。
  关闭后的注册数、原生对象、借用缓冲和 RGBA 缓冲字节数均为零；真实引擎退出返回。
- 缓冲层的真实帧存储测试覆盖 RGBA、尺寸变化、两个延迟释放的借用、第三次借用拒绝、
  隐藏/恢复、500 次并发发布、会话销毁后的延迟释放及上传失败回退。
  Linux 的 5 项 CTest、两项适配层 ASan/UBSan/LSan 和 Windows PE/Wine 两种缓冲测试通过。
- Windows 核心重新通过 TLS/WinPR SSPI NLA、AVC、键鼠、1 MiB 双向文件和 Unicode
  协议回归。Flutter 普通测试 99 项通过、6 项外部用例跳过，静态检查无问题。
- 实际退出发现插件在引擎已清除消息通道关联后仍调用 SetCallback，造成空指针访问。
  已修复为检查消息通道可用性；修复后的两组显示流程和引擎析构均通过。

Wine 11.20 默认 VirtualAlloc2 路径的运行曾在自身 `create_view` 断言退出；
内存日志记录了对仍在使用的同一地址区间的重复分配。显示通过的报告使用显式
`--wine-legacy-allocator`：只在测试宿主中选择该 Dart 版本已有的旧分配器路径，
不修改引擎磁盘文件、生产插件或 FreeRDP。失败原始日志保留在
`build/windows-video-runtime/debug-jit-*-failure/`，退出回归原始失败在
`messenger-shutdown-failure/`；正常和回退通过报告在 `native/`、`fallback/`。

这证明了有上述 Wine 兼容条件的 Windows Flutter 原生显示链路，不代表
`lib/main.dart` 的完整 Windows 应用、MSVC、真实 Windows SSPI/凭据管理器、
实际 GPU、键鼠手感或性能比较已经验收。当前路径仍在原生 CPU 中转换和上传像素，
没有 Direct3D 共享纹理或硬件 H.264。FreeRDP 子模块保持未修改，未重连公网主机。

## 中文文字发送方式修正

用户确认新版 Android 的键盘展开后触控问题已恢复，并反馈“文字输入”能显示中文、发送后远端无文字。
此前发送箭头在 CLIPRDR 可用时固定采用剪贴板确认和 Ctrl+V；通道成功不能证明远端应用接受粘贴。
现在“文字输入”默认发送成对的 UTF-16 Unicode 键盘事件，即使剪贴板可用也不走粘贴。
模式菜单保留单独的“粘贴输入”，两种文字模式之间保留草稿及输入焦点；不自动用另一方式重发。
“键盘模拟”继续保持英文字母扫描码语义。原生连接线程读取协商后的 Unicode 能力，
通过 ABI v5 的新增特性位 3 通知 Dart；服务端不支持时保留草稿并提示切换，不发送不支持的事件。

验证报告及本次 Android 包以新下载目录 `chinese-input` 为准。测试覆盖已确认的中文组合区提交、
UTF-16 代理对、无剪贴板发布/无 Ctrl+V，以及显式粘贴流程。公开服务未重连；用户远端应用的
实际接收仍需安装此包验收，不能用协议夹具成功代替其输入框显示成功。

## 手机特殊按键与保持键

手机输入面板加入可保持的 Ctrl/Shift/Alt/Win、空格和可展开横向滚动的特殊按键栏，
包含 F1～F12、导航、删除与常用组合键。键盘模拟的字符和快捷键只临时按下未保持的修饰键，
因此自动 Shift 不会松开用户保持的 Shift。保持键在面板关闭、失焦、切换文字模式、
后台或控件销毁时释放；输入面板收紧时默认折叠扩展栏。

控件回归核对 Ctrl+输入法空格、Shift 连续输入及大写、全部 F1～F12 与 Ctrl+Alt+Del，
并核对退出/后台/失焦释放与触摸远端时保留。实际 TLS/X11 独立输入记录还核对字符、
X11 修饰状态和按下/释放配对。Android 主入口 Release 通过系统按钮与真实 InputConnection
核对的范围以新报告为准，不等同于 ARM64 真机或厂商输入法验收。

本次最终检查：122 项 Flutter 测试通过，6 项外部协议测试在普通测试集中跳过；静态分析无问题，
原生 CTest 3 项、Python 检查 9 项、直接 Unicode/不支持时保留/粘贴/取消四种 TLS 流程及
保持键/F1～F12 的独立 TLS/X11 回环通过。实际 `lib/main.dart` Release AOT 主应用在
API36 x86_64 / 16 KiB 的 14 项系统输入场景通过，包括 Ctrl+真实 IME 空格、Shift + 远端点击及
连续大写、F1/F12、收起时 Alt 释放、Keystore/NLA 重启复用、Unicode 中文/表情 34 个成对事件，
及重新输入临时登录密码后显式粘贴；模式关闭再打开后仍保留。报告位于
`build/android-chinese-input-runtime/VERDICT.json`，匹配包与源码在 `build/distributions/chinese-input/`。

Unicode/CLIPRDR 协议夹具不发送桌面图形，对应中文截图显示“等待远程画面”是该夹具的范围，
并非远端输入框显示成功的证据。测试期间修正了点击目标未跟随测试窗口移动，以及二次临时登录
未填写密码这两处驱动问题；未修改安装包、未重连公网主机。当前按键界面截图见
[保持 Shift](screenshots/android-sticky-shift.png)。ARM64 APK 仅完成构建和静态检查，真机、
厂商输入法及用户远端应用的中文显示仍待验收。

## 尚待验收

- Android ARM64 真机触控、软键盘、旋转、后台/锁屏、Wi-Fi/蜂窝切换与静默丢包恢复。
- Flutter Windows runner、真实 Windows 系统 SSPI/凭据存储及 Windows RDP 服务互操作。
  先前 Wine system SSPI 返回 SEC_E_INVALID_TOKEN；当前通过的是显式 WinPR 后端。
- macOS/iOS 构建、系统插件、签名、沙盒目录和真机；脚本接入尚不等同于平台通过。
- 其他 Linux 发行版 ABI、系统钥匙串、实际网络下的性能/耗电及 8 小时稳定性。
- Android ARM64 / Windows / macOS / iOS 实机音频、实际延迟、A/V 同步和声卡切换恢复；Android 模拟器已检查自身音轨，主机声音回录使用隔离虚拟声卡。
- 长时间后台缓存进程冻结、系统终止后恢复、蓝牙路由与锁屏音频；当前实现不提供手机前台服务。
- Apple 原生纹理、Windows 主应用/真实 GPU；Android 较低 API / 不同 GPU / ARM64 真机；硬件解码、剪贴板文件粘贴、RD Gateway、RemoteApp 与多显示器。

文件重定向使用标准 RDPDR，服务端需允许；中文粘贴需允许 CLIPRDR。
动态分辨率取决于服务端 DISP 通道。移动端本地剪贴板读取由用户明确操作触发。


## Android 系统手势补充验收

第一次系统手势专项验收时，197 个应用及构建文件与源码快照 `8e6bc4d6…` 逐字节一致，
当时的四个包与补充验收归档保存在 `build/distributions-abi5-8e6bc4d6/`。
后续输入释放修复包含生产代码变更；当前安装包、源码及重跑报告以下载目录的
`BUILD_INFO.json` 和各报告的库哈希为准。测试用网格桌面的截屏：
[放大与边缘跟随](screenshots/android-gesture-follow.png)、
[拖拽中旋转后的横屏](screenshots/android-gesture-landscape.png)。
[返回原会话后的视野与光标](screenshots/android-session-restored.png) 来自当前系统输入回归。

测试先以系统点按确认输入到达应用，再发送待验收手势并独立读取远端事件。
横向滚轮按未修改的 X11 shadow 后端按钮映射核对；Windows 页面的实际方向及硬件手感
仍需 Windows/真机验收，细节见构建指南。设备模拟不构成触控延迟、耗电或 aRDP 性能对比。

当前专项第一次运行被专用模拟器的 SystemUI 无响应弹窗阻挡，在第一个待测手势前停止；
重启并确认快捷设置及返回操作可响应后重新验收。诊断还发现 Android 在手指按下前补发
touch 类型悬停，已在单元测试和真实 RDP 事件中复现并修复，不能作为正常鼠标移动处理。
测试入口使用被动输入观察器，调用生产 `RdpSession` 的真实 worker，只记录测试坐标；
观察器和系统输入辅助工具不进入主应用 APK。
