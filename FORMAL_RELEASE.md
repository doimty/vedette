# Vedette 1.1.13-2 正式修复

本轮授权：扩展 nice 完整接线、CPU/nice/内存/Jetsam 任一独立开关置顶，正式版本编译、验收后软件源更新；不自动安装设备。2026-10-13 用户明确改为保持开源，并授权将本轮候选推回原公开仓库 `doimty/vedette` 的新 `release/1.1.13` 分支；不改默认分支，不公开其他项目或凭据。

## 实现

- Extension nice 独立存储与严格 `.appex`/执行路径/启动时间身份；无自身 nice 字段继承宿主，disabled/invalid 自身记录阻断继承。CPU 与 nice 的存在/继承/解析/launch/retry/apply 完全分开。
- 持久 nice journal 保留扩展真实身份、宿主来源和 revision；当前规则 source-aware receipt，旧 App/Daemon journal 与卸载尽力恢复行为保留。
- 三类型四类独立开关统一置顶；全局执行开关不改变分组，填值不自动启用，继承本身不算独立置顶。扩展资源/nice-only 副标题不再误报整体跟随宿主。
- nice Follow 只清 nice 三字段；CPU Follow 只清 CPU 四字段，清全部重复 ID、保留另一族及所有资源段。保存失败不广播成功，界面回读旧值并反馈。
- 混合重复记录采用首个该族 intent，disabled/invalid 阻断后续；保存选择与读/执行一致，切 nice 开关不把后行数值意外改0。nice hotpath 用 serial queue 规范化快照，避免逐 PID 反复解析。
- 同配置代次的瞬态 nice 读写/身份/验证失败最多初始加两次延时尝试；每次仍执行出生时间/路径/元数据、journal 和读回护栏，Conflict、参数和权限终态不自动重写。配置重载使旧延时任务失效；Gone 实例 journal 清理也有独立预算。只用一条合并任务，不扫描 PID 或重新执行 CPU。手动 Retry 开新预算。
- 回执生成时间与各目标实际尝试时间分离；checkedAt/oldestCheckedAt 来自真正执行，重复 publish 不伪造观测。界面显示上次检查和上次读回，不声称实时值；外部覆盖需显式重试后报 Conflict，不自动抢写。
- 四个遗留 CHP ObjC 类和一个协议均改为 Vedette 自有 VDT 名称，根入口和父控制器引用同步；保留原文件路径、上游 MIT 版权及现有偏好域。扩展目录改为进程内共享只读 metadata 快照，安装/卸载/更新、显式刷新及300秒入口漏事件兜底才重扫；规则、搜索和暖返回不反复枚举。刷新失败保留旧成功快照、退出 Loading 并提供 Retry。守护原 singleton 门禁保留、状态/observer 改为主队列，增加错误检查/显式刷新并移除未参与展示的主线程 Mach-O 建议扫描。
- 页面目录回填在 didAppear 前/离页时仅标记待更新，避免转场中立即 reload。此为实现护栏，不等于已修复冷 push 或 PanCake 转场，仍需真实 UI 验收。Settings进程重启后的首次枚举仍有成本，本批不引入磁盘缓存，也不把UI目录用作实时PID身份。
- 云构建改为一个独立全量原生门禁，成功后依赖式双环境打包；不重复两份 Foundation/变异套件。

## 证据边界

- iSH `make -f Makefile.tests test` 全量通过；Foundation native 按设计 SKIP 77，不能当 PASS。
- 新 UI 独立门禁8 tests / 11错误变体静态拒绝；资源原文门禁17 tests。正式字面投影扣除指定路径的唯一字面区域回到固定1dfce93，再串完整788发布/历史CPU与UI冻结，未知差异负例仍拒；本批类命名/目录/重试/CI布局纳入逐字可审阅patch，不清空冻结。
- Linux真实生产C的有界重试预算（4编译后断言变体）与目录状态机（3编译后断言变体）已执行通过；并发失效、旧代次拒绝、暖失败保留和明确重试均有断言。新Foundation夹具覆盖不reload的恢复、三次上限、Gone清理、旧延时任务、真实目录扫描及CHP假类并存；本地只完成SDK编译，实际Foundation执行必须由新云原生门禁验证。
- 双架构 iPhoneOS16.5 SDK：扩展 nice 真实 TU 与fakekernel fixture均通过；UI生产原文 + 两套fixture×2架构8个语法编译通过。不是Applelink/native/真机证明。
- 独审发现重复记录F1/F2与CPUFollow失败反馈F4，已修并补真实文件测试；宿主CPU-only无nice继承F3也加固。原报告为变更前快照，不篡改原结论。
- Cloud CI已接 `--require-native` 两新套件，原 nice/SpringBoard/资源保存原生必须继续执行；待新run实际验证，没有借旧run包冒充正式包。

## 发布与兼容性

正式版本 **1.1.13-2** 大于1.1.13-1+rc1，已dpkg核验。用户已明确选择继续开源，本轮提交将推回原公开 `doimty/vedette` 的新 `release/1.1.13` 分支；旧 `main` 和 `feat/release-resource-rules` 保持不变。此前建立的私有仓库不删除、不改为公开，也不公开其他项目历史。

私有CI的扩展nice真实Foundation baseline及6个runtime变异已执行通过；整体原生回归仍未全绿。最后的旧候选 `0e4cd02` 因GitHub账户计费限制未启动runner，不能算编译失败或通过；本批接续修复后由公开仓库做新的完整验证，仍须逐项核验新run与产物。

用户确认另一机装PanCake，第二段搜索滑返不能视为纯原生gesturebaseline；不强制开启/禁用返回手势。真机冷push卡顿与PanCake search/popcancel兼容仍待A/B，未声称已修UI阻塞，不拿Foundation测试证明真机转场。

内存/Jetsam生产backend NULL、所有写能力false，本轮仅配置/列表，不宣称两侧生效。

GPLv3许可证和对应源码继续公开保留。公开源码授权已明确，不再作为发布阻断；完整原生回归、双环境成品核验和真实UI验收仍独立保留，不能用公开构建代替这些条件。在正式包验收前不发布APT，不自动装机。

详细checkpoint、独审与本地日志：`vedette-final-1113/`；本批计划/SDK对象/合同结果：`vedette-public-1113/continuation-0e4cd02/`。新包须核真实CI SHA，不拿旧rc1或未运行的候选充交付。
