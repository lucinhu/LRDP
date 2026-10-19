# 界面语言

默认跟随系统，设置中可选择简体中文、繁体中文和 English。
中文的 Hant / TW / HK / MO 使用繁体，其余中文使用简体；其他未支持语言回退 English。
语言设置只保存语言代码，切换时保留当前页面、未保存的表单与活动连接。

翻译源文件位于 `assets/l10n/{zh-CN,zh-TW,en}.json`。简体中文原文作为消息 ID，
参数使用 `{0}`、`{1}`，各语言可调整位置。连接名称、地址、路径、用户名与输入文字
保持原样；原生诊断保留原文。不要将用户数据或 RDP 配置字段名当成翻译消息。

修改目录后，在 Flutter/Dart 已进入 PATH 的环境运行：

```sh
python3 scripts/generate_localizations.py
flutter test test/localization_test.dart
```

生成器检查三份目录的消息及占位符是否一致，再生成 `lib/l10n/messages.dart`。
应用使用同步 LocalizationsDelegate 加载编译后的常量，不依赖网络、运行时翻译服务
或首次页面异步读取。代码中的 `context.tr('原文')` 只用于界面文案；参数在翻译后
替换一次，参数内的括号和中文不会继续解释成其他消息。

增加新语言时还需更新 `AppStrings` 的语言名称、Locale 列表/解析及 `ProfileStore.languages`，
并检查长文本、输入法、证书和登录对话框。Flutter Material/Cupertino 的标准控件使用
对应官方本地化委托。当前语言回归验证目录一致、语言解析及编辑中的表单原地切换；
翻译仍可按用户习惯持续修订。
