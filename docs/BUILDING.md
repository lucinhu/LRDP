# 构建

所有命令从仓库根目录执行。需要 Flutter ≥ 3.41 / Dart ≥ 3.11、Git、CMake ≥ 3.22、Ninja、
C/C++ 编译器及 OpenSSL 3。用 `flutter doctor -v` 检查本机工具链。

GitHub Actions 的 `Check` 工作流固定使用 Flutter **3.47.7 stable**，并输出 Flutter 与
Dart 版本。提交前用同一版本运行以下检查，避免旧 SDK 与 CI 的格式化结果不同。

```sh
git submodule update --init --recursive
flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
flutter analyze
flutter test
```

格式检查失败时，运行 `dart format lib test integration_test test_driver`，审查并提交格式调整，
然后重跑检查。CI 保留格式校验，不会自动修改仓库中的文件。

输入体验回归可单独运行 `flutter test test/input_experience_test.dart`，覆盖模式、草稿、软键盘
编辑事件与全屏释放布局。实际按键传输使用 `python3 scripts/run_keyboard_test.py`，
输入释放与堵塞取消使用 `python3 scripts/run_input_stop_test.py`；这些脚本只使用隔离回环服务。
桌面系统级验证需先构建主入口 Release，再运行 `scripts/run_linux_mouse_test.py`，
可用 `--window-manager /path/to/openbox` 在私有 X11 内验证真实全屏与快捷键恢复。
上述 Flutter/协议检查不替代手机厂商输入法、Wayland 或其他桌面系统验收。

系统配色依赖 `dynamic_color` 固定为 1.8.1，版本和下载摘要见 `pubspec.lock`；
源码由 Pub 缓存管理，不复制到仓库，也不修改 Pub 缓存。1.9.0 的 Android Kotlin DSL
在本项目 AGP 8.12.1 / Kotlin 2.2.20 下编译失败，因此没有采用。升级前应重新验证
Android Release 与各桌面插件构建。主题默认跟随系统，不支持动态配色的平台使用默认颜色。
Windows 对固定插件的 `MethodResult::Success(nullptr)` 调用做一处兼容适配：
`native/cmake/dynamic_color_compat.cmake` 校验原文件 SHA-256，只在构建目录生成
使用 `Success()` 的副本，普通 Flutter Windows 构建和交叉构建均使用这份副本。

界面支持简体中文、繁体中文和英语，默认跟随系统。翻译目录修改后运行
`python3 scripts/generate_localizations.py`，再运行本地化测试；生成的同步消息数据已经
提交，普通构建无需额外生成步骤。语言扩展与参数规则见 `docs/LOCALIZATION.md`。

## Linux

H.264 默认开启。先构建固定版本的最小静态 FFmpeg（需要 Make；x86 SIMD 建议安装 NASM）：

```sh
bash scripts/build_ffmpeg.sh linux-x64
export LRDP_FFMPEG_ROOT="$PWD/build/deps/ffmpeg/linux-x64"
```

Debian/Ubuntu 构建依赖（其他发行版安装同等开发包）：

```sh
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libssl-dev libsecret-1-dev libpulse-dev
flutter run -d linux
flutter build linux --release --target lib/main.dart
bash scripts/package_linux.sh
```

默认直接编译仓库内固定版本的 FreeRDP，静态链接进 `liblrdp.so`，无需外部
FreeRDP 客户端。安装包仍依赖 GTK、OpenSSL、libsecret、libpulse 等系统运行库。
安全存储需要正在运行并已解锁的 Secret Service（例如 GNOME Keyring 或
KWallet Secret Service）。不可用时不会将密码写入明文文件。

Linux 打包脚本检查主程序入口、ABI v5，以及安装目录的 Dart AOT 是否早于源码，
拒绝将集成测试入口或旧原生库打入用户包。打包前需等待构建及安装阶段完成。
发布前还要求当前主入口通过实际鼠标、全屏与窗口恢复检查，以及输入停止检查。
运行环境需要 Xvnc、freerdp-shadow-cli3、xdotool 和 Openbox；Openbox 仅用于私有测试显示：

```sh
python3 scripts/run_linux_mouse_test.py --window-manager /usr/bin/openbox
python3 scripts/run_input_stop_test.py --library build/linux/x64/release/bundle/lib/liblrdp.so
bash scripts/package_linux.sh
```

窗口图标通过 `glib-compile-resources` 嵌入可执行文件。解压分发包后运行
`./install-desktop.sh`，可将当前路径注册到当前用户的应用菜单并显示 LRDP 图标，
无需 root。注册后应保留解压目录的位置。图标源文件和重新生成步骤见
`assets/branding/README.md`。

单独构建桥接层和回归测试：

```sh
cmake -S native -B build/native -G Ninja -DCMAKE_BUILD_TYPE=Debug -DLRDP_BUILD_TESTS=ON
cmake --build build/native -j 4
ctest --test-dir build/native --output-on-failure
python3 scripts/run_protocol_test.py
python3 scripts/run_protocol_test.py --nla
python3 scripts/run_protocol_test.py --auth-ui
python3 scripts/run_protocol_test.py --flutter
python3 scripts/run_protocol_test.py --avc
python3 scripts/run_protocol_test.py --avc --flutter
python3 scripts/run_paste_test.py
python3 scripts/run_paste_test.py --flutter
python3 scripts/run_trackpad_test.py
python3 scripts/run_protocol_test.py --recovery
python3 scripts/run_cursor_test.py
python3 scripts/run_cursor_test.py --flutter
python3 scripts/run_logoff_test.py
python3 scripts/run_file_test.py
python3 scripts/run_frame_rate_test.py
python3 scripts/run_resolution_test.py
python3 scripts/run_file_clipboard_test.py
python3 scripts/run_file_clipboard_test.py --flutter
python3 scripts/run_audio_test.py --build build/native
python3 scripts/run_protocol_test.py --live-ui
python3 scripts/run_protocol_test.py --release
```

