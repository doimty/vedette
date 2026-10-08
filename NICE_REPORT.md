# Vedette nice1 本地实现报告

> 云构建阶段（2026-10-08）：用户已明确授权提交、推送新分支 `feat/nice-priority` 并执行 GitHub Actions。下文是提交前本地验证快照，不把它当成最终云构建回执；云端与成品结果以本次 Actions 和交付目录的 build.json 为准。仍未授权安装或真实 nice 调参。

## 结论与交付状态

已在隔离分支 `feat/nice-priority` 完成独立 nice 的**本地候选**，版本 `1.1.11-1+nice1`。基线与当前未提交 HEAD 均为 `2994f24bbc73a6081d958f8f64ba4ff76640b8af`，源码在 `workspace/vedette-nice`；原 `vedette-ui21` 工作树未改。

**未 commit/push、未触发 GitHub Actions、未产出新 deb、未安装/附加或修改任何真机参数。** 以下“实现”不等于已证明用户设备的 runningboardd 有设置 nice/写状态目录的权限。完整 Apple 构建及执行端权限仍是发布前门槛。

## 使用和配置语义

- 保留 ui21/ui2 外观、留白与普通动作选择行。详情末尾添加原生 nice 组，独立开关默认关、真实整数 -20…20 的41项选择；预选0不是默认干预。
- 旧 `enabled` 仍控制 CPU，文字明确为“启用 CPU 限制”；新 `niceEnabled`/`niceValue` 与它独立。全局开关控制两者。nice-only 目标的 CPU 仍为禁用，不进入 CPU setter。
- 新 `niceRevision` 每次受检 nice 保存更新；旧规则无需迁移，无新键就不调整 nice。配置域、存储路径、旧CPU枚举/default/保存函数均保持原样。
- App/daemon 启用排序现在认 CPU 开启或严格Boolean的 nice 开启，仍只是“保存的配置”，不是内核实时状态。
- nice 数值越小，调度偏好越高；不是CPU百分比上限，不涉及Jetsam、保活、VM、前后台或能耗承诺。

## 执行与恢复

### 旁路复用现有执行端

`Vedette.xm` 只在 runningboardd 串行队列接入 nice：普通启动/配置流程使用原扫描结果；nice 有独立成功/失败缓存，不被 CPU 去重挡住。没有新Hook、新daemon或周期扫描。失败不会在一个配置代际的每次广播里不断重试；改配置或手动“检查/重试nice”后再尝试。

专用手动检查只执行 nice，不调用 CPU 策略；100ms延迟只合并事件。保存 nice 仍发既有 prefs-changed 通知，因此原有全配置重载（含已启用CPU规则按旧逻辑重应用）保持不变，不把这一点说成“保存nice不会触碰任何其他CPU规则”。

### 每目标原值和意图

- `VDTNicePolicy.c` 是独立可测试状态机；原生适配使用 `setpriority(PRIO_PROCESS, PID, value)`，`getpriority=-1` 只有 errno 非0才是失败。
- 首次捕获原值，任何可能改变 nice 的操作前先保存原值与待写意图；之后更新值不覆盖原值。写后再次核验身份并回读，回读不符/权限失败/状态保存失败不报告成功。
- 同实例以 PID、启动时间、完整路径/受限名称绑定。读取失败保留记录，只有明确 ESRCH 或启动时间变化才作为旧实例消失处理。不能以一个 BOOL 失败就清空记录。
- 关闭、删除、全局关闭、重置都会尝试恢复原值，失败保留。已知值之外的外部改动报告冲突，不抢写其他工具的设置。
- 恢复不使用固定0。过程中的回调上下文强持有目标，避免替换持久记录时留下悬空引用。

### 存储约束

候选运行时通过 `jbroot` 定位 `/var/tmp/com.doimty.vedette.nice`，本轮未在设备创建它。

- 专用目录 root-owned 且无组/其他用户写权限；`journal.plist` 与卸载请求0600，界面只读的 `status.plist` 0644。
- 固定三个文件名，最终目录/文件 NOFOLLOW，常规文件、单硬链接、数字root属主、精确mode和2MiB上限校验；最多1024恢复记录，瞬态结果也有界。
- 文件内容fsync后原子rename，并重新核对目录身份。部分Darwin文件系统不支持目录fsync时容许EINVAL/ENOTSUP，**不宣称断电事务原子性**。
- 日志绑定开机时间，重启后不会把上一开机的PID记录应用到新实例；宿主重启读取原日志，不把已经调整过的值重新当原值。
- 现存记录的日志/目录丢失、损坏或权限异常不会被静默当成新安装。无法安全持久化时停止新的 nice 写入。

## 界面反馈与卸载

