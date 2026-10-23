# LRDP AUR 打包（`lrdp-bin`）

本目录维护 AUR 包 `lrdp-bin` 的打包文件。LRDP（**L**ightweight **R**emote
**D**esktop **P**rotocol）是基于 Flutter + FreeRDP 的轻量 RDP 客户端；`lrdp-bin` 直接
分发上游 GitHub Release 中预编译的 Linux x64 Flutter 应用（AppImage），不重新编译
Flutter / FreeRDP 代码。

上游版本：tag `v0.2.0-preview.1`（release commit `98b86ec…`），应用版本 `0.2.0+5`，
`applicationId` 为 `dev.lrdp.lrdp`。`pkgver` 取上游应用版本 `0.2.0`；`pkgrel=2` 起
在 `package()` 中移除 AppImage AppRun hook 强制设置的 `GDK_BACKEND=x11`（见下文
“HiDPI 与 Wayland 缩放”）。

## 文件

| 文件 | 说明 |
| --- | --- |
| `lrdp-bin/PKGBUILD` | 打包脚本：`source` 指向 release 的 `lrdp-0.2.0-linux-x64.AppImage` + 品牌图标；`build()` 用 `--appimage-extract` 解包（无需 FUSE），`package()` 安装到 `/opt/lrdp`。 |
| `lrdp-bin/.SRCINFO` | 由 `makepkg --printsrcinfo` 生成，提交 AUR 时必须与 PKGBUILD 一致。 |
| `lrdp-bin/LICENSE` | 0BSD，仅覆盖本目录的 AUR 打包文件；LRDP 应用本身为 Apache-2.0（安装后的 `/usr/share/licenses/lrdp-bin/LICENSE`）。 |
| `lrdp-bin/.gitignore` | 忽略 `makepkg` 的 `src/`、`pkg/` 与 `*.pkg.tar.zst`。 |

## 安装布局

| 路径 | 内容 |
| --- | --- |
| `/opt/lrdp/` | 原始 AppImage AppDir 布局：`AppRun`、`AppRun.gtk`、`apprun-hooks/`、`usr/bin/lrdp`、`usr/bin/data/`、`usr/lib/`（AppImage 自带 GTK3/GLib/OpenSSL/libsecret/libpulse/FreeRDP/Flutter 运行库）、`usr/share/`。 |
| `/usr/bin/lrdp` | 包装脚本：`exec /opt/lrdp/AppRun "$@"`（保留 AppRun 对 `APPDIR`、`OPENSSL_MODULES`、GTK 模块缓存的设置，运行时不需要 FUSE）。 |
| `/usr/share/applications/dev.lrdp.lrdp.desktop` | 桌面入口，`Exec=lrdp`、`Icon=dev.lrdp.lrdp`。 |
| `/usr/share/icons/hicolor/{36x36,64x64,128x128,256x256,512x512}/apps/dev.lrdp.lrdp.png`、`scalable/apps/dev.lrdp.lrdp.svg` | 图标。AppImage 内只有 256x256；其余尺寸取自 release tag 的 `assets/branding/`。 |
| `/usr/share/licenses/lrdp-bin/{LICENSE,NOTICE}` | 上游 Apache-2.0 许可证与 NOTICE（取自 AppImage 内 `usr/share/doc/lrdp/`）。 |
| `/usr/share/doc/lrdp-bin/` | 上游文档 `ARCHITECTURE/BUILDING/CLIPBOARD/LOCALIZATION/ROADMAP/USAGE/VERIFICATION.md`。 |

## 依赖推导（`depends` 来源）

在解包后的 AppImage 上对入口二进制做 `ldd`（含传递闭包），再把 `/usr/lib/…`
路径用 `pacman -Qo` 映射为 Arch 包名：

```
./lrdp-0.2.0-linux-x64.AppImage --appimage-extract
ldd squashfs-root/usr/bin/lrdp | grep -E '=> /usr/lib/'
pacman -Qoq /usr/lib/libharfbuzz.so.0      # => harfbuzz
```

结果共 23 个系统库；`glibc`、`libgcc`、`libstdc++`、`bzip2` 属于 `base` 元包，未重复列出。
最终 `depends`：`brotli expat fontconfig freetype2 fribidi graphite harfbuzz
libgpg-error libx11 libxau libxcb libxdmcp wayland zlib`。

另外显式加入 `libglvnd`：AppImage 自带的 libepoxy/libgdk 通过 `dlopen(3)` 加载
`libEGL/libGL/libGLESv2`（`ldd` 看不到），Flutter 的 OpenGL 渲染需要这些入口；
`mesa` 作为显卡/软件渲染驱动放入 `optdepends`。