文件粘贴使用现有 `file_selector`，不增加依赖或应用权限。原生适配使用 ABI v5 的新增
`lrdp_paste_files` 接口，Dart 按功能位 5 延迟查找；服务端未协商文件流时不启用入口。
选中的文件在私有临时目录形成快照，原生固定只读句柄，在连接线程按需读取；单块最多
1 MiB，不将整个文件载入内存。CLIPRDR 回调使用有界邮箱，所有协议响应由连接线程发送；
入站邮箱最多 63 个事件、32 MiB 数据。未声明锁定剪贴板和超大文件支持，换用其他剪贴板
内容撤销旧文件。操作与限制见 [CLIPBOARD.md](CLIPBOARD.md)。

独立文件测试需要系统 `freerdp-server3`、`freerdp3`、`winpr3` 开发包及 OpenSSL CLI，
服务只绑定随机回环端口。`--flutter` 经过真实 worker/FFI/TLS，系统文件选择器使用替代接口，
不作为实际系统文件选择器或远端文件管理器验收。发布安装库可用：

```sh
python3 scripts/run_file_clipboard_test.py --library build/linux/x64/release/bundle/lib/liblrdp.so
```

协议测试需要 `Xvnc`（TigerVNC）、`freerdp-shadow-cli3`、`xsetroot`，自动启动
独立虚拟桌面，RDP 仅绑定回环地址，结束时清理服务。不会控制当前用户桌面。
`--live-ui` 使用第二个私有显示运行客户端，避免画面递归；`--release` 的
窗口绘制验收还需要 Python Pillow（如 Ubuntu 的 `python3-pil` 包）。
开发时可用 `-DLRDP_USE_SYSTEM_FREERDP=ON` 显式链接系统 FreeRDP 3；发布构建
应保持默认关闭。文件协议测试另需系统 FreeRDP 3.32.2 的 server/core/WinPR 开发库与 pkg-config；它只把测试服务端链接到系统库，客户端仍是仓库子模块构建的桥接层。`LRDP_NATIVE_LIBRARY` 可为 FFI 测试指定库的绝对路径。

`run_trackpad_test.py` 将 Flutter 桌面触控板手势事件送入生产 worker 与 FreeRDP，
由独立 TLS 服务端检查竖向/横向滚轮 PDU 的方向和次数，以及捏合、失活后无额外输入。
事件由测试合成，实体触控板和操作系统驱动仍需单独验收。剪贴板使用方法及当前图片、
文件范围见 [CLIPBOARD.md](CLIPBOARD.md)。
只复现“粘贴本机文字”入口可运行 `python3 scripts/run_paste_test.py --flutter --case local`，
结果写入独立的 `VERDICT-local.json`；不带 `--case` 运行全部对应场景。

## Windows

在 Windows 上安装 Flutter 推荐的 Visual Studio C++ 工作负载、CMake ≥ 3.22、
Ninja 与静态 OpenSSL 3。设置 `OPENSSL_ROOT_DIR` 指向对应架构的 OpenSSL
安装目录；同时用对应 MSVC 工具链构建最小静态 FFmpeg，设置 `LRDP_FFMPEG_ROOT`
指向其前缀（`include/`、`lib/avcodec.lib`、`swscale.lib`、`avutil.lib`），再运行
`flutter build windows --release`。MSVC 构建仍待 Windows 验证。发布前检查 DLL 依赖与
系统凭据存储。Linux 无法运行 Flutter Windows runner 或替代 Windows 验收。

在 Linux 上可使用 MinGW-w64 交叉编译连接核心，再由独立 Wine 环境执行协议
回归。需要 `x86_64-w64-mingw32-gcc/g++/windres`、Perl、Make、Wine、Xvnc、
系统 FreeRDP 3.32.2 服务端开发库，以及未修改的 OpenSSL 3.x 源码：

```sh
export LRDP_OPENSSL_SOURCE=/path/to/openssl-3-source
export LRDP_BUILD_JOBS=3
bash scripts/build_windows_openssl.sh
bash scripts/build_ffmpeg.sh windows-x64
bash scripts/build_windows_core.sh
python3 scripts/run_windows_test.py --sspi-provider=winpr
python3 scripts/run_cursor_test.py --wine
python3 scripts/run_paste_test.py --wine
python3 scripts/run_audio_test.py --wine
python3 scripts/package_windows_core.py
```

产物为 `build/windows-x64/lrdp.dll` 及生命周期、协议测试程序。
测试脚本使用 `build/windows-runtime/wineprefix` 和私有虚拟桌面；各认证后端的
日志与报告在 `build/windows-runtime/{winpr,system}/`。Windows 路径按 UTF-8 进入 C ABI，测试程序的
Unicode 命令行使用 UTF-16 转换。Winsock 的初始化与清理由连接线程配对执行。
Flutter Windows 应用的窗口、系统插件、凭据存储和实际 Windows 运行仍需验收。
开发包输出为 `build/distributions/*-windows-x64-core-debug.zip`，包含 DLL、
C ABI 头文件、依赖许可和明确标注运行范围的验收报告；打包时核对 DLL 哈希与
实际测试报告一致。该包供核心开发与集成使用。

Windows 的原生像素缓冲纹理通过 `lrdp_native_plugin.dll` 注册，`lrdp.dll` 仍负责
连接核心。两者应来自同一源码版本；主工程正常执行 `flutter pub get` 会生成插件注册。
画面在原生层转换为 RGBA，由 Flutter 上传；没有共享 Direct3D 纹理或硬件解码。
纹理不可用时自动恢复现有 Dart 图像路径。

在 Linux 上还可交叉编译独立的 Debug Flutter Windows 显示验收宿主，运行真正的
Flutter Windows 引擎、插件 DLL 和 Dart worker，然后从私有 X11 桌面核对系统像素：

