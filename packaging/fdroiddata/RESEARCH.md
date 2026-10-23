# F-Droid 提交可行性研究报告（LRDP）

- 目标应用：`dev.lrdp.lrdp`，LRDP 0.2.0（versionCode 5），提交 commit `98b86ecfc7bb84b1a05d4185714b58bfdd3574d3`（tag `v0.2.0-preview.1`）
- 上游仓库：<https://github.com/lucinhu/LRDP>（已公开，Anonymous HTTPS clone 已验证）
- 报告日期：2026-10-23
- 结论：**metadata 与 fastlane 素材已就绪，本地 `fdroid lint` 通过（exit 0，无 app 级 warning）。F-Droid 构建方案在现有 fdroiddata/buildserver 机制下可行，但首次构建必须在 F-Droid buildserver 上验证（本地未做完整 Android 构建）。主要风险是 buildserver 资源/超时与首次 universal 2-ABI APK 验证，而不是字段正确性。**

---

## 1. 交付物清单

| 文件 | 说明 |
| --- | --- |
| `packaging/fdroiddata/dev.lrdp.lrdp.yml` | 可直接放入 `fdroiddata/metadata/dev.lrdp.lrdp.yml` 的完整 metadata（`fdroid rewritemeta` 规范化后的格式） |
| `fastlane/metadata/android/en-US/short_description.txt` | 70 字符，≤80，无结尾句点（`Lightweight RDP client with touch gestures, keyboard and file transfer`） |
| `packaging/fdroiddata/dev.lrdp.lrdp/en-US/summary.txt` | 70 字符 Summary；2026 年 fdroiddata 约定 Summary 放 per-locale 目录，YAML 不再写 `Summary:` |
| `fastlane/metadata/android/en-US/full_description.txt` | 英文纯文本功能说明（1860 字节，≤4000） |
| `fastlane/metadata/android/en-US/changelogs/5.txt` | 348 字节（≤500 = F-Droid whatsNew 上限），对应 versionCode 5 |
| `fastlane/metadata/android/en-US/images/icon.png` | 512×512 RGBA PNG（取自 `assets/branding/lrdp-512.png`） |
| `fastlane/metadata/android/en-US/images/phoneScreenshots/1..5.png` | 720×1600 PNG（workspace / fullscreen toolbar / keyboard / IME control / files），无 DEBUG 角标、无敏感信息 |
| `build/fdroid/lint-output.log` | `fdroid lint dev.lrdp.lrdp` 原始输出（exit 0） |
| `build/fdroid/rewritemeta-output.log` | `fdroid rewritemeta dev.lrdp.lrdp` 原始输出（exit 0） |
| `build/fdroid/lint-selfcheck.log` | 反向自检：故意写坏字段后 lint 报错的原始输出 |
| `build/fdroid/scan-output-raw.log` | 对 tag 源码 + FreeRDP submodule 跑 fdroidserver scanner 的原始输出（FATAL_PROBLEMS: 0） |
| `build/fdroid/research/` | 保存的 fdroiddata 模板、srclib、buildserver provision 脚本等参考资料 |
| `docs/fdroid-report.md` | 面向项目维护者的简明报告 |

> fastlane 目录已由 Lead 提交到上游 `main`（commit `4158f541b92cbc45387ce51da71d9a14a6eed95c`），F-Droid 的 `fdroid update` 会从构建源码树里的 `fastlane/metadata/android/<locale>/` 读取摘要/描述/截图/changelog（fdroidserver `update.py` 的 `insert_localized_app_metadata()`/`_parse_triple_t_metadata()`）。

---

## 2. metadata 关键决策与依据

### 2.1 Flutter 构建方式：srclib（选定）vs submodule

fdroiddata 官方模板 `templates/build-flutter.yml` 同时给出两条路：把 Flutter 作为 **submodule**，或用 **srclib** `flutter@<tag>`；两者都要求 `output:` 且不写 `gradle:` 字段（否则 fdroidserver 会走 gradle 主构建，Flutter 项目会失败）。

选定 **srclib**：`srclibs: [flutter@3.47.7]`