> 上游 AppImage 的详细构建信息（appimagetool、linuxdeploy、GTK 插件版本与所有
> ELF 的 sha256、glibc 上限 2.35）保存在解包树的
> `usr/share/doc/lrdp/APPIMAGE_BUILD.json`，即安装后的
> `/opt/lrdp/usr/share/doc/lrdp/APPIMAGE_BUILD.json`，可供审计。

## 来源校验

1. **主产物 AppImage**：`https://github.com/lucinhu/LRDP/releases/download/v0.2.0-preview.1/lrdp-0.2.0-linux-x64.AppImage`
   - `sha256 = e616045bc4081cc34a0e4876fc4ecfa80d397079dd8da430d39880a2a8c98350`
   - 与 release 资产 `SHA256SUMS` 中的同名条目一致（本地实测 `sha256sum -c` 通过）；
   - release 另有 `SOURCE_SHA256`（`affc686…`，源码包 sha256）和 `RELEASE_INFO.json`
     （`release_commit`、`application_runtime_commit`、`native_abi=5`）可供核对。
2. **品牌图标**：取自 tag `v0.2.0-preview.1` 的 `assets/branding/`，sha256 写在 `sha256sums` 中；
   其中 256x256 直接使用 AppImage 内 `usr/share/icons/hicolor/256x256/apps/dev.lrdp.lrdp.png`，
   并与 `assets/branding/lrdp-256.png` 完全一致（`638641bb…`），用作交叉校验。
3. **完整性**：`build()` 里校验解包结果必须有 `AppRun` 与 `usr/bin/lrdp`，否则构建失败。

## 本地验证记录（2026-10-23，Arch Linux rolling，makepkg 7.1.0）

```bash
# 缓存目录中预置 6 个 source（AppImage + 图标），即可离线重复构建
SRCDEST=/path/to/source-cache PKGDEST=build/aur/pkg-v2 \
  makepkg -Ccf --nodeps
```

- 源校验：6 个 source 全部 sha256 通过。
- 产物：`lrdp-bin-0.2.0-1-x86_64.pkg.tar.zst`，58,919,441 B，
  `sha256 = df97d06e113bf1c0217bb017c9e1a644ec60d9543b6e4871c6bf086ca49b5d49`，
  1022 个文件，安装后大小 167,467,105 B。
- 检查：`/usr/bin/lrdp`、desktop、5 个尺寸图标 + SVG、`LICENSE/NOTICE`、7 份文档均就位；
  `/opt/lrdp` 目录权限已从 AppImage 的 `0700` 规范为 `0755`。
- 对安装树 `opt/lrdp/usr/bin/lrdp` 复跑 `ldd`：无 `not found`，系统库与 `depends` 一致。
- 无头启动：`DISPLAY= /opt/lrdp/AppRun` 正常进入 GTK 初始化并输出
  `Gtk-WARNING: cannot open display: `（exit 1）。本机无 Xvfb/Xvnc，按项目约定不占用
  用户桌面，因此**未做真实图形界面启动测试**。

### 本地验证记录（2026-10-24，pkgrel=2，HiDPI 修复）

```bash
SRCDEST=/home/lucinhu/workspace/flutter/LRDP/build/aur/src PKGDEST=/tmp/aurpkg3 \
  makepkg -Ccf --nodeps
```

- 源 AppImage sha256 与 release `SHA256SUMS` 一致（`e616045b…`）。
- 产物：`lrdp-bin-0.2.0-2-x86_64.pkg.tar.zst`，58,919,403 B，
  `sha256 = f22298eab6fd0b47404b66b04f17c58393d26d7af0183a68eba1375a68e6e6a6`。
- 解包检查：`/opt/lrdp/apprun-hooks/linuxdeploy-plugin-gtk.sh` 中已无 `GDK_BACKEND=x11`。
- KDE Plasma 6 Wayland（eDP-1，150% 缩放）下启动安装树中的 `AppRun`：进程存活、窗口创建成功；
  同一环境下 GTK 探针在 Wayland 后端报告 `monitor_scale=2`（逻辑 1707x1067），而强制
  `GDK_BACKEND=x11` 时报告 `monitor_scale=1`（物理 2560x1600），与“界面不随系统 DPI 变化”
  的现象一致。
- `env -u WAYLAND_DISPLAY`（无 Wayland 时）重新启动：GTK 自动回退 X11，进程正常存活。

### 已知限制（继承上游 AppImage，不是打包引入）

