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

## 进行中的正式补丁（历史 rc1 完成记录保持不改）

用户后续明确指出Extension nice与资源置顶遗漏，授权修复并正式发包。本轮选1.1.13-2（dpkg大于rc1），工作分支release/1.1.13，非fork私有库doimty/vedette-private。扩展nice独立resolver/lifecycle/来源/恢复、四侧enablepin、按族Follow/失败反馈及混合重复记录一致性已接；全量本地与双架构SDK通过，新增Foundation原生留CI实际验证。旧App/Daemon固定发布合同经本轮正式逐字投影后继续冻住，原策略、工具、卸载脚本未动。详 [FORMAL_RELEASE.md](FORMAL_RELEASE.md)。

相较最初只重建的授权，现允许commit/push私有新分支/云编译及验收后更新软件源，但GPL对应源码公开归档尚待用户确认。未安装/改设备，未新CI或发APT；本地SKIP非PASS。PanCake兼容与真实冷pushUI仍未验收，不用host模型充真机。资源backend仍NULL/能力全false。

## 完成回执（2026-10-13）

- 正确基线整合提交 `1dfce93bd54b83292b1547d6a608a180fb4cd8b4` 的第一父提交为正式 `788f43b`，第二父为旧候选 `bb211c0`；只推新功能分支，默认 `main` 仍 `0766c23812aa7255a1d4218d9ef5de3914adbf07`。
- [run 38340606214](https://github.com/doimty/vedette/actions/runs/38340606214) **rootless 与 roothide 双 job 全绿**，分别 10m42s / 9m55s；真实 nice Foundation 63 断言、当前 SpringBoard 解析/nice 52 断言、资源控件原文 + VDTShared 文件回读（95 次成功保存）均实际执行。旧解析器和旧错误 getter 的编译后负对照被真实断言拒绝，未用 SKIP 替代 native。
- 原 CPU/UI/nice/存储/卸载/权限门禁保留；策略/引擎各 15 个行为变异编译后断言击杀。投影先回固定发布 788，再接历史链；41 个逐区域 hunk 和明确单字段增量，不把当前文件哈希当 oracle。
- 两包各含 3 个 arm64+arm64e Mach-O / minOS15 / sdk17.5，代码页哈希和 nice 四权限绑定检查通过；en/zh-Hans 各 129 键资源字节匹配。此证据不等于设备信任/加载或真机 UIKit 验收。
- RootHide：167,400 B，SHA-256 `b126d9d52dfc1c5a2d8e407251cb3e440345dc1c05587dd72556e3ac8a5c7d35`。
- rootless：169,464 B，SHA-256 `92d34855b9ccf7a29e228451c96e17ac700e384c135395722f7fc9a38b8018a8`。
- 独审限定范围未发现已证阻断；其中 native/写失败夹具待证项已由最终 CI 日志闭环，PSSwitchCell 真机回调类型及 UIKit 渲染仍未验证。
- 产物与详细报告：`vedette-rebuild-1113/run-38340606214/`；稳定交付：`shared/vedette-rebuild-1113-run-38340606214/`。仍不安装、不发布、不改设备；内存/Jetsam 写能力全 false、backend NULL，未来启用另需资源独立生命周期与恢复记录，nice 既有功能完整保留。
