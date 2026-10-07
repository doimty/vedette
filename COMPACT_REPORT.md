# Vedette 紧凑 UI 本地候选报告

> 后续统一计划见 [ROADMAP.md](ROADMAP.md)。紧凑 UI 与普通处理方式选择行均已写入本地源码，待构建/真机验证；CPU 优化和可能增加的功能仍为规划。后续不能遗漏现有 UI 候选，也不需要为等全部功能而重做或搁置 UI。

## 当前修正：ui4

ui3 云构建成功（4ac1497 / run37641593227），但用户真机截图显示分组标题和说明重复叠画，不能作为通过验收的版本。已补单一文字来源及系统标签抑制，详见 [SECTION_TEXT_FIX.md](SECTION_TEXT_FIX.md)。同时按用户要求改为自有包 ID `com.doimty.vedette` 和设置 Bundle ID `com.doimty.vedetteprefs`，旧配置通道兼容保留，详见 [PACKAGE_IDENTITY.md](PACKAGE_IDENTITY.md)。这些改动随 ui4 继续推送构建，不含 CPU 优化或设备安装。

## ui3 发布阶段记录

用户已授权在独立分支 `feat/compact-prefs` 推送并进行 roothide 云构建。版本调整为 `1.1.10-1+ui3`，包含紧凑布局、普通处理方式选择行和路线图，不包含 CPU 优化实现；未授权设备安装/重启。额外改动仅为版本号、工作流接入已有新测试、实际包标记检查和对应冻结门禁。以下为先前本地候选记录，原生编译/验包结果以后续构建回执为准。

## 本地候选阶段记录

基于已确认正常的 ui2 `cd0b34807c031d2e179f1ae397ea8c6847be35e3`，新分支 `feat/compact-prefs`，工作树 `/var/minis/workspace/vedette-compact`。本轮只改显示布局；CPU/日志/配置逻辑仅审查，没有实施。未 commit/push/云构建/安装/重启，尚无新 deb。control 仍为 ui2，仅作为源码基线，不可用同版本发布新包。

## 已实现

- 普通首页、应用/daemon列表、关于页行高默认目标44pt，随系统字体增大；C安全下限≥44。真正行高由delegate返回，不是只修改estimatedRowHeight。
- 详情页开关和处理方式行紧凑化，文本输入保留原生行高。本次针对用户“按钮突兀”反馈，将独立PSSegmentCell改为“处理方式／当前值 ›”普通选择行，与CPU上限、时间窗口同组；点击进入系统PSListItemsController选择终止/限速。两个原帮助段落合并到同组footer，不删除警告。没有新造自定义按钮或更改策略保存回调。
- 头卡图标48→40pt，标题22→20pt，上下padding20→12pt；仍使用完整约束、可多行和UITableViewAutomaticDimension，不手算横屏宽度。
- 明确移除sectionHeaderTopPadding。空首组8pt、其余空组12pt、空footer4pt；文字header/footer使用局部可复用原生view和多行自动测高，文字/中文资源没有删除。
- 普通行名称单行尾部省略，防止紧凑行内挤成多行；完整名称和标识仍保存在specifiers及详情头卡。动态字体不缩字，字号改变重新计算行高。
- 保留ui2的cellForRowAtIndexPath→样式→返回同一cell，新增可选section delegates自行实现，不调用未知父类方法。没有global UIAppearance、负inset或导航栏布局改动。
- 启用置顶、名称搜索、返回刷新、保存键/默认值、CPU及恢复策略均冻结。

## 验证

- 新 compact tests 6项通过，其中生产C度量函数经cc/clang实际运行12个边界输入和5000步下限/单调检查。
- 详情处理方式追加5项源码检查通过：同组顺序、旧大分段负对照、enum/default和回调接线、保存及时间窗口更新函数与ui2逐字相同。参考并核对PSControlTableCell/PSListItemsController公开Theos头及Kayoko/PullOver X源码后，选择更小改动的原生PSLinkListCell，而非引入自定义分段按钮。
- 新 `preview/process.html` 已在428×926实开，处理方式当前值、进入选择、取消保留、终止/限速对应时间窗口状态、255输入保留等8项交互检查通过；示例数据不操作设备，也不证明原生UIKit选择回调已经运行。
- 原UI资源测试9项、iOS15闪退回归2项通过；原CPU identity/policy两套C测试、1000组排序oracle、auto monitor源码契约通过。
- 跟ui2逐文件验证：只有8个已列UI文件有变更，后端/资源/脚本/版本/workflow/排序与枚举器和原测试不变。新增只含计划、UI指标头和新测试/本报告。
- 独立只读原生源码复核覆盖上一阶段间距/测高改动，没有找到阻断项或P2缺陷；不将其扩大为后续原生选择行已独审/已真机验证。详情见仓库外 compact-audit.md。
- HTML对照预览428×926实开：首页示例内容高度649→515px，减少134px，8项交互/布局检查通过；这是HTML预览测量，不是UIKit或耗电基准。初次截图因浏览器页状态丢失为空，重载后已实际看见正确画面，不计空截图为验证成功。

## 边界

新UI没有原生iOS编译/真机结果。需验证极大字号、横屏安全区、多行footer、长名称详情、实际自适应header/footer与重用。默认44pt是布局目标，不保证所有系统环境或控件最终高度完全相同。用户确认过的是原ui2，不是这个尚未构建的候选。

## CPU 审查摘要（未实现）

优先减插件自身工作：Release日志惰性构造（ui2实际二进制已证实空函数前仍构造字典/NSNumber）、可信端归一化配置复用、全无启用且无待恢复目标时跳过无效扫描。之后才考虑reload的成功目标差量下发、LS成功结果的单扫描缓存、设置预览复用快照。不要删PID生命周期校验、通知补扫或恢复失败处理。

当前没有前台/后台差异策略；更低限额不等于更省电。对前台App强限速可能增加卡顿，Fatal可能形成进程重启/重试，需要真实CPU时间/完成时长/能耗对照再选阈值。

资料在 `/var/minis/workspace/vedette-efficiency-review/`：cpu-efficiency.md、release-logging-evidence.md、compact-audit.md、preview/index.html。
