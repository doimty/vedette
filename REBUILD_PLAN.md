# Vedette 完整发布基线重建

## 目标与范围

用户明确要求「重新从正确基线构建」。固定完整发布基线 `788f43bcb17a2c3890ed8bdeea3f1a97660e13c7`（release/1.1.12，Version 1.1.12-3），从该提交新建 `feat/release-resource-rules`，三方整合旧候选 `bb211c0`。候选版本独立设为 **1.1.13-1+rc1**，不复用旧同版本不同字节包。

保留：nice UI/策略/运行时/持久化/控制工具/工具权限；App/Daemon nice 类型边界；SpringBoard 精确路径与明确daemon规则优先；卸载尽力恢复、不删journal；rootless+roothide双包及原生旧门禁。

合入：扩展CPU规则/目录和严格执行文件身份；按资源独立继承的memory/jetsam配置/策略/引擎；修资源getter、文本整数转换和保存失败反馈。**资源生产写能力仍全部关闭，backend NULL；本轮不接通真实内存写入，不添加未经验证的extension nice。**

## 成功标准与失败信号

- 正确基线必须是新HEAD祖先，nice核心不得丢失或被UI空壳替换；原CPU/nice/SpringBoard/卸载合同与负例保留。
- 两条基线冻结链以精确可审阅增量组合，不用当前文件全文/hash作为新行为oracle，不放宽输入或符号白名单。
- 新保存getter必须存在且符合Preferences一参getter ABI，非法/浮点/垃圾/溢出整数不修改文件，失败反馈+回读旧值，写文件成功才通知。
- 新旧套件实际运行；Foundation真实执行与UIKit/真机区分，iSH SKIP不当native证据。旧错selector/整数类型写法要被负例拒绝。
- 两个新deb的三个Mach-O（含nicectl）均双架构、minOS15，nice entitlement/layout/权限及资源验证通过。SHA/CI HEAD固定。

失败信号：nice任一层丢失；Extension误落daemon nice存储；SpringBoard精确规则丢失；资源失败绑定CPU/nice；删除journal/阻塞卸载；门禁被删除或无条件接受候选；不存在getter仍被绑定；CI未实际执行native；默认分支变更。

## 执行与证据

本地独立工作树 `/var/minis/workspace/vedette-release-resources`；旧发布树和旧内存树不改。分工隔离UI/core/test冲突整合。详细验证与回执位于 `vedette-rebuild-1113/`。每筆拟用说明和提交对象按commit-check A/B检查，只推新分支云构建。**不安装、不改设备、不发布APT、不改默认分支。**

当前阶段：整合及回归。后续状态只以完整云日志、工件本地独立核验和最终交付报告为准。