- `fdroiddata/srclibs/flutter.yml` 已存在（`RepoType: git`，`Repo: https://github.com/flutter/flutter.git`），MR **不需要新增 srclib 文件**。
- F-Droid 会先 `fdroid fetchsrclibs` 把 flutter 仓库 clone 到 `build/srclib/flutter` 并 checkout 指定 ref；`$$flutter$$` 在 prebuild/build 命令里被替换成该绝对路径（`fdroidserver/common.py: replace_config_vars()` / `getsrclib()`）。
- 版本来源：`.github/workflows/check.yml:19` 的 `flutter-version: '3.47.7'`。flutter 3.47.7 稳定版存在（tag commit `abaf9c523780a608bd46686fd5e53740a07077f8`），满足 `pubspec.yaml` 的 `sdk >=3.11.0 <4.0.0`、`flutter >=3.41.0`。
- 已通过 raw.githubusercontent.com 核实 flutter 3.47.7 的 `packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt`：`compileSdkVersion = 36`、`minSdkVersion = 24`、`targetSdkVersion = 36`、`ndkVersion = "28.2.13676358"`，与本项目 gradle 配置一致。
- 不选 submodule：需要 upstream 额外提交一个 Flutter submodule（体积巨大、审核不现实），而 srclib 已能 pin tag 并复现；两者对 F-Droid 等价。

**prebuild（export 在同一个 `bash -c` 里生效，fdroidserver 会把多行命令拼成 `bash -e -u -o pipefail -x -c 'a; b; c'`）**：

```yaml
prebuild:
  - export ANDROID_HOME=$$SDK$$
  - export ANDROID_SDK_ROOT=$$SDK$$
  - export PATH=$$flutter$$/bin:$PATH
  - flutter config --no-analytics
  - sdkmanager "platforms;android-36" "build-tools;36.0.0" "cmake;3.22.1"
  - flutter pub get  # 不用 --enforce-lockfile：与 Flutter 3.47.x 的 pub 解析不兼容（Would change 5 dependencies）
```

- Flutter SDK 保持在 `build/srclib/flutter`（**不移动进应用目录**），因此 `$PUB_CACHE` 默认在 `/home/vagrant/.pub-cache`、Flutter 的 `.flutter/bin/cache` 也不在扫描目录内 → **不需要** `scanignore`/`scandelete`（见 2.7）。PocketSense 等较新 recipe 同样是 SDK 不落在应用目录内的做法。

### 2.2 F-Droid buildserver 环境差异

现行 buildserver 是 **Debian trixie Docker 镜像**（`buildserver/Dockerfile`），`vagrant` 用户 + 无密码 sudo，`ANDROID_HOME=/opt/android-sdk`；构建期**允许联网**（Flutter recipe 本身依赖 pub.dev / storage.googleapis.com；`common.auto_install_ndk` 也走网络）。

| 项目 | buildserver 现状 | 本项目需要 | 处理 |
| --- | --- | --- | --- |
| Java | `default-jdk-headless`（trixie = OpenJDK 21） | gradle compileOptions Java 17，AGP 8.12.1 + Gradle 8.14 支持 JDK 21 | 直接用；若构建机 Java 变化，`sudo:` 里可加 `openjdk-17-jdk-headless` |
| Android SDK | 只预装 `tools;25.2.5`；`/opt/android-sdk` 对 vagrant 组可写、licenses 已写入 | platform 36 / build-tools 36.0.0 / cmake 3.22.1 | prebuild 里 `sdkmanager "platforms;android-36" "build-tools;36.0.0" "cmake;3.22.1"`（已有 recipe 先例：`app.dumdum.yml`、`app.knotwork.android.yml`、`cc.narumi.chaldea.fdroid.yml`） |
| NDK | 镜像不预装版本；fdroidserver 按 metadata `ndk:` 自动 `sdkmanager` 安装（`build.py:466` → `common.auto_install_ndk()`），随后 `local.properties` 写入 `ndk.dir` | 28.2.13676358（Flutter 3.47.7 默认；`packages/lrdp_native` 默认 27.0.12077973 需覆盖） | `ndk: 28.2.13676358`；build 期 `export "ORG_GRADLE_PROJECT_lrdp.ndkVersion=28.2.13676358"` 让子工程用同一 NDK（Gradle 以 `ORG_GRADLE_PROJECT_<prop>` 环境变量注入 project property） |
| make / perl / nasm / xz / pkg-config | provision 脚本未安装；`xz-utils` 甚至被 purge | OpenSSL 需要 perl+make；FFmpeg 需要 make+nasm（x86_64 汇编，否则 configure 报 “nasm/yasm not found or too old”）；`fetch_ffmpeg.sh` 用 `tar -xJf` 需要 xz；FreeRDP `find_package(ZLIB)` 保险用 pkg-config | `sudo:` 里 `apt-get update && apt-get install -y build-essential nasm xz-utils perl pkg-config`（recipe 的 `sudo:` 以 root 执行，随后 root 被锁） |
| Gradle | `/usr/local/bin/gradle` = gradlew-fdroid wrapper；`~/.gradle/gradle.properties` 关闭 daemon 与自动下载 JDK | 项目 `android/gradle.properties` 有 `-Xmx8G -XX:MaxMetaspaceSize=4G` | 见 §5 风险；AGP/Gradle 一般不会真的占满，必要时 fallback 是 buildserver 资源或调低堆（需评估/授权） |
| 签名 | F-Droid 构建通过后由 F-Droid 统一重签名 | `android/app/build.gradle.kts` 的 `validateLrdpReleaseSigning` 要求 preview keystore 或 4 个 keystore env | build 期 `export LRDP_ANDROID_PREVIEW_SIGNING=1`（debug keystore 由 AGP 在 `$HOME/.android/` 自动生成）；F-Droid 之后重签名，可行 |

