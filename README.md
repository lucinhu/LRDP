# LRDP

使用 **Flutter + FreeRDP** 构建的跨平台远程桌面客户端。

[LRDP 图标与各平台资源](assets/branding/README.md) · [图标预览](assets/branding/preview.png)

![连接库预览（测试配置）](docs/screenshots/workspace.png)

当前为 **0.1 开发预览**，目标是以可测量的日常体验超过 aRDP Free。
FreeRDP 3.32.2 固定为 Git 子模块，所有桥接、通道和构建适配都在 LRDP 中，
不修改 FreeRDP 源码。

```sh
git submodule update --init --recursive
flutter pub get
bash scripts/build_ffmpeg.sh linux-x64
export LRDP_FFMPEG_ROOT="$PWD/build/deps/ffmpeg/linux-x64"
flutter run -d linux
```

构建需要 Flutter ≥ 3.41 / Dart ≥ 3.11、CMake ≥ 3.22、Ninja、C/C++ 工具链、OpenSSL 3，以及各平台 Flutter
依赖。H.264 使用 FFmpeg 9.0.2 的最小静态解码器；完整说明见 [构建指南](docs/BUILDING.md)。

已实现连接库、快速连接、分组/收藏/搜索/最近使用、多会话切换、系统配色与自动明暗外观、
`.rdp` 导入导出、后台 RDP 连接与 BGRA 画面、键鼠和组合键、中文文字发送、
带确认的中文/图片粘贴、文字与双向图片剪贴板、选择本机文件粘贴到远端、H.264 软件解码、动态分辨率通道、服务器光标形状/热点与单色反相、RDP 磁盘重定向文件中转站，以及可取消、有次数上限的掉线重连。密码使用系统安全存储；未验证证书需要明确核对
SHA-256 指纹，支持临时确认或保存指纹。

Linux 已完成真实回环 RDP、NLA、文件传输和原生界面联调，并提供发布构建。
Android ARM64 Release 预览 APK 已完成构建，使用明确启用的本地开发证书签名；API 36 / x86_64 / 16 KiB 模拟器已通过
实际协议、系统安全存储和手机操作流程。Windows、macOS、iOS 均有工程与
构建接入，各平台真机验收仍在进行。远程声音采用平台后端，Linux 与 Windows 核心/Wine
通过私有声卡波形检查；Android 模拟器通过实际音轨播放、后台暂停、回到会话继续及音频焦点恢复检查。
本机文件粘贴通过独立 TLS 协议测试，真实文件管理器互操作仍待验收；操作及限制见 [剪贴板与文件传输](docs/CLIPBOARD.md)。
远端文件剪贴板下载、文件夹粘贴、RD Gateway、
多显示器和硬件视频解码尚未实现。浏览器不是本项目的原生
RDP 运行目标。

Windows x64 连接核心已交叉编译为 PE DLL，并通过 Wine 下的实际协议回归；
NLA 使用显式 WinPR SSPI 模式通过。Wine 原生 SSPI 路径仍失败，Flutter
Windows 窗口与真实 Windows 系统仍待验收，详见 [验收记录](docs/VERIFICATION.md)。

手机使用底部导航、全屏连接表单和底部会话操作栏；默认触控板，支持双指轻点右键、
横竖滚动、捏合缩放、双击按住拖拽、Unicode 中文发送、显式粘贴与英文软键盘模拟；
Ctrl/Shift/Alt/Win 可保持并与输入法组合，支持 F1～F12 及扩展特殊键。放大后视野随光标到达边缘移动。
键盘展开时可继续操控画面；模拟模式隐藏本地输入框，支持重新唤起键盘。已覆盖横竖屏和软键盘避让的
自动化测试；Android 模拟器还验证了真实系统键盘、触控、旋转、后台恢复、
文件选择器及分享窗口；真实流量故障注入验证了后台掉线不消耗重试、返回恢复画面，及后台换证书延后确认。ARM64 Android / iOS 真机仍待验收。

画面帧率默认跟随屏幕，可设置最高 240 帧/秒的客户端上限。Android 与 Linux 原生显示
使用系统垂直同步，CPU 回退保留单帧背压；实际效果受远端输出、网络和设备性能影响。
实体高刷新率屏幕的性能、延迟与耗电仍需真机验收。

[手机连接列表预览](docs/screenshots/phone-workspace.png) ·
[手机会话操作栏](docs/screenshots/phone-remote.png) ·
[中文输入栏](docs/screenshots/phone-keyboard.png)

[保持 Shift 与扩展按键（当前 Android 模拟器）](docs/screenshots/android-sticky-shift.png)

Android 模拟器实际截图：[竖屏中文栏](docs/screenshots/android-keyboard.png) ·
[横屏键盘](docs/screenshots/android-landscape-keyboard.png) ·
[系统分享](docs/screenshots/android-share-sheet.png) ·
[换证书确认](docs/screenshots/android-certificate-changed.png)。

- [使用指南：连接、中文、文件传输](docs/USAGE.md)
- [架构与资源所有权](docs/ARCHITECTURE.md)
- [开发目标和验收清单](docs/ROADMAP.md)
- [构建与 FreeRDP 升级](docs/BUILDING.md)

```text
lib/                     Flutter 界面、配置、RDP isolate 与 FFI
native/                  独立 C ABI、FreeRDP 回调、线程与生命周期
packages/lrdp_native/    五个平台的原生构建接入
third_party/FreeRDP/     上游子模块；保持源码未修改
scripts/                 平台依赖构建、隔离回环协议回归
```

运行 `flutter analyze`、`flutter test` 和原生 CTest 检查；真实协议回归使用
`python3 scripts/run_protocol_test.py`。协议测试启动私有虚拟桌面，不接触用户
当前桌面。`python3 scripts/run_file_test.py` 验证独立 TLS/RDPDR 文件双向传输与 Unicode 输入。详细测试范围记录在 [验收记录](docs/VERIFICATION.md)。

Apache-2.0。第三方项目保留其各自许可。
