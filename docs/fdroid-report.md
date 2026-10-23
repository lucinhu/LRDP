# LRDP 的 F-Droid 提交材料与可行性报告

日期：2026-10-23 · 版本：LRDP 0.2.0（versionCode 5，tag `v0.2.0-preview.1`，commit `98b86ecfc7bb84b1a05d4185714b58bfdd3574d3`）

## 状态

本地材料已完成，`fdroid lint` 通过。fdroiddata MR 已提交：<https://gitlab.com/fdroid/fdroiddata/-/merge_requests/53893>（fork `lucinhu/fdroiddata`，分支 `dev.lrdp.lrdp`）。CI 已通过：pipeline `2981918553` 的 9 个 job 全部成功，包含 buildserver 内的 Flutter + NDK + OpenSSL/FFmpeg + universal 2-ABI 构建、APK 校验与签名（测试 keystore）；MR 状态 mergeable，等待 F-Droid 维护者评审。

- 完整 metadata：`packaging/fdroiddata/dev.lrdp.lrdp.yml`（可直接作为 `fdroiddata/metadata/dev.lrdp.lrdp.yml`）
- fastlane 素材（`main` commit `4158f54` 加入，描述文案在 `d98fffa` 更新为 lightweight 定位）：`fastlane/metadata/android/en-US/`（short/full description、icon、5 张 phoneScreenshots、changelogs/5.txt）
- Summary 素材：`packaging/fdroiddata/dev.lrdp.lrdp/en-US/summary.txt`（当前 fdroiddata 约定；YAML 不再写 `Summary:`）
- 研究与提交步骤：`packaging/fdroiddata/RESEARCH.md`
- 验证证据：`build/fdroid/lint-output.log`、`build/fdroid/rewritemeta-output.log`、`build/fdroid/lint-selfcheck.log`、`build/fdroid/scan-output-raw.log`

## 关键结论

1. **构建方式**：F-Droid 用 `srclibs: [flutter@3.47.7]` 固定 Flutter 版本（与 `.github/workflows/check.yml:19` 一致），不引入 Flutter submodule；仓库代码不需要任何改动。NDK 28.2.13676358 通过 metadata `ndk:` 由 buildserver 自动安装；platform 36 / build-tools 36.0.0 / cmake 3.22.1 在 prebuild 用 `sdkmanager` 安装；`build-essential nasm xz-utils perl pkg-config` 通过 recipe 的 `sudo:` 安装（首轮 CI 发现 buildserver 无宿主 C 编译器，FFmpeg configure 报 `Host compiler lacks C11 support`，故补 `build-essential`）。
2. **静态依赖**：OpenSSL 3 复用 fdroiddata 现有 `OpenSSL@openssl-3.5.9` srclib（脚本已有 `LRDP_OPENSSL_SOURCE` 接口，零改动）；FFmpeg 9.0.2 沿用现有 `scripts/fetch_ffmpeg.sh`（官方 tarball + sha256 校验）在构建期下载。两者都在 `build:` 阶段（scanner 之后）编译，避免 `.a` 静态库触发扫描错误。
3. **APK 形态**：universal 2-ABI（arm64-v8a + x86_64，均为 `docs/BUILDING.md` 已实测的 ABI），单条 Build 条目，versionCode 5，输出 `build/app/outputs/flutter-apk/app-release.apk`。未使用 `--split-per-abi`（会触发 Flutter 的 ABI versionCode 编码 1005/2005/3005 并需要 per-ABI 条目）。
4. **签名**：构建期 `LRDP_ANDROID_PREVIEW_SIGNING=1` 让 `validateLrdpReleaseSigning` 通过（debug keystore，仅构建机内部使用）；F-Droid 发布前会用自己的 key 重签名，这是标准流程。
5. **更新检查**：`UpdateCheckMode: Tags` + `UpdateCheckData` 从 `pubspec.yaml` 取 version/vercode；`AutoUpdateMode: None`（自定义 native 构建无法被自动 mode 安全复制）。本地已用 `git show <tag>:pubspec.yaml` 验证四个发布 tag 的映射：`v0.2.0-preview.1 → 0.2.0 / 5`，与 `CurrentVersion`/`CurrentVersionCode` 一致。
6. **本地 lint**：`fdroid lint dev.lrdp.lrdp` exit 0，无 app 级 warning（仅两条本机环境 WARNING：venv 无 apksigner、clone 里 `config.yml` 权限非 0600）。反向自检（故意写错 Summary/License）能被正确报错，证明 lint 有效。
7. **源码扫描**：对 tag 源码 + FreeRDP submodule 本地跑 fdroidserver scanner，`FATAL_PROBLEMS: 0`（87 条 warning 全部是 FreeRDP `test/` 目录下的测试夹具；路径含 `/test/`，按规则只记 warning）。

## 需要 upstream 的改动（全部可选、非阻塞）

1. （推荐，远期）`scripts/fetch_ffmpeg.sh` 增加 `LRDP_FFMPEG_SOURCE` 等覆盖项，使 metadata 未来可切换到 fdroiddata 已有的 `FFmpeg@n9.0.2` srclib，去掉构建期对 ffmpeg.org 的依赖。
2. （可选）`docs/BUILDING.md` 增加 “F-Droid packaging” 小节，记录本 metadata 的假设（Flutter 3.47.7、NDK 28.2.13676358、2-ABI universal、`LRDP_ANDROID_PREVIEW_SIGNING=1`、构建期联网）。
3. （可选）文档/NOTICE 把 “OpenSSL 3.x” 改成 recipe 实际使用的版本（openssl-3.5.9）；FFmpeg 9.0.2 已 pin。
4. （可选，远期）发布 universal 2-ABI 的已签名 APK 后，metadata 可加 `Binaries` + `AllowedAPKSigningKeys`，获得 F-Droid “verified” 标记。

本次未修改 app 源码、`android/`、`native/`、`scripts/`、`third_party/FreeRDP` 或 `pubspec.yaml`。

## 主要风险

- 首次构建必须在 F-Droid buildserver 上验证（本地不做完整 Android 构建）：Flutter SDK/engine 下载 + OpenSSL/FFmpeg/FreeRDP 编译可能耗时较长 → metadata 设 `timeout: 14400`（默认 7200）。
- universal 2-ABI 单 APK 未本地实测；若有问题，回退为 2 条 per-ABI Build + `--split-per-abi` + `VercodeOperation`（见 RESEARCH.md §2.6）。
- buildserver 容器资源（`android/gradle.properties` 的 `-Xmx8G`）与网络依赖（pub.dev、storage.googleapis.com、ffmpeg.org、GitHub）是首轮构建的主要不确定项。
- `fdroid checkupdates` 无法默认在本机完成（fdroidserver 把 GitHub URL 改写成需要构建机 credential proxy 的形式），属本地工具链限制，不影响 lint 与生产构建；UpdateCheck 语义改用离线方式校验（`git show <tag>:pubspec.yaml` → `v0.2.0-preview.1` 得到 0.2.0 / 5，与 `CurrentVersion`/`CurrentVersionCode` 一致）。

## 提交（Lead）

MR 步骤见 `packaging/fdroiddata/RESEARCH.md` §6：fork `fdroid/fdroiddata` → 只加 `metadata/dev.lrdp.lrdp.yml` → lint → push → MR（`New app: LRDP`）。若 GitLab 区域限制阻塞账号操作，可用同一文件走 `team@f-droid.org`。
