# Nice 第一版本地实现计划

## 授权与基线
- 用户“嗯 开始”承接独立 nice 方案：本地实现与测试；不 commit/push、云构建、安装、附加或改真机参数。
- 隔离 worktree `vedette-nice` / `feat/nice-priority`，基线 `2994f24bbc73a6081d958f8f64ba4ff76640b8af`；原 ui21 工作树不改。
- 已读 README、UI21_REPORT、ROADMAP、Shared/ProcessManager/事件/详情/测试/包脚本；仓库无 AGENTS.md。基线 `make -f Makefile.tests test` 全过。没有可用关系图，按相关源文件追踪，不重复安装图工具依赖。

## 功能契约
1. 每 App/daemon 独立 `niceEnabled`（默认 false）和 `niceValue`（整数 -20…20，未设UI预选0）；不启用≠强制0。旧 `enabled` 仍只表示 CPU 开关，全局开关控制二者。nice-only 不能进入 CPU setter。
2. 沿用原配置域/路径/通知、PID解析和串行事件队列。CPU内核策略/身份模块冻结；正常启动/配置路径复用既有扫描结果，不增加周期扫描或常驻进程。手动 nice 检查/卸载请求只触发一次有界补扫；卸载另附非 setuid 的一次性握手工具，不是 daemon。
3. 目标 PID>0 且不是 PID1/执行端自身；设置前和回读前复验同一实例。原值首次接管保存；更新不覆盖原值。getpriority=-1 仅 errno非0才失败。
4. 写后回读匹配才显示成功；关闭/删除/全局关/重置恢复同实例原值。身份读取失败不等于退出，失败记录保留；旧PID已复用才可无写丢弃。
5. 记录在第一次可能写 nice 前持久化，包括待写意图；与开机时间、PID启动时间和路径绑定，runningboardd重启不得把已修改值当原值。状态存储失败则不开始新写。状态文件损坏/不安全则 fail closed。
6. 不抢写第三方已改变的值：当前值不等于已知原值/本插件上次或待写值时报告冲突，保留证据。此为保守比较，非内核CAS原子保证。
7. UI保存原子且检查返回；有每条规则revision，回执匹配当前规则/全局开关，不把旧成功显示为新成功。手动检查/重试走通知和回执，只有事件合并的100ms延迟，不运行周期性定时器。
8. 首版不改Jetsam、VM、前后台、CPU阈值/策略、不自动启用系统关键项。设置App/PID1/执行端禁止nice，其他敏感项需显式确认。

## 文件分工
- Portable nice transition engine + callback tests：VDTNicePolicy.h/.c，tests/test_nice_policy.c。
- 父代理：共享schema/严格配置/安全存储/运行时管理/串行接入、CI测试入口、整体回归与文档。
- UI子任务：nice控件、回执文案、列表保存状态与英中资源，仅约定的prefs文件；不改CPU setter或内核模块。

## 验收/独立失败信号
- -20/-1/0/+20、非法类型/小数/超限、nice-only/CPU-only/都开/都关、旧plist无nice键必须覆盖。
- 先保存原值后写；保存失败0次写；每个读取/写入都必须经过fresh identity guard。
- 更新值后仍恢复首次原值；PID复用0次写；身份暂不可读不丢记录；EPERM/读回不一致不报成功。
- crash-before-set/crash-after-set/restore-fail/store-fail、外部改值、重启boot不匹配、损坏/链接/权限/超限状态文件。
- 生产C引擎由fake kernel/store执行；Foundation/UI在Linux不能冒称原生跑过，准备macOS CI测试但本轮不触发Actions。
- 旧C/源码/资源测试继续跑，精确冻结CPU代码；必要测试范围更新只允许明示nice增量，不删除旧断言。
- 收尾diff/check工作树、源码交付包、报告区分本地验证/未Apple编译/未实机执行端权限。

## 生命周期限制需明确
- 卸载必须先请求并确认nice恢复，不能仅依赖postrm杀宿主；失败时保留记录且阻止声称已完成。实现优先最小受检路径，不能把未验证设备卸载表现当完成。
- 新版状态目录可写性、runningboardd MAC权限与UIKit回执需要云包后单独真机验证；root终端成功不替代执行端验证。