```sh
export FLUTTER_ROOT=/path/to/flutter
python3 scripts/build_windows_video_host.py
python3 scripts/run_windows_video_test.py --wine-legacy-allocator
python3 scripts/run_windows_video_test.py --wine-legacy-allocator --fail-upload
```

先按上文构建 Windows 核心与静态依赖。构建脚本需要 Flutter 仓库中的
`engine/src/flutter/shell/platform/` 客户端包装源码；它按本机 Flutter 缓存的
引擎内容哈希下载官方 Windows Debug 引擎到 `build/deps/flutter-windows/`，
核对 SDK 公共头文件，记录下载和构建哈希。使用 Linux frontend server 编译可移植
Debug kernel，实际操作系统判断在 Windows VM 内发生。
脚本使用独立的 `build/windows-video-runtime/wineprefix`、两个私有桌面和本地 TLS
服务，不控制当前桌面、不使用公网主机。报告保存在该目录的 `native/`、`fallback/`。
这个宿主只包含显示专项入口，不是 `lib/main.dart` 的 Windows 应用验收，也不验证
MSVC、Credential Manager、真实 Windows GPU 或安装包。

本次 Wine 11.20 的 `VirtualAlloc2` 把同一内存区域分配给两个仍在使用的请求，
导致 Dart VM 在画面显示前触发 Wine 自身的断言。`--wine-legacy-allocator` 仅让
测试宿主在进程中对 Flutter 的 `GetProcAddress("VirtualAlloc2")` 返回不可用，
选择 Dart 3.12 已有的旧版 VirtualAlloc 路径；其他 API 查询保持原行为。
该选项不进入生产插件、不修改引擎磁盘文件，也不修改 FreeRDP。
默认路径的失败日志和内存映射记录保存在 `build/windows-video-runtime/`。
这是有明确兼容条件的 Wine 显示验收，不等同于未调整的 Windows 主应用验证。

缓冲层测试也可独立运行。配置 `LRDP_FLUTTER_TEXTURE_HEADERS` 为 Flutter 的
桌面公共头文件目录（包含 `flutter_texture_registrar.h` 与 `flutter_export.h`），
开启 `LRDP_BUILD_TESTS` 后构建 `lrdp_windows_video_test`；CTest 会加入正常和失败
两种场景。Linux 可用匹配 Flutter 源码的 `shell/platform/common/public/` 目录，
MinGW 使用下载后的 Windows Debug 头文件。Linux 的 ASan/UBSan/LSan 验证只覆盖
这个原生缓冲适配层及其实际帧存储，不代表整个 Windows 引擎被内存检查器覆盖。

Wine 回归明确选择 FreeRDP/WinPR 内建 SSPI，验证固定指纹 TLS 上的 NLA 错误
密码拒绝和正确密码认证。`--sspi-provider=system` 可单独检查 Wine 原生 SSPI；
当前 Wine 11.20 的该路径返回 `SEC_E_INVALID_TOKEN`。应用在真实 Windows 上
仍默认使用系统 SSPI，此项互操作需要 Windows 原生系统验证。

