# Portable nice 状态机验证报告

## 交付
- `VDTNicePolicy.h/.c`：仅依赖标准 C 与 `sys/types.h`；nice 有效范围固定 `-20..20`，pid 必须大于零。PID 1 / self 拒绝属于 runtime 职责。
- `VDTNiceRecord` 保留首次原值、最后已知受管值与待写 intent。回调提供 identity/read/write/store；回调错误按 errno 返回。
- `VDTNiceTransition` 对每一次 kernel read/write 单独先做 identity 检查。未接管且 disabled 直接 `VDTNiceUnmanaged`，不触碰任何回调。
- 首次接管先持久化原值与 intent，再复读确认、写入、复读验证，最后提交 ownership；更新始终保留首次原值。恢复也先保存 intent，验证回读后才删除记录。
- 保存成功才推进调用方 record；删除成功后零初始化。保存/写入/验证失败会保留可恢复状态；PID Gone 才移除已有记录；Unavailable 保留记录；未知当前值返回 Conflict。
- 相同目标值不写内核；首次 no-op 仍持久化原值。允许读值 `-1`，仅 callback errno 表示读取失败。

## C 命名约束说明
C11 的 enum 常量在全局命名空间；契约同时要求 identity 枚举值和 outcome 枚举值都叫 `VDTNiceIdentityUnavailable`，两者不能以同名 enum enumerator 同时声明。保留要求的 outcome 名 `VDTNiceIdentityUnavailable`；identity callback 使用 `VDTNiceIdentityUnavailableValue`，语义对应 identity unavailable。其余 API/结果名按契约。

## 测试
Fake callbacks 覆盖边界值、非法入参/record、未接管 no-op、首次捕捉 no-op、首次 set→update→restore 原值、无写 no-op、apply/restore 每个 identity gate 的 Unavailable、未知 identity enum fail-closed、Gone 与删除失败、每个 read 阶段失败、EPERM、guard mismatch、readback mismatch、apply/restore 每个 store 阶段失败（包含恢复已写原值后删除失败）、intent 写前/写后崩溃恢复、restore 重试、外部改值冲突、PID 生命周期变化、原值不覆盖、失败保存不推进内存 record，以及 callback 顺序。

本地命令及结果：
```sh
cc -std=c11 -O2 -Wall -Wextra -Werror VDTNicePolicy.c tests/test_nice_policy.c -o /tmp/test_nice_policy_cc
/tmp/test_nice_policy_cc
# nice policy tests passed
clang -std=c11 -O2 -Wall -Wextra -Werror VDTNicePolicy.c tests/test_nice_policy.c -o /tmp/test_nice_policy_clang
/tmp/test_nice_policy_clang
# nice policy tests passed
```

## 边界 / 未验证
- 本轮未执行实际 iOS/runningboardd 权限测试、Apple SDK 构建、runtime/UI/build 接入；无原生 nice syscall、真机操作或权限结论。
- Callback identity/read/write 间仍非内核原子 CAS；运行时需串行化，并提供可靠的 PID 实例身份检查及安全持久化。
- process record 的启动时间/boot 标识绑定、PID 1/self 检查、配置/schema/卸载恢复与 UI 回执均留给 runtime 集成。
- 本轮仅编译并运行新增 portable C fake-callback 测试，未声称其它仓库测试已运行。
