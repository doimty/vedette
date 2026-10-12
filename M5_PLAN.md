# M5 整合计划：内存／回收优先级写入引擎（接入层）

状态：2026-10-13 实施中。本批次＝apply 引擎设计＋假后端＋宿主测试＋UI 接线设计；**不改**运行时管理器（VDTProcessManager.mm 保持冻结）、**不接**设备写入、不做 Makefile/CI 改动。
依据：`MEMORY_PLAN.md` §三／§五／§六；设备证据 `vedette-memory-plan/m2..m4`（M2 自定义对读回；M3 无限机制＋用户裁定「禁止无证据的大数冒充」；M4 band 语义与优先级↔限额联动）。

## 1. 目标与分层

```
配置(plist) ──► VDT*Policy（已冻结的纯策略核：解析/校验/分类/继承选择）
                    │  VDTMemoryPlan / VDTJetsamPlan（抽象意图，无 syscall）
                    ▼
              VDTResourceApply（本批次新增：意图→有序操作程序；执行编排；
                    │            能力门禁；身份前后复核；部分失败报告；撤销记录）
                    ▼
              VDTResourceBackend（本批次新增：可注入边界，vtable）
                    ├── tests/fake_resource_backend（宿主假后端，含 M4 实测的联动模型）
                    └── 生产后端（后续批次：真 syscall；仅当能力通过后由管理器接线）
```

不变式：
- 引擎内部 **没有** syscall／无动态内存分配；一切副作用经后端 vtable。
- 策略核输出视为唯一意图来源；引擎不得偷偷放宽或改写核心判定（含 raw 版本校验、混配拒绝、保留档拒绝）。
- 单资源失败不得中止另一资源；不宣称跨资源原子事务。

## 2. 能力门禁（capabilities）

`VDTApplyCapabilities` 默认全 false，逐项对应已取得的证据；未置位的门禁使对应意图以 `CapabilityMissing` 跳过（fail-closed）：

| 能力 | 证据 |
|---|---|
| `writeMemoryCustom` | M2：正数对可写可读、字段独立、进程消亡不继承、90s 稳定 |
| `writeMemoryUnlimited` | M3：`SET(INT32_MAX,INT32_MAX,attrs=0)` 实测生效 ≈2.2518PB；frida `without_limits` 先例；用户裁定后允许（有证据） |
| `writeJetsamBand` | M4：0..21 域校验、-1/-2/老化档语义、`EINVAL` 边界 |
| `restoreWriteback` | M2/M3/M4：写回已读回的现场值（非 CAS，只能报告未确认状态） |

生产写入口在本批次维持关闭；只有管理器层显式置位后才可能生效（后续批次）。

## 3. 意图 → 操作的映射（引擎解析规则）

| 核心计划 | 引擎动作 |
|---|---|
| Memory `Ready`（Custom/Custom） | `SetMemory`：整对写 `{a, FATAL, i, FATAL}`（首版＝硬上限语义，MEMORY_PLAN §一）；无门禁→跳过 |
| Memory `Unsupported(UnlimitedUnverified)` | 仅当 **active 与 inactive 双侧都是 Unlimited** 且 `writeMemoryUnlimited`：`SetMemory`＝`{INT32_MAX,0,INT32_MAX,0}`；其余（单侧无限、混配）保持跳过 |
| Memory `Unsupported(其余)` | 跳过（Unsupported） |
| Memory `NoWrite` / `RestoreRequired` | 跳过（NoWrite）／门禁全则 `RestoreMemory`（写回记录对） |
| Memory `ReadOnly` | 跳过（ReadOnly） |
| Jetsam `Ready` | `SetPriority`＝核心解析出的数值（named 已按目标 Darwin 映射；raw 已过同版本校验）；无门禁→跳过 |
| Jetsam `NoWrite` / `RestoreRequired` / 其余 | 同上模式（RestorePriority 写回记录值） |

常量与证据同处一文件（`VDTResourceApply.h`），突变测试钉死 `INT32_MAX`／attrs=0／attrs=1 的取值，防回归成「-1 哨兵」「nonfatal 伪装」。

## 4. 顺序、联动与部分失败（产品集成规则）

