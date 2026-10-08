# Vedette ui2.1 本地实现报告

## 状态

以 ui2 `cd0b34807c031d2e179f1ae397ea8c6847be35e3` 为视觉基线，当前分支 `feat/ui21-cpu-efficiency`，候选包版本 `1.1.10-1+ui21`，自有包/Bundles仍为 `com.doimty.vedette` / `com.doimty.vedetteprefs`。**本报告记录本地候选，尚未 commit、push、云构建或安装；用户设备仍运行先前安装的版本。**

## UI: 保留 ui2，只轻改策略入口

- 首页、应用/daemon列表、关于、头卡、行距/留白恢复为 ui2 文件逐字节内容；ui2 中文、启用置顶和 iOS15 cell lifecycle 修复保留。
- 不再包含 ui3 自绘 `VDTCompactSectionLabel`、44pt统一行高、4/8/12pt section spacing 或截断版列表；分组标题/footer走原生 PSListController 路径，防止上次出现的重影复发。
- 详情页只把一整块 `PSSegmentCell` 改成普通 `PSLinkListCell` 单行选择。点击进入专属 `VDTActionListController`，仍由系统列表组件显示“终止/限速”。该控制器把读写显式转给 parent `VDTProcessConfiguration`，不新建默认值域、不直写NSUserDefaults。values、titles、default、violationPolicy key、通知名、父setter实现保持原有含义。
- 实际 UIKit/PSListItemsController 导航、选择和返回尚无真机结果。属于 UI2.1 唯一显示改动，不再压缩其它页面。

## CPU 优化 E1：Release 日志 payload 惰性

`VDT_DIAGNOSTIC_CALL` 在 `DEBUG=0` 下展开为空宏，连 label、emitter 和 payload 表达式都不求值，避免调用点创建字典/NSNumber；Debug 仍调用原有 `HBLogDebug`实现。Release实现体用编译期条件排除。

纯C副作用回归证明Release label/payload/emitter调用计数均0，Debug每次完整执行；Objective-C预处理回归确认含逗号的真实字典字面量在Debug中保持为单参数，Release展开没有字典/实现引用。**是否成功去掉Apple优化链接后的最终 ARM64e 指令还要由云产物检查，当前没有新包证据。**

## CPU 优化 E2：可信配置解析快照

- `normalized_configs_snapshot`仅存在runningboardd进程，读写仅由已有`vedette_serial_queue`串行化。
- 冷启动意外地在补扫/快捷路先发生时，从当前`VDTGetPrefs()`初始化一次；正常 reload 从单次`getPrefs()`解析新内容，先更新共享 prefs，再发布新的归一化不可变数组。
- 单 PID快捷路径、立即扫描、100ms尾随扫描复用此快照；卸载恢复仍独立读取临时旧prefs并做restore，不误用已清空的新prefs。
- 不缓存PID存活、路径/实例身份或 syscall许可；配置内容、策略、参数合法性不改；原PID+start time+path复核和两阶段补扫全部保留。
- 启动路径的配置数组解析次数从每快路径/扫描重复归一化降到同一代只一次；每次全PID扫描、逐进程身份查询和 target匹配依旧，未声称省掉整次扫描。

## 测试与范围

`make -f Makefile.tests test`通过：

- Release/Debug诊断宏副作用C夹具和Objective-C宏预处理。
- 五项ui2视觉/选择行测试，五项CPU缓存/安全边界测试，五项进程Action读写转发测试。
- 原UI资源九项、iOS15 lifecycle两项、自有包ID三项、ui2行排序fixtures与1000随机 oracle、process identity/policy C套件。
- backend source freeze只准许UI choice、宏/缓存候选及ui21 release metadata：VDTProcessManager、身份、transition、共享存储、状态/卸载脚本与filter保持ui2逐字节不动。
- 原auto-monitor静态契约已更新为验证snapshot来源/队列复用，需再次作为主命令复跑，并检查 `git diff --check`。

这些是宿主C/源码/资源测试，不是原生UIKit runtime proof、系统调用能耗基准，也不代替cloud Xcode build。当前唯一root CPU基线为此前一次非待机约405秒采样，runningboardd是整个host进程约1.445%单核，不作为E1/E2前后A/B。

## 尚需完成

1. 最后跑全部CI等价测试、clang warnings、diff/status。
2. CI固定Theos/Xcode17.5/iOS15 target编译完整 arm64+arm64e包，实包校验own package ID、Preferences Bundle ID、Conflict/Replaces、中文资源、`VDTActionListController`符号，且Release二进制没有`VDTProbeRecordImpl`。
3. 如获准推送/构建，应新分支；不覆盖`feat/compact-prefs`的ui3/ui4历史，也不安装设备。
4. 用户日后安装时先点进详情处理方式，分别选择两项后回列表确认保存；UI/省电均由真机重测后再定。

其它恢复可靠性R1、安全免扫描E3、索引E4、差量下发E5、设置快照E6及前后台/电量/温度/备份/暂停均未实现。