### 2.3 静态 OpenSSL 3 的来源（选定方案 A：srclib）

- 仓库脚本 `scripts/build_android_openssl.sh` 的接口要求外部提供 **OpenSSL 源码目录**：`LRDP_OPENSSL_SOURCE`（必需）、`ANDROID_NDK_ROOT`（必需，r27+），输出到 `LRDP_OPENSSL_ROOT`（默认 `build/deps/android-openssl`），按 ABI 生成 `arm64-v8a` / `x86_64` 的 `include/openssl/ssl.h`、`lib/libssl.a`、`lib/libcrypto.a`，`-D__ANDROID_API__=24`、`no-shared`。
- 因此 **复用 fdroiddata 已有 srclib**：`srclibs/OpenSSL.yml`（`https://github.com/openssl/openssl.git`），metadata 写 `OpenSSL@openssl-3.5.9`（tag 存在；2026-10 最新 3.5.x 线），build 期 `export LRDP_OPENSSL_SOURCE=$$OpenSSL$$` 后调用脚本即可。**upstream 不需要改任何代码/脚本**。
- 放在 `build:` 阶段编译（在 scanner 之后）是刻意的：scanner 会把 `*.a` 当 fatal problem（`fdroidserver/scanner.py`），放到 scanner 之后编译就绕开了；`com.limelight.yml` 等 recipe 同样在 build 阶段编译 OpenSSL。

### 2.4 静态 FFmpeg 9.0.2 的来源（选定方案 A：build 期下载官方 tarball + sha256）