- **规范顺序：优先级在前、内存在后**（构建器固定；撤销同顺序）。理由：内存对写入自带「按当前活跃状态选择 active/inactive 缓存并重写 ledger」；让它最后执行使最终生效值由内存操作单独封定，与 M4 实测（跨 FG 边界翻转缓存）解耦且可测。两种顺序的**最终**生效值等价（M4 证据），固定顺序是为了确定性与可测性。
- 假后端把 M4 实测行为建模进宿主测试：priority 变更按 `≥10` 阈值切换 enforced 字段；内存写入重算 enforced；测试断言最终 enforced 值与调用顺序。
- 部分失败：两侧独立记账（`memoryOutcome`/`jetsamOutcome`）；`partial=一侧生效∧另一侧失败或非 NoWrite 跳过`；任何一侧失败后**继续**执行另一侧。
- 身份复核：任何写入前后都要 `getInstanceToken` 且与期望 token 匹配；不可读／不匹配 → 两侧跳过（fail-closed）。读前置失败（GET 失败）同样跳过该资源，不把默认值写进记录。
- 非 CAS 声明：写回是「读-改-写」，可能覆盖系统后续写入；回读不一致一律落 `Unverified/Unconfirmed` 状态，由管理器上报（监控漂移，不抢写）。

## 5. 记录与撤销

每次执行产生 `VDTApplyReport`：前/后身份、两侧结果、前后读回、跳过原因、partial。
管理器持久化的撤销来源＝用户规则生效前记录的**读回值**（memlimit 整对；priority 读回的 effective 值，记录「来自读回、非 requested」的语义限制）。撤销＝`RestoreRequired` 计划 + `restoreWriteback` 门禁 + 记录存在，三步缺一不写。

## 6. 测试策略（本批次）

- `tests/test_resource_apply.c`：断言式场景（能力门禁、custom/unlimited/restore、身份 fail-closed、部分失败双向、顺序与联动、coercion 呈现、跳过分类、静态约束）。
- `tests/test_resource_apply.py`：编译真实生产 C＋运行；**变异测试**（13 条行为突变必须编译后被杀）；符号审计（无 syscall/malloc/OS 导入）；C++ 头文件语法检查。
- 已冻结的核与旧门禁不动；新测试独立运行（沿用 M1 约定，暂不接 Makefile，CI 接线留 M6）。

## 7. UI 接线（首批已实施 2026-10-13）

实施状态：段落与独立存储已落地（见 §8 更新与 m5-integration 报告第二批）；**应用状态的动态显示、扩展资源级继承按钮仍留待运行时接线批次**。设计要点（实施时已遵循）：

- 位置：每进程配置页沿用 ui2 原生分组样式，在现有 CPU 参数之外**追加**「内存」与「回收优先级」两个独立分段；CPU 页不动。
- 保存与生效分离展示：保存成功≠生效；状态枚举（未生效／已写入／回读一致／回读不一致／部分成功／待恢复）必须来自引擎报告，不虚构。
- iOS15 安全约束：不用 `tableView` getter 等私有访问；不碰 backgroundConfiguration 重绘（沿用 UI_CRASH_FIX 与 ui2 结论）；新增选择行复用 `VDTActionListController`／`PSListItemsController` 既有安全路径。
- 扩展继承：内存/优先级开关与 CPU 独立；「跟随所属 App」只删除对应资源的记录。

## 8. 本批次不做（边界）

- 不接线 `VDTProcessManager`／不起后台任务／不新增扫描器；不写 plist 存储与 UI 代码；不接 Makefile/CI；不连设备（引擎与假后端只在 iSH 编译运行）。
- 2026-10-13 更新：UI 段落与 `memoryRules`/`jetsamRules` 独立存储已作为第二批落地（含逆投影补丁与负例门禁）；`VDTProcessManager` 接线、CI 接线与设备侧仍未开始。
- 2026-10-13 更新二：管理器与运行时的资源接入第一落地完成（加载/继承/仅资源目标/应用阶段；写入通道保持关闭）。后续：真实写入后端、恢复/漂移记录与能力启用（M6），CI 接线仍在 M6。
