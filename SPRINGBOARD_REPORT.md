# SpringBoard 入口修订报告

## 改动

在 `a054671` 的待发布1.1.12基线上，版本修订提升为 **1.1.12-2**，不和上一轮-1成品混用。

- 守护进程目录预置一个名称为SpringBoard的系统条目，再使用原有发现/去重/排序逻辑；移除明确排除com.apple.SpringBoard的条件。预置目录条目不是写入已启用配置，也不表示进程一定正在运行。
- 新 `VDTSpringBoardIdentity.h` 集中定义唯一路径 `/System/Library/CoreServices/SpringBoard.app/SpringBoard`。本轮只读系统plist/Info及proc_pidpath核实此身份；从RootHide终端读取文件须用/rootfs视图，但**运行时不接受/rootfs或/var/jb前缀冒充系统路径**。
- `VDTProcessManager` 只对上述精确系统路径优先选择显式daemon规则SpringBoard，并保留第一条配置优先（含disabled）。没有该daemon配置时，原App规则解析仍可用；手工同时存在两种规则时，显式daemon条目优先，避免关闭该行后旧App配置又启用同目标。
- generic daemon路径永远跳过保留名SpringBoard，不能靠同名可执行文件或p_comm降级匹配。其他.app禁止落入daemon的原保护不变。
- CPU策略函数、nice状态机/原值日志/回读恢复、旧配置保存setter、两套安装卸载脚本、工具签名权限、过滤器和ui21视觉源均未改。只开放入口，不自动调整设备。既有敏感项确认和默认false都保留。

## 提交前验证

- 修改前基线及修改后 `make -f Makefile.tests test` 通过；原process identity、CPU policy两个C套件与auto-monitor契约通过。
- 生产路径helper43个检查，cc/clang各跑同一套；错误前缀/包含匹配的可执行变异被拒。
- 新增6项入口/精确增量/同名拒绝/确认默认值/原生门禁契约通过。旧冻结测试只减去逐字列明的两文件差分，其他改动仍拒绝。
- 新原生测试使用**真正的VDTProcessManager与VDTNiceRuntime**，但所有proc/CPU/nice调用均为fake kernel，并使用隔离临时文件和测试LS代理，不定义同名系统类。覆盖无LaunchServices代理仍解析、nice-only与CPU-only、原值-1、更新/关闭/删除/全局关闭、同名假路径拒绝、其他App保护、手工双规则优先级、PID复用和路径不可验证不写/保留记录。
- 云runner会实跑候选，再用同一断言拒绝a054671的真实旧解析器，且核失败位置为匹配数量不是其他环境错误。本机Alpine无Foundation，**提交前未原生执行，不计为通过**。
- 已做arm64/arm64e SDK语法检查：新集成测试和列表源，以及旧解析器负例可编译；依赖路径/日志用测试stub，不是Apple完整链接或UIKit验收。
- 独立复核子任务超时无交付，不计独审通过；以上证据均由主代理直接核验。

## 后续和边界

沿用已经授权的双环境云构建与软件源发布流程，发布前必须实读两job测试日志并核验实际-2包。未在设备执行任何真实nice/CPU写入、安装或重启；新增入口的UIKit视觉、真实SpringBoard调度权限与长期稳定性仍需用户按实际需求验证。关键进程可能影响系统响应，确认提示不移除。不把本次补齐匹配扩大为旧CPU批量恢复R1已解决或节能收益。