- nice 保存采用独立受检原子写入，保留全部旧CPU字段；坏plist不覆盖、非法key/value拒绝、写失败不发成功通知。
- 回执匹配 boot、revision、开关、合法性和数值；展示“最近回执（非实时）”、原值/回读值、待处理状态、具体失败类型。不是用保存开关冒充成功。
- UI主线程通知、弱引用与取消观察者；初次构建只更新footer属性，不在详情尚未建好时递归reload。
- 设置App、PID1与执行端自身禁止nice；已列关键进程启用时有独立确认。未自动启用任何系统项。
- 新增 **非setuid、非daemon** 的 root一次性 `vedette-nicectl`。真正卸载的prerm先写root请求并等待runningboardd暂停新nice写入、原值恢复完、匹配nonce的回执与空私有日志，最长约8秒。
- 恢复超时/失败阻止卸载，不靠postrm杀宿主冒充恢复；upgrade保留日志交新运行端。安装的resume只解除卸载暂停，不删除原值日志，随后沿用旧postinst的宿主重启。
- 无响应、外部改值冲突、损坏日志可能使卸载被拦，这是保留恢复线索的选择，不提供盲目清记录按钮。

## 本地验证结果

1. 基线回归先跑通过；最终 `make -f Makefile.tests test` 通过。
2. nice生产C状态机的fake callback套件：cc与clang严格C11 `-Wall -Wextra -Werror` 通过；原值-1、边界值、更新/恢复、身份变化/不可用、写失败、回读不符、各阶段存储失败、crash intent和外部冲突均有用例。
3. 安全文件存储 **76项** 正反检查通过（cc、clang各跑相同套件）：模式/属主、符号链接、硬链接、FIFO、超限、目录替换、错误路径等。nice状态机/存储均通过Clang UBSan；未称ASan已跑。
4. **12项新接入契约** 通过，包括原CPU文件逐字节冻结、精确允许增量、三种可执行错误实现被旧断言击中、归档负例，以及安装/卸载脚本全部外部命令mock后的成功/失败/upgrade分支。没有实际执行安装或killall。
5. 原 process identity、CPU policy C套件、auto-monitor契约、UI/资源/选择行/历史闪退/分组检查及1000个列表随机对照通过。
6. 现有iOS16.5 SDK（非本轮新装）＋与CI固定Theos对应的 `roothide/headers@ac1c4fd` 做 **20项 arm64/arm64e 语法检查**：新增C/ObjC/ObjC++、nice工具、集成测试、Vedette构造函数体通过。路径/日志依赖用语法stub；仅把唯一Logos `%ctor` 转换成普通函数用于检查其体。**这不是Apple编译链接、Logos完整构建或UIKit运行。**

旧冻结测试没有整片删除：`tests/nice_delta.py` 只接受逐字写明的 nice 插入/元数据变化，其余继续按旧基线比较；另加负例证实额外源码改动会拒绝。

## 已准备但未执行的验证

- `tests/test_nice_native.mm` + `run_nice_native_tests.sh`：真实Foundation/真实隔离文件、fake kernel的集成测试，覆盖归一化、nice-only、宿主重建、删除、PID复用、失败重试、坏/丢日志、跨boot、root卸载请求及回执版本、受检保存保留CPU键。
- 本机运行脚本明确返回 **77 SKIP**，因为Alpine没有Foundation runtime；不能算通过。其源码已通过上述SDK语法检查，未来macOS CI将显式执行。
- workflow已添加原生测试与成品门禁：新版本、自有包身份、控制工具数字root/0755（不是4755）、真实架构/签名load command、运行端导入setpriority而控制工具不导入。**尚无实际新归档可检查。**
- 完整独立审查任务未交付结论，没有计为独审通过；主代理直接读了实现、修正边界并实跑上述本地检查。

## 剩余风险与使用边界

- runningboardd 的MAC/沙盒与状态目录写权限未实测；root SSH能设置nice不代表这里能设置。权限失败应保持原状并留失败，不允许自动提权或偷偷换执行器。
- UIKit导航、分组footer刷新、选值回调和回执文件可读性尚未真机验收。SDK语法通过只能排除部分编译错误。
- PID检查与setpriority之间不是内核原子事务，外部同时修改nice也没有CAS锁；目录fd/路径复核也不能消除整个RootHide祖先拓扑被特权方更改的所有窗口。
- 文件内容可持久化不等于具备断电恢复证明。若外部把全部原值记录删除、且宿主也已重启，就无法凭空知道更早的nice基线；本版不承诺抵抗这种全证据丢失。
- 失败重试是显式/配置事件驱动，不是后台不停重试。外部冲突或无法确认身份会保留待恢复项，可能阻止卸载；应先恢复可验证状态再重试，不盲目清日志。
- **原CPU的批量恢复R1缺口没有在此批修复**，也没有改变其阈值/违例行为。nice拥有独立可恢复记录，不把它的保证扩大到旧CPU路径。
- 未采集耗电或流畅度对照，不宣称性能收益。

## 后续发布顺序

只有下一次获得对应授权后才 commit/push 并用现有GitHub Actions云构建；云门禁通过仍不等于真机验证。安装与真实nice修改另按明确授权执行，先在非关键目标验证：只开nice→回读→改值→关闭恢复→进程重启→宿主重启→失败反馈，再决定是否交付长期使用。

本轮证据在相邻 `workspace/vedette-nice-validation/`：`regression-final.log`、`syntax-results.json`、固定头文件manifest和可重跑脚本。源码/补丁交付材料放其 `delivery/`，不会包含任何设备凭据或真实进程数据。
