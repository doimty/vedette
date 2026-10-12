# App 扩展独立规则：本地实施计划

基线：`2994f24bbc73a6081d958f8f64ba4ff76640b8af`（ui2.1 云编译通过）。工作树 `vedette-appex`，本地分支 `feat/appex-process-rules`。用户授权添加 `.appex` 支持；内存上限与优先级本轮仅调研，未授权推送、构建、安装或设备策略变更。

## 假设与选择
- 新增“App 扩展”独立原生列表，可搜索、已启用置顶，使用既有 CPU 详情/策略页。
- 原类型 App=0/Daemon=1 不变，追加 Extension=2；新增 `extensionConfigs` / `extensionIdentifier`，旧文件路径/通知/App/daemon规则均保留。
- 扩展依据最近 `.appex` 祖先的 Info.plist（独立 bundle ID、NSExtension、主可执行文件）识别，不按进程短名混配。未知/损坏元数据不猜扩展身份。
- 存在独立扩展配置时优先采用（包括关闭/参数损坏时的停用覆盖）。不存在时保留现有宿主 App 规则回退。识别为 app/appex 的 PID 不能落入同名 daemon 规则。
- 列表从 LSApplicationWorkspace 的 app bundleURL 只遍历一层 `PlugIns/*.appex`；不递归全盘搜索，不增加 CPU 常驻轮询。
- CPU 身份验证、syscall 迁移顺序、失败保留、100ms 补扫与串行队列不变；新规则加入既有重载/恢复路径。

## 成功标准与独立失败信号
1. 扩展 ID 独立读写，关闭扩展不关闭 App，启用扩展不影响兄弟扩展。旧两类规则和数据仍兼容。
2. 相同短进程名不同扩展不合并；不可识别 appex 不落同名 daemon。扩展显式关闭不被宿主规则覆盖；无扩展规则仍继承宿主。
3. 一个 PID 只产生一个 target；PID+启动时间+路径仍在策略前复核。撤销/全局关闭/卸载恢复含扩展。
4. UI 保留 ui2.1 的样式与原生分组，只添加一行入口/扩展列表；未知私有 selector 先 capability gate。
5. 回归应能拒绝：交换类型编号、扩展存到 daemon、去掉独立配置优先、关闭后回退宿主、appex落 daemon、放宽身份校验、移除补扫。

## 验证
- 基线已运行 `make -f Makefile.tests test`、auto-monitor、identity/policy 套件，全通过。
- 增加生产 C 选择/路径核的动态单元及随机/负例测试；源码契约精确限定旧文件差异，不以删掉冻结断言规避失败。
- 全量已有测试、`git diff --check`，clang iOS arm64/arm64e 语法检查（现有 SDK/真实 Preferences 声明）。
- 无本机 UIKit/原生 Foundation runtime，静态/宿主测试不等 Apple 完整链接、真机列表/CPU策略验证。CI 可接门禁，但这轮不推/不触发。

## 内存调研边界
原上传 plist 含授权信息；只统计 `applist` 参数与 `sysctl`，不复制授权字段到报告/源码。逐进程内存上限、jetsam band 与 nice 必须区分；不导入34个全局 sysctl，不把 Hello 的 `priority=150/210` 猜作内核 band，不实现无法读回/恢复的内存控制。
