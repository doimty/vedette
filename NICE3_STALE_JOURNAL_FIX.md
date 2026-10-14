# Nice3：旧格式 journal 兼容修复

## 故障与证据
- 用户设备（1.1.13-3，RootHide）：设置页 nice 回执始终显示“状态不可用”，errno 22（EINVAL），待处理目标 0；App、守护进程、扩展的 nice 全部不生效。
- 拉取设备 `/var/tmp/com.doimty.vedette.nice/journal.plist`（18 条记录）：其中 3 条（微信/QQ/抖音的通知扩展）为旧版格式——扩展进程按 App 类型 + `.appex` 可执行路径记录（旧版“组件跟随主 App”时期产物）。
- 按现行校验逐条复算：18 条中仅这 3 条失败（`type != Extension` 但路径位于 `.appex`）；按旧版规则复算 0 失败，即该 journal 由“组件独立设置”之前、写入方尚不认识的版本写入。
- 现行 `load` 先逐条校验、后比对 boot；任一条失败即 `loadError = EINVAL`，reconcile/apply/save 全部 fail-closed，且该失败对文件内容而言是永久性的（重启不自愈）。这就是“加组件设置之后全部失效、连守护进程也不生效”的机制。

## 修复（仅读取路径）
1. boot 比对前移：来自其他 boot 的 journal 整体弃用（重写为空），不再对其逐条校验；旧 boot 的 PID+start 令牌本来就无意义。
2. 当前 boot 的 journal：无法解析的条目在“全新加载”时被丢弃（保留可解析条目并重写 journal），格式漂移不再锁死整个存储；进程仍持有内存记录时维持原严格 fail-closed。

## 边界
- 原子写入、root-only 存储、CPU/身份/执行语义与消息面未变；无法解析的文件整体仍 fail-closed。
- 被丢弃条目与跨 boot 弃用一样不可恢复原值基线；无法解析的记录本就不可用于恢复。

## 回归
- `tests/test_nice_native.mm`：旧 boot 含坏条目→整体弃用；同 boot 坏条目→丢弃且存储可用；持有内存记录时→保持 fail-closed。
- `tests/test_nice_contracts.py`：锁 boot 比对先于逐条校验、丢弃路径与重写形态。
- 设备侧处置：旧 journal 已备份至 `/var/tmp/vedette-nice-backup/`（2026-10-14），重载后设备可先恢复，无需等待新包。

## 云编译阶段（2026-10-14）
用户明确「编译」。源码修复已推送为 66c65d68b3a0e944b89b14efdd2e7523e243c9c8；此阶段仅将包及严格版本断言升级为 `1.1.13-4`，不改运行时修复、其他生产行为或原生回归夹具。
版本升级要求：严格 staging 拒绝已交付 `1.1.13-3`、`1.1.13-2` 和旧 rc1；新版本需严格大于它们；字面冻结不扩大允许范围。现有工作流通过 workflow_dispatch 在当前修复分支运行，先在 Darwin 真实执行包括新增 nice 恢复用例在内的原生门禁，通过后才生成 rootless 与 RootHide 双包。
成功标准为指定 SHA 的全部云任务 success、原生日志无 SKIP、下载工件版本/架构/依赖/权限/签名及归档哈希一致。任一编译或原生断言失败都不作为交付，不降低生产护栏或测试强度；按实际日志定点修复并复验。
此阶段仅授权云编译与产物核验，仍不安装、不发布 APT。云 run、tested SHA 和实际结果另留证，以上历史未完成项仅在取得证据后更新。