- AppImage 内 gdk-pixbuf 的 TIFF loader 与 GTK 的 IBus 输入模块没有把自带依赖库放进
  `RUNPATH`：运行时 `libtiff.so.5`、`libibus-1.0.so.5` 报 not found；GTK 会回退，
  可能影响 TIFF 图片加载与 IBus 输入法，不影响启动。
- `AppRun.gtk` 强制 Adwaita 主题（上游行为）。
- `/opt/lrdp` 保留 AppImage 内部 `usr/share/doc` 的依赖版权副本（约 12 MB），以保持与上游
  完全一致的布局。

## HiDPI 与 Wayland 缩放

上游 AppImage 由 linuxdeploy 的 GTK 插件生成，其 `apprun-hooks/linuxdeploy-plugin-gtk.sh`
硬编码了 `export GDK_BACKEND=x11`。在 Wayland 桌面（KDE Plasma / GNOME）下，这会让应用
强制走 XWayland；XWayland 中 GTK 报告的缩放因子是 1（而原生 Wayland 是 2）。Flutter
Linux 只读取 GTK 的整数缩放因子，因此界面不会跟随桌面设置的 150% / 125% 等 DPI 缩放，
窗口只是被合成器整体放大（发虚）。

`pkgrel=2` 起 `package()` 删除该行，让 GTK 自行选择后端：

```bash
sed -i '/^export GDK_BACKEND=x11/d' \
  "${pkgdir}/opt/lrdp/apprun-hooks/linuxdeploy-plugin-gtk.sh"
```

- Wayland 会话：GTK 使用 Wayland 后端，Flutter 拿到缩放因子 2，150% 下界面清晰且尺寸正确；
- X11 会话：GTK 自动回退 X11，行为与之前一致；
- 用户仍可用自己的 `GDK_BACKEND` 环境变量强制后端。
- 上游 `scripts/package_appimage.sh` 已同步修复，下一版 AppImage 会自带该改动，本补丁届时
  自动变成空操作。

## AUR 推送步骤

前置：release `v0.2.0-preview.1` 已公开，asset 可匿名下载且与 `SHA256SUMS` 一致。

```bash
# 1) 首次 clone AUR 仓库
git clone ssh://aur@aur.archlinux.org/lrdp-bin.git
cd lrdp-bin

# 2) 复制本目录的打包文件
cp /path/to/LRDP/packaging/aur/lrdp-bin/{PKGBUILD,.SRCINFO,LICENSE,.gitignore} .

# 3) 重新生成 .SRCINFO（必须，且要在提交前执行）
makepkg --printsrcinfo > .SRCINFO

# 4) 干净构建验证（依赖需已安装）
makepkg -Ccf

# 5) 提交并推送
git add PKGBUILD .SRCINFO LICENSE .gitignore
git commit -m "upgpkg: lrdp-bin 0.2.0-2"
git push
```

注意：

- AUR 仓库只放打包文件，不要提交 `*.pkg.tar.zst`、`src/`、`pkg/`、二进制 tarball 或文件清单。
- 本机 SSH 22 端口不可用时可由 CI 代推：把 AUR 私钥放在 GitHub Actions secret 中（如
  `AUR_SSH_PRIVATE_KEY`），在 job 内写入 `~/.ssh/aur` 并新增 `Host aur.archlinux.org`
  配置（`User aur`、`IdentityFile ~/.ssh/aur`）；私钥不得提交到仓库。

## 版本更新流程

1. 确认新 Release 已发布，下载官方 `SHA256SUMS` 并校验：
   `curl -fsSLO https://github.com/lucinhu/LRDP/releases/download/<tag>/SHA256SUMS && sha256sum -c SHA256SUMS --ignore-missing`
2. 修改 `PKGBUILD`：`pkgver`、`_tag`、`pkgrel`（新版本 `pkgrel=1`），AppImage 文件名与
   sha256；图标随 tag 更新时同步 `_branding_url` 与校验和。可用 `updpkgsums`（或
   `makepkg -g`）重新生成 `sha256sums`。
3. 用 `makepkg -Ccf --nodeps` 重新干净构建，检查文件清单与无头启动输出。
4. `makepkg --printsrcinfo > .SRCINFO`，提交 `PKGBUILD` + `.SRCINFO` 并推送。
5. 若上游 bundle 布局变化（AppImage 结构、系统依赖、捆绑库变化），重新执行
   `ldd` + `pacman -Qo` 推导并更新 `depends`。

## 维护者

- Maintainer: lucinhu <lucinhu@users.noreply.github.com>（如 AUR 账号使用其他邮箱，更新
  `PKGBUILD` 顶部 `# Maintainer:` 注释即可）。
