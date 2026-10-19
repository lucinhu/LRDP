# LRDP 图标

深绿色底、显示器与连接箭头。图形为项目自有矢量素材，与项目采用相同许可。
`lrdp.svg` 是图形和颜色的唯一源文件，其他资源由脚本生成。

```sh
python3 -m pip install CairoSVG 'Pillow>=10.1'
python3 scripts/generate_icons.py
```

- Android：API 24–25 的五种密度 PNG，API 26+ 自适应图标，API 33+ 单色主题图标。
- iOS：按现有 AppIcon 目录规格生成不透明 RGB 图标，由系统裁切圆角。
- macOS：16–1024 px 的 AppIcon 资源。
- Windows：ICO 包含 16、20、24、32、40、48、64、128、256 px。
- Linux：SVG 应用菜单图标、嵌入程序的 PNG 窗口图标；解压后可运行 `install-desktop.sh` 注册当前用户菜单。
- Flutter：应用内品牌图标使用同一份图形。

适配规范参考 [Android 自适应图标](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)
与 [freedesktop 启动参数规范](https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html)。

`preview.png` 展示浅色、深色背景下的实际尺寸。Apple 和 Windows 图标资源已替换，
这些系统的原生应用构建与显示效果仍需各自平台验收。