MinGW 适配均在 LRDP 构建层：检测缺失的可选 `threads.h`、选择 WinPR 的
Windows 回溯后端，并仅对 FreeRDP 3.32.2 的 `locale/keyboard.c` 保留指针类型
警告而不作为错误，同时关闭该文件的严格别名优化。该处 `DWORD` 与 `UINT32`
在目标 ABI 均为 32 位，LRDP 自身仍使用严格诊断；升级上游后应重新审查此项。
背景见 [GCC 14 移植说明](https://gcc.gnu.org/gcc-14/porting_to.html#incompatible-pointer-types)
和 [Microsoft DWORD 定义](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-dtyp/262627d8-3418-4627-9218-4ffe110850b2)。

## Android

JDK 17、Android SDK 36、Build Tools 36.0.0、NDK r27 或更新版本、CMake 3.22.1。
确认 Flutter 实际选择的 JDK。Android Studio 的附带 JDK 可能优先于 `JAVA_HOME`；
本次构建可通过 `GRADLE_OPTS="-Dorg.gradle.java.home=/path/to/jdk17"` 指定 Gradle 使用 JDK 17。
OpenSSL 必须为每个 ABI 独立编译，不能链接主机库。脚本遵循
[OpenSSL 官方 Android 构建说明](https://github.com/openssl/openssl/blob/master/NOTES-ANDROID.md)。

```sh
export ANDROID_NDK_ROOT=/path/to/android-ndk
export LRDP_OPENSSL_SOURCE=/path/to/openssl-3-source
export LRDP_OPENSSL_ROOT="$PWD/build/deps/android-openssl"
bash scripts/build_android_openssl.sh arm64-v8a x86_64
bash scripts/build_ffmpeg.sh android-arm64 android-x64
export LRDP_FFMPEG_ROOT="$PWD/build/deps/ffmpeg/android"
LRDP_ANDROID_PREVIEW_SIGNING=1 flutter build apk --release --target lib/main.dart --target-platform android-arm64
```

从集成测试切换回主入口 Release 时，使用上述完整 `flutter build` 命令，不加 `--no-pub`，
让 Flutter 重新生成排除开发插件的注册代码，避免保留 Debug 的 `integration_test` 注册。

已构建并检查的 ABI 为 ARM64 与 x86_64；32 位 Android 尚未验收。
目录结构：`$LRDP_OPENSSL_ROOT/<abi>/include/openssl`、`<abi>/lib/libssl.a`、
`<abi>/lib/libcrypto.a`。只构建 ARM64 可加 `--target-platform android-arm64`。
应用和原生插件都按 Flutter 的 `target-platform` 参数过滤 ABI，防止单架构 APK
混入其他架构的辅助库。OpenSSL 和桥接层启用 16 KiB 页兼容；最终 APK 还需设备检查。
FreeRDP 的 Android 初始化使用应用私有目录，凭据不会存到这个协议目录。
桥接层使用 NDK 推荐的 `max-page-size=16384` 与 `common-page-size=16384`
链接选项，见 [Android 官方页大小说明](https://developer.android.com/guide/practices/page-sizes)。
安装包可使用以下命令检查；检查器同时核对 ABI、LOAD 段、RELRO 保护区、ZIP
对齐、签名、可调试标志和 Debug/Release 的 Dart 主入口，避免把集成测试 APK 当成应用预览包：

```sh
python3 scripts/check_android_apk.py build/app/outputs/apk/debug/app-debug.apk --abi arm64-v8a --build-mode debug
python3 scripts/check_android_apk.py build/app/outputs/apk/release/app-release.apk --abi arm64-v8a --build-mode release
python3 -m unittest discover -s scripts/tests -v
```

`LRDP_BUILD_JOBS=3` 可限制 Ninja 的原生编译并发；它也适用于 OpenSSL 构建脚本。
主应用跟随 Flutter 的 NDK 版本（本次为 28.2.13676358），以满足 JNI 依赖；
FreeRDP 桥接层默认使用 r27。可通过
Gradle 属性 `-Plrdp.ndkVersion=...` 覆盖桥接层版本。最低 Android API 24。
Release 构建必须显式选择签名：本地开发预览设置 `LRDP_ANDROID_PREVIEW_SIGNING=1`，
使用现有调试证书，APK 仍是不可调试的 AOT Release。正式签名通过环境变量注入
`LRDP_ANDROID_KEYSTORE`（密钥库文件）、`LRDP_ANDROID_KEY_ALIAS`、
`LRDP_ANDROID_STORE_PASSWORD` 和 `LRDP_ANDROID_KEY_PASSWORD`；不要同时开启预览签名。
未选择签名的 Release 任务会失败，Debug 开发构建不受影响。签名密码由 CI 密钥或进程环境
提供，不放入命令行、配置导出、日志或源码；密钥库不进入源码包。

Android 运行回归使用单独的 `LRDP_` 模拟器、ADB 5038 端口、私有桌面和回环
服务，不使用个人手机或当前桌面。需要 Linux 上的系统 FreeRDP 3.32.2 服务端
开发库、Xvnc、xsetroot、Python Pillow，以及 x86_64 OpenSSL 构建。示例：

```sh
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
export ANDROID_AVD_HOME="$PWD/build/android-avd"
export ANDROID_USER_HOME="$PWD/build/android-tool-config"
mkdir -p "$ANDROID_AVD_HOME" "$ANDROID_USER_HOME"
sdkmanager 'system-images;android-36;google_apis_ps16k;x86_64'
avdmanager create avd --name LRDP_API36_16k --device pixel_7 \
  --package 'system-images;android-36;google_apis_ps16k;x86_64'
ADB_SERVER_SOCKET=tcp:5038 adb start-server
ADB_SERVER_SOCKET=tcp:5038 ANDROID_ADB_SERVER_PORT=5038 emulator \
  -avd LRDP_API36_16k -port 5556 -adb-path "$ANDROID_SDK_ROOT/platform-tools/adb" \
  -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader \
  -memory 3072 -cores 4
```

保持模拟器运行，在另一个项目终端执行 `python3 scripts/run_android_test.py`。
脚本默认使用 `/usr/lib/jvm/java-17-openjdk`，其他安装位置可设置
`LRDP_JAVA_HOME`。它先构建独立的 x86_64 集成测试 APK，再检查实际 16 KiB
运行环境、Keystore、RDP 协议及手机流程。截图和日志位于
`build/android-runtime/`，只有全部通过才生成 `VERDICT.json`；测试 APK 不放入
分发目录。冷启动系统镜像可能需要数分钟，系统就绪与应用测试分开计时。

## Android 7.1 的独立兼容性回归

这项检查与上面的 API36 / 16 KiB 验收分别记录。使用独立
`LRDP_API25_x64` AVD、同一个专用 ADB 5038 端口和
`emulator-5556`，同一时刻只运行一个所选设备。不得把这些脚本指向个人手机。

```sh
avdmanager create avd --name LRDP_API25_x64 --device pixel_7 \
  --package 'system-images;android-25;google_apis;x86_64'
ADB_SERVER_SOCKET=tcp:5038 ANDROID_ADB_SERVER_PORT=5038 emulator \
  -avd LRDP_API25_x64 -port 5556 -adb-path "$ANDROID_SDK_ROOT/platform-tools/adb" \
  -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader \
  -memory 3072 -cores 4 -show-kernel
python3 scripts/run_android_video_test.py --device api25
python3 scripts/run_android_video_test.py --device api25 --reuse-apk --fail-gpu
python3 scripts/run_android_release_test.py /path/under/build/main-release.apk --device api25
```

延续前文的 `ANDROID_AVD_HOME` 与 `ANDROID_USER_HOME` 设置。必须先确认系统已
完成启动，脚本还会核对 AVD 名称、实际 API、x86_64、4 KiB 页和非 root 身份。
API25 镜像没有 `getconf` 时读取内核 `/proc/self/smaps` 的 `KernelPageSize`，
没有 `sha256sum` 时仅读取已安装 APK 的公开代码文件，在主机计算 SHA-256；
不使用 `run-as` 读取 Release 的应用私有数据。

旧系统在覆盖显示尺寸后，截图仍可能保持屏幕物理分辨率；像素核对由 WindowManager
的逻辑显示尺寸映射到截图，旋转后也会重新计算，不按颜色反推坐标。
UIAutomator 的 XML 通过 `/proc/self/fd/1` 返回，避免旧系统 `/dev/stdout` 不返回
界面树。空输入框没有提示字段时，主入口测试通过可见表单、五个编辑框与密码标志
确定字段次序；单个键盘输入框则通过当前模式的可见控件确定，仍使用系统触摸与
InputConnection 输入，不向应用数据目录写入配置或凭据。这不代表 TalkBack 已验收。

API25 报告位于 `build/android-api25-video-runtime/` 与
`build/android-api25-main-release-runtime/`。`--runtime-dir build/...` 可指定独立的
运行记录目录，例如回到 API36 后回归更新的测试工具，避免覆盖历史证据。
API25 的 x86_64 模拟器不能替代 API24 最低版本、ARM64 真机或实际 GPU 验收。

### 小屏与系统大字号

在专用 API36 AVD 上，可以使用实际 `lib/main.dart` 的 x86_64 Release APK
重复主入口流程，并检查 200% 字号下的横竖屏输入提示：

```sh
python3 scripts/run_android_release_test.py build/app/outputs/flutter-apk/app-release.apk \
  --font-scale 2.0 --small-phone --runtime-dir build/android-large-text-main-release-runtime
```

沿用上面的 Android 构建环境，以 `--target-platform android-x64` 构建该 APK。
`--small-phone` 临时设置 720×1280 / 360 dpi，即 320×568 逻辑尺寸，关闭自动旋转，
并通过至少占 160 dp 高度的隔离系统输入法和系统触摸，在横竖屏检查模式切换、
提示与收起按钮。旋转后点按“显示键盘”重新打开输入法，以覆盖输入法展开的布局。
字号、显示尺寸/密度和
旋转设置在退出时恢复；仍只接受允许列表内的自有 AVD、ADB 5038 / emulator-5556。
API36 默认流程目前共 12 项，包含默认 Unicode 和保持键；两参数一起使用时增加两项布局流程。
这不代替 TalkBack、真实厂商输入法或实体手机验收。

键盘与画面同时操作的验收可在 API36 主入口命令中追加 `--verify-ime-control`：

```sh
python3 scripts/run_android_release_test.py build/chinese-input-main-release/lrdp-main-x86_64-release-preview.apk \
  --verify-ime-control --runtime-dir build/android-chinese-input-runtime
```

它分别在文字输入和键盘模拟模式下，通过 Android 系统分发点击、右键、滚轮、
按住拖窗与释放，独立核对远端 X11 事件，并检查输入法持续可见且随后仍可输入。
模拟模式必须没有可见 EditText，系统返回键收起后再用“显示键盘”重新打开。
该参数增加两项流程：API36 普通字号共 14 项；同时使用 `--font-scale 2.0 --small-phone`
时共 16 项，大字号提示出现后也须保留远程画面区域。只操作允许列表中的自有 AVD。

## macOS / iOS

必须在有 Xcode、CocoaPods、CMake、Ninja 的 Mac 上构建。先为每个
SDK/架构准备静态 OpenSSL 3：

```
$LRDP_OPENSSL_ROOT/macosx-arm64/{include,lib}
$LRDP_OPENSSL_ROOT/macosx-x86_64/{include,lib}
$LRDP_OPENSSL_ROOT/iphoneos-arm64/{include,lib}
$LRDP_OPENSSL_ROOT/iphonesimulator-arm64/{include,lib}
$LRDP_OPENSSL_ROOT/iphonesimulator-x86_64/{include,lib}
```

```sh
bash scripts/build_ffmpeg.sh macosx-arm64 macosx-x86_64 \
  iphoneos-arm64 iphonesimulator-arm64 iphonesimulator-x86_64
export LRDP_FFMPEG_ROOT="$PWD/build/deps/ffmpeg/apple"
bash scripts/build_apple.sh macos
bash scripts/build_apple.sh ios
flutter build macos --release
flutter build ios --release --no-codesign
```

脚本在 LRDP 的构建目录里编译上游，再生成独立 XCFramework；Podspec 负责
嵌入。它不修改 FreeRDP。最低 macOS 11 / iOS 15。当前脚本尚待 Mac 验证。
如 Flutter 默认启用 Swift Package Manager 而没有发现 Podspec，请在当前
工程 `pubspec.yaml` 的 `flutter.config` 配置 `enable-swift-package-manager: false`。
配置 Team/签名、Keychain Sharing 和局域网权限后进行真机测试。

## 更新 FreeRDP

可运行 `bash scripts/update_freerdp.sh 3.x.y`，将参数替换为已经审查的版本。
脚本先检查子模块没有本地修改，再获取明确的标签并切换指针，不修改源码。
等效手动步骤：

```sh
git -C third_party/FreeRDP fetch origin --tags
git -C third_party/FreeRDP checkout --detach <已审查的版本标签>
git add third_party/FreeRDP
```

随后重跑原生构建、协议测试与 Flutter 测试，审查新版本通道/证书 API 和
上游安全公告。改动仅应是子模块指针及 LRDP 自己的适配代码。

原生桥接采用 Flutter FFI 插件的显式平台构建，用于整合 FreeRDP 的完整 CMake
依赖图与 Apple 框架打包。其 Dart 层仅依赖稳定 C ABI，后续可迁移到
[Flutter build hooks](https://docs.flutter.dev/platform-integration/bind-native-code)。


当前桥接 ABI 为 v5。Dart 启动时检查版本；更新 LRDP 后需要同步重建对应平台
的原生库，不能将旧 `liblrdp.so` / `lrdp.dll` / LRDP framework 与新 Dart 代码混用。
恢复逻辑在 LRDP 层实现，不修改 FreeRDP，也不启用上游自动重连 Cookie。

光标协议夹具需要与文件夹具相同的 FreeRDP server/core/WinPR 开发库；它仅使用
独立回环 TLS，不读取当前桌面。Windows 核心构建脚本也构建
`lrdp_cursor_test.exe`；先运行 Windows WinPR 回归，再运行
`python3 scripts/run_cursor_test.py --wine`、`python3 scripts/run_paste_test.py --wine` 及 `python3 scripts/run_audio_test.py --wine`。Windows 核心打包脚本同时核对四份
通过报告中的 DLL 哈希，防止新光标接口只验证导出而未执行真实协议。

## FFmpeg 与源码分发

`scripts/fetch_ffmpeg.sh` 校验官方 FFmpeg 9.0.2 压缩包的固定 SHA-256；固定该摘要前已用
官方发布密钥验证签名。构建脚本仅开启 H.264 解码/解析及 avcodec、avutil、swscale，
关闭网络、程序、GPL、nonfree、硬件加速及自动探测。安装前缀包含配置和静态库哈希。
`LRDP_WITH_H264=OFF` 可显式关闭解码，但只支持 H.264 的服务将无法显示桌面。
Apple 构建步骤仅完成脚本接入，仍需在 Mac 实际验证；MSVC 也需匹配架构和工具链。

桥接库保持 ABI v5，当前有 26 个导出；包含五个原生帧读取接口与两个新增图片剪贴板接口，旧接口签名保持兼容。
Linux/Android 原生纹理需要匹配的平台插件与新库；没有可用纹理后端时继续使用兼容画面路径。
粘贴协议验收包含成功、提前请求数据、拒绝、无确认、无数据及取消六种情况：
`run_paste_test.py` 的 `--flutter`、`--asan`、`--wine` 分别运行 Flutter、内存检查和 Windows PE 客户端。

图片剪贴板不增加外部 Flutter 依赖，平台通过 `dev.lrdp/clipboard_image` 交换有界图片数据，
原生 CLIPRDR 代码仍在 `native/`。FreeRDP 子模块保持原样。功能位 `16` 表示适配器提供图片接口，
不代表服务端或远程目标应用接受图片。Dart 按功能位延迟查找新增符号；构建分发时仍应保持完整应用、插件与原生库匹配。

```sh
cmake --build build/native --parallel 3
ctest --test-dir build/native --output-on-failure
flutter test
python3 scripts/run_image_clipboard_test.py
python3 scripts/run_image_clipboard_test.py --flutter
python3 scripts/run_linux_clipboard_test.py
# 主入口 Release 构建后，用实际安装库复验协议：
python3 scripts/run_image_clipboard_test.py --library build/linux/x64/release/bundle/lib/liblrdp.so
python3 scripts/run_image_clipboard_test.py --large --library build/linux/x64/release/bundle/lib/liblrdp.so
```

图片协议测试生成独立 PNG/DIB 金样，在私有回环 TLS 核对格式、数据、按键、拒绝/超时/取消、
反向接收和过期响应；Flutter 模式另验证生产 worker 和实际菜单入口，操作系统剪贴板在该测试中被替代。
Linux 系统测试另起私有 Xvnc，独立 GTK 进程提供/读取图片，运行实际平台插件，
不读取个人桌面或剪贴板。Android 设备可运行 `integration_test/clipboard_image_test.dart`，
验证真实 ClipboardManager/FileProvider 的重复读写；结果不能替代 ARM64 真机或远程服务端互操作验收。
在已启动且核对过的隔离 AVD 上，可运行 `python3 scripts/run_android_clipboard_test.py --device api25`
或选择 `api36`；脚本固定使用 ADB 5038 / emulator-5556，核对设备白名单，安装/清理集成 APK。
不要与同一 Android 工程的 Release 构建同时运行。

```sh
python3 scripts/package_source.py
```

将生成的 `*-source.tar.gz` 与二进制及许可证一同保留。它包含应用完整源码、未修改的
FreeRDP 快照、FFmpeg 精确源码压缩包及构建配置，支持替换 FFmpeg 后重建/重新链接。
源码包已展开 FreeRDP，不含 Git 元数据，按根目录 `README-SOURCE.txt` 跳过子模块初始化。
发布前仍需配置自己的签名；当前 Android 包使用调试签名。

## 远程声音后端

`LRDP_WITH_AUDIO` 默认开启。平台后端通过上游的构建选项接入，不修改源码：
Linux 为 PulseAudio（需要 libpulse 开发库及兼容的声音服务），Windows 为 WinMM，
Android 为兼容最低 API 24 的 OpenSL ES；Apple 后端仍待 Mac 实测。
连接配置默认静音，开启时注册真正的 rdpsnd 通道；仍禁用麦克风。
播放缓冲设为 250 ms，以避免小缓冲在一般调度抖动下丢弃样本；这不是实机延迟保证。

`run_audio_test.py --build build/native` 需要 PulseAudio、pactl、parec、dbus-run-session
和同文件夹内的 `lrdp_audio_test`。测试创建独立 D-Bus、PulseAudio null sink，
不加载任何硬件模块，也不触碰现有声音服务。它验证精确指纹 TLS 上的 RDPSND 格式协商，
录回 48 kHz 双声道合成信号，检查有效样本数、500/1000 Hz 幅度与串音，
以及关闭播放、同时开启 RDPDR 和无共同格式时的连接状态。
`--wine` 使用已有的 LRDP 私有 Wine 前缀并将其音频驱动固定为私有 Pulse 端点；
不会使用个人 Wine 配置或硬件输出。ASan 构建可用 `--build build/native-asan` 验证。


声音生命周期由 LRDP 自己的设备代理控制，静态和动态 RDPSND 都经过同一个会话门控。
ABI v5 新增 `lrdp_audio_active`，`lrdp_read` 字段 4 提供声音状态；旧的 ABI v4 库需同步重建。
只有前台选中的活动会话允许播放。Android 还需获得系统音频焦点；失去焦点、退到后台、
返回电脑列表或关闭会话时清空待播数据并释放设备，回到会话后继续接收新的音频。
OpenSL ES 前增加有上限的 PCM 预缓冲、约 50 ms 分块与 PCM8 转 PCM16，防止不均匀网络分块
反复启停播放器；待提交数据最多 500 ms，溢出丢弃最旧完整帧。

声音协议测试还包含 PCM8、动态 RDPSND 和暂停/恢复：用不同频率标记暂停期间的数据，
确认暂停时静音、恢复后播放新数据而不重播旧数据，并检查关闭后没有残留播放设备。
Android 专项回归使用 `python3 scripts/run_android_audio_test.py`，仅连接脚本校验过的
私有 API 36 / x86_64 / 16 KiB 模拟器（默认 ADB 5038、emulator-5556、LRDP_API36_16k）。
它运行实际 WorkspaceScreen、RDP worker、Keystore 和系统音频焦点，另安装临时的焦点测试服务；
通过系统播放器状态、LRDP 自身音轨帧计数和欠载计数检查播放与释放。宿主禁用声音输出，
不等同于手机扬声器听测、ARM64 真机或长时间锁屏/路由切换验收。


## Android 系统输入手势验收

在已启动的专用 `LRDP_API36_16k`、ADB 5038、emulator-5556 上运行：

```sh
python3 scripts/run_android_gestures_test.py
# 仅复用已核对 APK 哈希、项目编译输入和原生依赖库的测试包：
python3 scripts/run_android_gestures_test.py --reuse-apk
```

脚本另建一个只绑定回环地址的 2560×1600 X11/RDP 桌面，用可见坐标网格检查真实图像。
主机驱动通过 ADB shell 调用 Android 系统输入接口，发送多指 MotionEvent；测试入口开启
设备事件分发，操作实际 WorkspaceScreen、RemoteSurface 和 RdpSession worker。
WidgetTester 负责准备连接和打开“适应屏幕”，待验收的手势全部由 Android 系统分发。
测试工具位于 `native/tests/android_gestures/`，不加入应用 APK 或 FreeRDP 子模块。

覆盖捏合、边缘跟随、双指/长按右键、横竖双向滚动、双击拖拽、取消、拖拽中后台/旋转/
返回列表、边界约束及鼠标悬停边缘平移。独立 X11 连接核对实际按钮事件、按住左键的移动、
释放坐标和最终按钮状态；原有 TCP 连接的端点与 inode 用于确认返回会话没有重连。
验证结果和系统截屏保存在 `build/android-gestures-runtime/`，测试 APK 不进入下载包。

当前覆盖 19 场景 / 41 阶段，还检查返回列表后的缩放、光标与操作模式。
`SESSION_VIEW_PROOF.json` 对照离开前的实时变换、恢复后的变换、客户端发送坐标及
远端实际按钮事件；`mode-return.json` 对照触屏/平移模式。测试入口只在独立 APK 中
被动观察真实 `RdpSession.mouse` 调用，生产 worker 和 FreeRDP 连接保持原实现。
触摸设备在按下前补发的悬停事件也进入诊断轨迹，应保持触控板光标不变。

横向滚轮正值在 Windows 表示向右，负值表示向左，见
[微软 MOUSEINPUT 说明](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-mouseinput)。
此处未修改的 FreeRDP X11 shadow 后端把正值映射为按钮 6、负值映射为按钮 7；
脚本按该后端的源码映射核对接收事件。Windows 页面的实际滚动方向、触摸硬件手感和
ARM64 手机仍需对应设备验收。


鼠标场景使用 `native/tests/android_gestures/uinput_mouse.c` 创建临时内核输入设备。
专用调试 AVD 需要允许 `adb root` 和 `/dev/uinput`；脚本按需开启 adbd root，结束后恢复
原状态，并销毁鼠标设备。应用权限保持交付版配置。触摸由系统输入接口注入，鼠标由
内核输入设备生成真实 HOVER_MOVE；主机根据系统记录的光标坐标做闭环移动，处理系统加速。
运行这些验收工具需要 Git 工作区；源码展开包可直接构建应用，验证脚本的输入指纹依赖 Git。

## 断开时释放输入与堵塞取消

```sh
python3 scripts/run_input_stop_test.py
python3 scripts/run_input_stop_test.py --build build/native-asan
python3 scripts/run_input_stop_test.py --wine
python3 scripts/run_input_stop_test.py --library build/linux/x64/release/bundle/lib/liblrdp.so
```

先构建对应目录的 `lrdp_input_stop_test`。脚本只启动回环 TLS 服务，不操作用户桌面。
服务端收到六种扫描码、重复按下、已释放按键、中文和表情 UTF-16 单元及三个鼠标键后，
通过 RDP 指针位置回执确认；客户端随后关闭，服务端核对每项释放次数、位置及修饰键顺序。
另一个场景在回执后停止读取 TCP，实际填满客户端输入队列，检查重复取消、拒绝迟到输入
以及关闭并销毁在两秒内完成。正常情况下释放输入；传输堵塞时只能保证本地及时结束。
500 ms 为输入释放宽限，真实关闭时间还包括线程调度和资源回收，并非硬实时保证。

服务端先按 KRDP 的 `DOWN → MOVE → RELEASE` 优先级解析实际收到的鼠标 PDU，
检查拖动松开后还能连续左/右/中键点击，按钮坐标准确；移动和按钮变化必须分开发送。
这也覆盖断开时的按钮释放。堵塞用例保留队列连续满 300 ms 与两秒关闭上限；
填满 Wine TCP 缓冲的准备时间最多 20 秒。

报告与双方日志位于 `build/input-stop-runtime/{native,asan,wine,native-custom}/`，
报告包含实际库的 SHA-256。ASan 检查适配层；Wine 检查 Windows PE 核心，均不代替真机。

## Linux 系统鼠标回归

```sh
flutter build linux --release --target lib/main.dart --no-pub
python3 scripts/run_linux_mouse_test.py
```

需要 Xvnc、xdotool、xsetroot、dbus-run-session、FreeRDP shadow 服务和 Pillow。
脚本启动两个私有 X11 显示，运行真实 `lib/main.dart` Release，使用独立配置和 D-Bus；
通过系统鼠标连接私有 RDP，在服务端移动真实 X11 窗口。核对松手后窗口停止移动、
后续左/右/中键、Esc 后点击，以及同时按住两键时先松开一键的状态。
不访问当前桌面或公网服务。报告、真实服务端事件与截图在 `build/linux-mouse-runtime/`。
该窗口测试使用 X11 shadow；KRDP 的解析优先级由上一节的 TLS 对端单独核对。

打包可用 `LRDP_DISTRIBUTIONS_DIR` 指定独立输出目录，适用于 Linux 包和对应源码包，
避免覆盖上次完整发布快照。


## Linux 原生纹理

Linux 插件同时使用 FFI 和 Flutter 平台插件；需要 GTK3、libepoxy 与 EGL/OpenGL。
通过正常 Flutter 构建注册插件，保持 `liblrdp_native_plugin.so` 与 `liblrdp.so`
一同位于 bundle/lib，保留插件的 `$ORIGIN` RUNPATH。不要只更新其中一个库。
Linux 默认使用原生 BGRA 上传，GL 不支持或上传失败后自动切回兼容显示；
手动选择兼容显示可执行 `LRDP_DISABLE_TEXTURES=1 ./lrdp`。

```sh
flutter analyze --no-pub
flutter test --no-pub
python3 scripts/run_native_video_test.py
python3 scripts/run_native_video_test.py --fail-gpu
LRDP_FFMPEG_ROOT="$PWD/build/deps/ffmpeg/linux-x64" \
  CMAKE_BUILD_PARALLEL_LEVEL=3 flutter build linux --release --target lib/main.dart --no-pub
python3 scripts/run_linux_mouse_test.py
python3 scripts/run_input_stop_test.py --library build/linux/x64/release/bundle/lib/liblrdp.so
LRDP_DISTRIBUTIONS_DIR="$PWD/build/distributions/native-video" bash scripts/package_linux.sh
LRDP_DISTRIBUTIONS_DIR="$PWD/build/distributions/native-video" python3 scripts/package_source.py
```

两个纹理用例都在独立私有 X11 显示和回环 RDP 服务上运行，不访问个人桌面。
测试截图来自实际系统窗口；CPU 故障回退注入仅在 Debug 有效，Release 不编入该钩子。
正常路径核对颜色、AND/XOR、缩放、隐藏/恢复、视图重建与三次重连；故障路径还要求
实际观察到上传失败，重复重连后只保留一个引擎共享占位图。两种路径均核对每会话
纹理/上下文/读取句柄释放。报告在 `build/video-ui{,-fallback}-runtime/VERDICT.json`。
原生 CTest 新增 `video_store`，覆盖并发借用、尺寸/步长、失败重试及连接关闭后读取。

Linux 阶段的原生纹理快照只包含 Linux 后端；Android 后续实现见下一节，
Windows/Apple 仍使用原画面路径。输入修复的旧 Android APK 快照在 `build/distributions/input-refinement/`，其构建与设备报告
继续只对应原哈希。本次 Linux 纹理快照不会替换或冒充已验收的 Android 安装包。


## Android 原生 Surface

Android FFI 插件也注册 `LrdpNativePlugin`，桥接库额外链接系统 android/EGL/GLESv2。
无需修改 FreeRDP，不增加应用权限。Java 与 Dart 复用同一个 liblrdp.so；
保持原生库、插件 Java 和 Dart 代码同步构建，不能只替换其中一部分。

使用现有私有 API36 / x86_64 / 16 KiB AVD、ADB 5038、emulator-5556：

```sh
python3 scripts/run_android_video_test.py
python3 scripts/run_android_video_test.py --reuse-apk --fail-gpu
python3 scripts/run_android_gestures_test.py
```

视频测试使用 Debug 集成入口、实际回环 RDP 与 Android 系统截图，包含颜色角标、
光标 XOR、缩放、Surface 重建、隐藏/恢复、后台内存清理信号、旋转和重复重连。
`--reuse-apk` 严格核对编译输入和 APK 摘要；修改应用或渲染源码后必须重新构建。
通过 `--keep-app-running` 先保留结果文件，再由测试清理回调停止应用。
运行报告分别位于 `build/android-video-runtime/{native,fallback}/VERDICT.json`。

手势测试现在从真实 Android 合成画面核对远端初始颜色，使用 native 图像尺寸元数据；
不以 Dart RawImage 是否存在判断收到桌面。鼠标工具对 InputDispatcher 的自然方向
历史坐标应用系统提供的显示矩阵，再与横屏截图/Flutter 坐标比较；远端坐标与释放
断言保持不变。完整手势测试的内核鼠标只使用专用调试 AVD 的临时 root，结束后恢复。
主入口 Release 输入验收继续要求无 root、非 debuggable、无私有配置预填。

CPU 兼容构建使用 `--dart-define=LRDP_DISABLE_TEXTURES=true`。历史四用例 Android
运行套件显式启用该构建选项，保留 Dart 图像采样、文件、Keystore 和故障恢复覆盖；
不能将它当作默认原生 Surface 的截图证据。常规客户 Release 不设置该选项。
已实现 Android Surface 后端；ARM64 真机、较低 Android API、不同设备 GPU 和物理
网络下的功耗/帧延迟仍需各自验收。模拟器软件 GPU 不代表实体设备的硬件加速性能。

### 中文发送修复包回归

“文字输入”默认走协商后的 Unicode 键盘输入；“粘贴输入”显式走 CLIPRDR 和 Ctrl+V。

```sh
python3 scripts/run_paste_test.py --flutter
python3 scripts/run_android_release_test.py build/chinese-input-main-release/lrdp-main-x86_64-release-preview.apk --verify-ime-control --runtime-dir build/android-chinese-input-runtime
```

前者包含直接中文/UTF-16 代理对、服务端不开放 Unicode 时保留草稿，以及原有粘贴/取消场景。
后者在原有主入口 Release 验收中另外核对默认 Unicode 数据流、显式粘贴及模式重新打开后的保留，
并通过系统按键栏验证保持 Ctrl + 输入法空格、Shift 连续输入、F1/F12 和收起时释放 Alt；
只允许工作区自有 API36 x86_64 AVD（ADB 5038 / emulator-5556），不会操作个人设备。
