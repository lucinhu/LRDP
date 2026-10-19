# LRDP 项目约定

- 使用 Flutter + FreeRDP，不通过启动外部 RDP 客户端冒充内嵌连接。
- `third_party/FreeRDP` 是上游 Git 子模块。不得修改其中源码；更新只移动经审查的版本指针。
- FreeRDP 适配、CMake 选项和虚拟通道逻辑放在 `native/` 与 `packages/lrdp_native/`。
- 所有 FreeRDP 调用由原生连接线程串行处理，Dart FFI 会话归单个 worker isolate 所有。
- 密码不进入配置 JSON、导出文件、日志或命令行；安全存储失败时不使用明文持久化降级。
- 修改协议、证书、输入或生命周期代码后运行原生 CTest 和隔离回环协议测试。
- 修改界面后运行 Flutter 测试；区分布局测试、真实连接测试和平台真机验收。
- 未实测的平台或功能保持明确的待验收状态，不能将项目工程存在当成跨平台验证完成。
- 记录可复现的构建步骤和实际限制，见 `docs/BUILDING.md`、`docs/VERIFICATION.md`。
- 桌面界面面向实际使用：采用功能名称和操作提示，不使用宣传口号，不加入无实际功能的账号或状态入口；保留清楚的连接、编辑、搜索与分组操作。