- `scripts/fetch_ffmpeg.sh` 已固定 `9.0.2` 与 sha256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`，用 `curl --fail --location --retry 2` 下载 `https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz` 后 `sha256sum --check`，再 `tar -xJf` 解包；`scripts/build_ffmpeg.sh` 用 NDK Clang 交叉编译静态 h264 解码器（`--disable-gpl --disable-nonfree --disable-version3` → LGPL-2.1-or-later）。
- F-Droid 允许 build 期联网；fdroiddata 中 218 个 recipe 在 prebuild/build 里用 `curl` 下载，部分带 sha256 校验（如 `app.hkTransport.yml`、`app.intra.yml`）。URL + sha256 固定 → 可复现、合规。
- 备选 B（推荐 upstream 远期做，非阻塞）：给 `scripts/fetch_ffmpeg.sh` 增加 `LRDP_FFMPEG_SOURCE` 环境变量（指向已解包源码目录，缺省仍走下载+校验）。这样未来 metadata 可改用 fdroiddata 里**已存在**的 `srclibs/FFmpeg.yml`（`FFmpeg@n9.0.2`），把源码来源 pin 到 git，去掉对 ffmpeg.org 单点的构建期依赖。当前方案 A 不需要 upstream 改动。
- 备选 C（不选）：再给仓库加 FFmpeg/OpenSSL submodule，体积/审核收益都差。

### 2.5 签名

- `android/app/build.gradle.kts` 的 `validateLrdpReleaseSigning` 在 `preReleaseBuild` / `compileFlutterBuildRelease` / `validateSigningRelease` / `packageRelease` 前执行，要求 `LRDP_ANDROID_PREVIEW_SIGNING=1` 或 4 个 keystore env。
- recipe build 首行 `export LRDP_ANDROID_PREVIEW_SIGNING=1` → release APK 用 debug keystore 签名，**只用于 F-Droid buildserver 内部产物**；F-Droid 发布前会用它自己的 key 重签名（这是 F-Droid 标准流程），不会使用我们的 debug 签名。
- keystore 不进入仓库、不进入元数据。

### 2.6 APK 形态、versionCode、output

- **universal 2-ABI APK（arm64-v8a + x86_64）**，单条 Build，`versionCode: 5`（= `pubspec.yaml` 的 `0.2.0+5`）。
- 构建命令：`flutter build apk --release --target-platform android-arm64 --target-platform android-x64`（无 `--split-per-abi`）。
  - Flutter tool 会把多个 `--target-platform` 汇总成 `-Ptarget-platform=android-arm64,android-x64`（flutter_tools `gradle.dart`），本项目 `android/app/build.gradle.kts` 读取 `target-platform` 属性后设置 `ndk.abiFilters`，因此一个 APK 内含两个 ABI。
  - 无 split 时输出固定为 `build/app/outputs/flutter-apk/app-release.apk`（`output:` 已设为该路径），APK versionCode 即 pubspec 的 5，满足 fdroidserver 的 `Builds.versionCode == APK versionCode` 校验（`build.py:820-825`）。
- **为什么不用 `--split-per-abi`**：Flutter plugin 在 split 模式下会写 `output.versionCodeOverride = abiVersionCode * 1000 + versionCode`（`FlutterPlugin.kt`），APK 文件名变成 `app-<abi>-release.apk`，需要 per-ABI 的多个 Build 条目 + `VercodeOperation: %c*10+N` 体系；而单条 Build 的 `versionCode: 5` 会与 split APK 的 1005/2005/3005 不一致，构建校验直接失败。universal 方案字段更少、语义更清楚。
- **32 位 armeabi-v7a 不上报**：`docs/BUILDING.md` 明确只实测了 ARM64 与 x86_64（32 位未验证）；F-Droid 不应对用户提供未验收的 ABI。
- 回退方案（如果 F-Droid 首次构建发现 Flutter 多 ABI 单 APK 行为不符）：拆成 2 条 Build 条目 + `flutter build apk --release --split-per-abi --target-platform android-arm64` / `android-x64`，配合 `VercodeOperation: ['%c * 10 + 1', '%c * 10 + 2']` 和各自的 `output: .../app-arm64-v8a-release.apk`、`app-x86_64-release.apk`。改动量很小。

### 2.7 scanner / scanignore 说明

- 对 tag 源码 + FreeRDP submodule 的本地 scanner 结果：**FATAL_PROBLEMS: 0**（87 条 warning 全部是 FreeRDP 测试夹具 `third_party/FreeRDP/.../test/*.bin`，路径含 `/test/`，scanner 只记 warning；3 个 gradle wrapper 文件被自动移除）。原始日志见 `build/fdroid/scan-output-raw.log`。
- 由于 Flutter SDK 与 PUB_CACHE 都在应用构建目录之外，`prebuild` 只会在仓库内产生 `.dart_tool/`、`.flutter-plugins-dependencies` 等**文本**文件；native `.a`/`.so` 在 scanner 之后才生成 → 不需要 `scanignore`/`scandelete`。
- 这一点很重要：scanner 对“声明了但没用上的 scanignore/scandelete 路径”会报 fatal（`Unused scanignore path: ...`、`Non-exist scanignore path: ...`），所以能不加就不加。

### 2.8 其余 root 字段

| 字段 | 值 | 依据 |
| --- | --- | --- |
| Categories | `Remote Access` | fdroiddata `config/categories.yml:252-254` 存在该键（“Control desktops, servers, and devices remotely via RDP, VNC, or SSH”） |
| License | `Apache-2.0` | 仓库 LICENSE / SPDX 合法值 |
| SourceCode / IssueTracker / Changelog | 三个不同 URL（repo / issues / releases） | `check_duplicates` 不允许跨字段重复链接；因此不设与 SourceCode 相同的 WebSite |
| AutoName | `LRDP` | 显示名；也让 `check_checkupdates_ran` 不误报 |
| AutoUpdateMode | `None` | `Version` 模式自动生成的新 Build 条目不会带我们的自定义 prebuild/build 字段（fdroidserver `checkupdates.py` 只复制/编辑 version/commit），会导致下次自动更新后构建坏掉；由 maintainer 手动加 Build 条目 |
| UpdateCheckMode | `Tags ^v[0-9]+\.[0-9]+\.[0-9]+(-preview\.[0-9]+)?$` | tag 形如 `v0.2.0-preview.1`；用 UpdateCheckData 从 `pubspec.yaml` 取 version/vercode，避免从 tag 名硬解 |
| UpdateCheckData | `pubspec.yaml\|version:\s.+\+(\d+)\|.\|version:\s(.+)\+` | 与官方 Flutter 模板一致，vercode/version 分别取 `0.2.0+5` 的 5 与 0.2.0 |
| CurrentVersion / CurrentVersionCode | `0.2.0` / `5` | 与 Builds 条目一致 |
| Binaries | 不设 | 上游 release APK 是 arm64-only + preview 签名，与 F-Droid 构建产物不一致，不能用于可复现对照（详见 §6 建议 #4） |
| AntiFeatures | 不设 | 无广告/跟踪/非自由依赖/账号；服务端地址由用户填写 |
| Builds.timeout | `14400`（4 小时，默认 7200） | 首次构建要在 1-2 核 buildserver 上编译 FreeRDP + OpenSSL(×2 ABI) + FFmpeg(×2 ABI) + Flutter；见 §5 |

---

## 3. 本地验证证据（可复现）

环境：Arch Linux，`python3 -m venv build/fdroid/venv` + `pip install fdroidserver`（2.4.5），`git clone --depth=1 https://gitlab.com/fdroid/fdroiddata build/fdroid/fdroiddata`。

```console
$ cd build/fdroid/fdroiddata
$ cp <repo>/packaging/fdroiddata/dev.lrdp.lrdp.yml metadata/dev.lrdp.lrdp.yml
$ ../venv/bin/fdroid lint dev.lrdp.lrdp
2026-10-23 23:04:42,794 WARNING: apksigner not found! Cannot sign or verify modern APKs
2026-10-23 23:04:42,794 WARNING: unsafe permissions on 'config.yml' (should be 0600)!
$ echo $?
0
$ ../venv/bin/fdroid rewritemeta dev.lrdp.lrdp
...
INFO: Rewriting 'dev.lrdp.lrdp'
$ echo $?
0
```

两条 WARNING 是**本机全局环境**问题（venv 里没有 apksigner；`fdroiddata/config.yml` 权限不是 0600），与 `dev.lrdp.lrdp` 无关；lint 对 app 字段本身没有任何 error/warning。

反向自检证明 lint 真的在检查（故意写入 120 字符 Summary + 假 license，跑完删除）：

```console
$ ../venv/bin/fdroid lint zz.selfcheck.app
zz.selfcheck.app: Summary of length 120 is over the 80 char limit
zz.selfcheck.app: Unexpected license tag "NotARealLicense"! Only use FSF or OSI approved tags from https://spdx.org/license-list
$ echo $?
1
```

`fdroid rewritemeta` 后的文件就是 `packaging/fdroiddata/dev.lrdp.lrdp.yml` 的内容（字段顺序、`$$...$$` 换行折行均为 canonical 格式）。

**已知本地限制**：`fdroid checkupdates` 在本机无法默认完成 —— fdroidserver 的 `vcs_git.git()` 出于安全/构建机 credential proxy 约定，会用 `-c url.https://u:p@github.com.insteadOf=https://github.com` 把 https URL 改写成带占位凭据的 URL；上游 build 机配置了 credential proxy 才能解析，本机没有 → `git clone` 报 “fatal: could not read from remote repository”。这是 fdroiddata 本地工具链的固有行为，**不影响 `lint`/`rewritemeta`，也不影响生产 buildserver**。本地想验证 UpdateCheck 时可用 `GIT_CONFIG_GLOBAL` 注入 identity insteadOf 映射（仅本地实验，不写入 metadata）；实测这样能完成 clone，但 `checkupdates` 会接着对每个候选 tag 拉取 FreeRDP submodule（`git fetch origin 97eff6d...`），在本地网络下耗时过长，本次未跑完、已终止。因此 UpdateCheck 语义改用离线方式校验：见下。

**离线校验 UpdateCheckMode/UpdateCheckData**（`git show <tag>:pubspec.yaml`，与 `checkupdates.check_tags` 读取逻辑一致）：

```console
$ git tag -l | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+(-preview\.[0-9]+)?$'
v0.1.0-preview.1
v0.1.0-preview.2
v0.1.0-preview.3
v0.2.0-preview.1
$ for t in <以上 tag>; do git show "$t:pubspec.yaml" | grep -m1 '^version:'; done
version: 0.1.0+1
version: 0.1.0+1
version: 0.1.0+3
version: 0.2.0+5
```

`UpdateCheckData` 的 codeex `version:\s.+\+(\d+)` 对 `v0.2.0-preview.1` 提取 vercode=5、`version:\s(.+)\+` 提取 version=0.2.0，与 `CurrentVersion: 0.2.0` / `CurrentVersionCode: 5` 一致；tag 名里的 `-preview.N` 后缀不参与版本解析，后续预发布版本也能被正确识别。

---

## 4. 需要 upstream 的改动清单（全部可选，不阻塞本次提交）

1. **（推荐，远期）** `scripts/fetch_ffmpeg.sh` 支持 `LRDP_FFMPEG_SOURCE`（已解包源码目录）或 `LRDP_FFMPEG_TARBALL`/`LRDP_FFMPEG_SHA256` 覆盖，缺省行为不变。收益：metadata 可切换到 fdroiddata 已有的 `FFmpeg@n9.0.2` srclib，构建期不再依赖 ffmpeg.org。
2. **（可选）** `docs/BUILDING.md` 增加 “F-Droid packaging” 小节，记录本 metadata 的假设：Flutter 3.47.7、NDK 28.2.13676358、universal 2-ABI、preview signing、构建期联网下载 OpenSSL/FFmpeg 源码。
3. **（可选）** 在 `docs/BUILDING.md`/`NOTICE` 中把 “OpenSSL 3.x” 写成确切版本（当前 recipe 用 openssl-3.5.9；FFmpeg 9.0.2 已在 `scripts/fetch_ffmpeg.sh` 与 BUILD_INFO 里 pin）。
4. **（可选，远期）** CI 增加发布 universal 2-ABI release APK 并签名的 workflow；有了与 F-Droid 构建产物一致的已签名 APK 后，metadata 可加 `Binaries:` + `AllowedAPKSigningKeys:`，让 F-Droid 标记 “verified”。
5. **明确不改**：不需要 Flutter submodule；不需要改 `android/`、`native/`、`scripts/` 的任何接口；不需要改 `pubspec.yaml`。本次交付也严格遵守了“不修改 app 源码/scripts/native/third_party/pubspec”。

---

## 5. 风险与待决策项

| # | 风险 | 影响 | 缓解/决策 |
| --- | --- | --- | --- |
| R1 | 首次构建在 F-Droid buildserver 上才能验证（本地未做完整 Android 构建，环境缺 OpenSSL 源码/时间成本高） | 首轮 MR 可能需要 1-2 轮修复 | 已尽量对齐 buildserver 机制与线上 Flutter recipe；`output:`/`versionCode` 语义已按 fdroidserver 源码核对 |
| R2 | 首次构建要下载 Flutter SDK 的 Dart SDK/engine artifacts（数 GB）并编译 native 依赖 | buildserver 时间/磁盘/网络压力 | `timeout: 14400`；build 阶段先编 FFmpeg/OpenSSL 再 `flutter build`；MR 描述里向 reviewer 说明资源需求 |
| R3 | universal 2-ABI 单 APK 的 Flutter 行为未在本地实测 | 若 Flutter/AGP 行为不同，APK 可能只有一个 ABI 或构建失败 | 失败即切 per-ABI 两条 Build + `--split-per-abi` + `VercodeOperation`（§2.6 回退方案） |
| R4 | `android/gradle.properties` 的 `-Xmx8G` 在大堆限制的构建容器里可能被 OOM kill | 构建失败 | 先用默认配置；若首轮失败，和 F-Droid reviewer 协商临时代码/config（或在上游调小堆，属 upstream 决策） |
| R5 | NDK 双版本：app 用 Flutter 默认 28.2.13676358，`packages/lrdp_native` 默认 27.0.12077973 | 若 `ORG_GRADLE_PROJECT_lrdp.ndkVersion` 注入不生效，AGP 会去自动下载 NDK 27（构建期联网），增加时间/风险 | 已用 env 注入；备选：`sudo:` 里预装两个 NDK，或在 recipe 里显式 `-Plrdp.ndkVersion`（gradleprops 只作用于 gradle 主构建，故当前用 env） |
| R6 | 构建期网络依赖：pub.dev、storage.googleapis.com（Flutter artifacts）、google Maven、ffmpeg.org、GitHub（submodule/OpenSSL srclib） | 任一网络抖动导致构建失败 | F-Droid buildserver 网络本来就允许这些（大量 Flutter/FFmpeg/OpenSSL recipe 证明）；FFmpeg tarball 有 sha256 |
| R7 | 无 `Binaries`/可复现对照 | 用户可感知的 “verified” 标记缺失 | 记录在报告；远期按 §4 #4 补 |
| R8 | OpenSSL 版本未在 upstream 文档 pin（只写 “OpenSSL 3.x”） | 复现说明性不足 | recipe 已 pin 3.5.9；报告里建议 upstream 文档 pin（§4 #3） |
| R9 | 提交渠道：fdroiddata MR 在 GitLab，部分地区账号受限 | 可能阻塞 MR | Lead 已确认走 GitLab API；若仍受阻，备选 team@f-droid.org 邮件 / 社区代理，材料完全一致 |
| R10 | `AutoUpdateMode: None` | 新版本需要 maintainer 手动加 Builds 条目 + 更新 CurrentVersion，不是自动更新 | 这是自定义原生构建 recipe 的常见取舍（如 com.limelight 等）；在 MR 描述中说明 |

**待 Lead 决策**：① 是否接受 `AutoUpdateMode: None`（建议接受）；② 首次构建若失败，是否授权我按 §2.6/§5 回退方案改 metadata（不碰 upstream 代码）；③ MR 描述是否需要附上本报告的“buildserver 资源需求/回退方案”摘要。

---

## 6. MR 提交步骤（GitLab）

> 实际已于 2026-10-23 通过 GitLab API 提交，结果见 §6.1；以下步骤保留为复现记录。

1. Fork `https://gitlab.com/fdroid/fdroiddata` 到自己的 namespace。
2. `git clone https://gitlab.com/<you>/fdroiddata.git && cd fdroiddata`
3. `git checkout -b add-dev.lrdp.lrdp`
4. 把 `packaging/fdroiddata/dev.lrdp.lrdp.yml` 复制为 `metadata/dev.lrdp.lrdp.yml`（**只加这一个文件**；flutter/OpenSSL/FFmpeg 的 srclib 文件在 fdroiddata 中已存在，不需要提交）。
5. 本地验证（可选）：
   ```bash
   python3 -m venv .venv && .venv/bin/pip install fdroidserver
   .venv/bin/fdroid lint dev.lrdp.lrdp
   .venv/bin/fdroid rewritemeta dev.lrdp.lrdp
   ```
6. `git add metadata/dev.lrdp.lrdp.yml`
   `git commit -m "New app: LRDP (dev.lrdp.lrdp)"`
   `git push -u origin add-dev.lrdp.lrdp`
7. 在 GitLab 创建 MR：target `master`，标题 `New app: LRDP`；按仓库 MR 模板填写：应用是 FLOSS（Apache-2.0）、可完全从源码构建、metadata 字段、repo 内已含 fastlane metadata、fastlane 图片/截图/changelog、构建期需要 `sudo` 安装的包、`timeout: 14400` 原因、Flutter 3.47.7 srclib、NDK/SDK 说明。
8. 等待 CI（lint + buildserver 构建）与 reviewer；首轮常见要求是构建通过 + 字段核对。
9. 若 GitLab 区域限制阻塞账号操作：把同一 metadata 文件与 fork/分支信息发给 `team@f-droid.org` 走邮件/RFP 流程（材料完全相同）。

## 6.1 提交与 CI 结果（2026-10-23）

- MR：<https://gitlab.com/fdroid/fdroiddata/-/merge_requests/53893>，标题 `New app: LRDP`，fork 分支 `dev.lrdp.lrdp`（commit `53a05883` → `9fa10f63`）。
- 首轮 CI 暴露并已修复两处问题：
  1. `tools check scripts`：fdroiddata 的 `tools/make-summary-translatable.py` 会把 YAML `Summary:` 迁移为 `metadata/<appid>/<locale>/summary.txt`，并以迁移数量作为退出码；新 app（默认 `ArchivePolicy: 3`）因此失败。改为在 `metadata/dev.lrdp.lrdp/en-US/summary.txt` 提供 Summary，YAML 删除 `Summary:`。
  2. `fdroid build`：buildserver 镜像没有宿主 `gcc`，FFmpeg 9.0.2 configure 编译 host tools 时报 `Host compiler lacks C11 support`。`sudo:` 增加 `build-essential`。
- 本地用 fdroidserver 2.4.5 与 fdroiddata CI 辅助脚本复验：`fdroid lint`、`fdroid rewritemeta`、`tools/make-summary-translatable.py`、`tools/check-metadata-summary-whitespace.py`、`tools/check-localized-metadata.py` 均 exit 0；修复后 pipeline `2981808248` 重新运行。
- 第二轮 CI（pipeline `2981876762`）又暴露两处，均已修复：
  3. `fdroid rewritemeta` job：`fdroid rewritemeta` 按 80 列折行 build 命令，CI 用 `git diff --exit-code` 检查 canonical；修复方式是在 fdroiddata 克隆内运行 `fdroid rewritemeta dev.lrdp.lrdp`，把生成的 canonical 文件作为仓库内的 `metadata/dev.lrdp.lrdp.yml`。
  4. `fdroid build` job：`export "ORG_GRADLE_PROJECT_lrdp.ndkVersion=28.2.13676358"` 报 `not a valid identifier`（export 不允许变量名含点）。改为在同一条命令上用 `env "ORG_GRADLE_PROJECT_lrdp.ndkVersion=28.2.13676358" flutter build apk …`（env(1) 允许点号），Gradle 仍能以环境变量形式读到项目属性。
- 最终 CI（pipeline `2981918553`，commit `5be146ef`）9 个 job 全部成功：check apk、check source code、schema validation、tools check scripts、fdroid rewritemeta、fdroid lint、git redirect、checkupdates、fdroid build。buildserver 内完成 Flutter 3.47.7 + NDK 28.2.13676358 + 静态 OpenSSL/FFmpeg + universal 2-ABI 构建，并由 CI 测试 keystore 签名（artifact `tmp/signed/dev.lrdp.lrdp_5.signed.apk`）；MR mergeable。
- 后续：等待 F-Droid 维护者评审与合并；合并后由 F-Droid 构建周期重签并发布。

---

## 7. 参考

- fdroiddata Flutter 模板：<https://gitlab.com/fdroid/fdroiddata/-/raw/master/templates/build-flutter.yml>
- fdroiddata srclib 定义：`srclibs/flutter.yml`、`srclibs/OpenSSL.yml`、`srclibs/FFmpeg.yml`（本地副本：`build/fdroid/fdroiddata/srclibs/`）
- fdroidserver（本地 clone：`build/fdroid/fdroidserver`）：
  - `metadata.py` `build_flags`/`build_method()`（`output:` ⇒ raw 构建）
  - `build.py:466` NDK 自动安装、`build.py:619` build 命令拼接、`build.py:785-787` output glob、`build.py:820-825` versionCode 校验、`build.py:1185-1188` timeout
  - `common.py:2820-2838` prebuild 执行（`bash -e -u -o pipefail -x -c '; '.join(...)`，`$$SDK$$`/`$$NDK$$` 替换）、`common.py:4963` `auto_install_ndk()`
  - `scanner.py`（`*.a`/`*.jar`/binary 规则；`src/test` 路径只 warning；scanignore/scandelete 未使用报 fatal）
- buildserver 镜像定义（本地副本：`build/fdroid/fdroidserver/buildserver/`）：`Dockerfile`、`provision-android-sdk`、`provision-android-ndk`、`provision-apt-get-install`、`provision-gradle`
- fdroiddata metadata schema：`build/fdroid/fdroiddata/schemas/metadata.json`
- Flutter 版本/NDK 默认值：`https://raw.githubusercontent.com/flutter/flutter/3.47.7/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt`
- Flutter ABI versionCode 逻辑：`flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt`（`output.versionCodeOverride`）
- 线上 Flutter+NDK recipe 样例：`metadata/org.eu.mumulhl.ciyue.yml`、`metadata/ace.software.pocketsense.yml`、`metadata/cc.narumi.chaldea.fdroid.yml`；OpenSSL srclib 样例：`metadata/com.limelight.yml`、`metadata/net.gcompris.full.yml`
- fdroidserver 文档（Build Server Setup）：`build/fdroid/research/Build_Server_Setup.txt`
