# SpringBoard 专用入口与严格身份匹配

## 范围与基线
- 最新指令“优化一下放开吧”：开放 SpringBoard 的守护进程入口，并修正真实执行匹配；不放宽其他系统App匹配，不自动启用规则或在设备上调nice/CPU。
- 当前未上线正式版基线 a054671a0a3f6b0c476d95906fd924687b5b3386（release/1.1.12）；两环境上一轮构建成功但下载中断，APT尚未发布。此修正合并进待发布版本，修订改为1.1.12-2，避免和已构建的-1混包。
- 已读AGENTS（本仓库无）、源码/旧测试/发布计划。修改前全套本地回归通过。源码关系工具此前缺解析器，无有效图；以实际源码调用链为证。

## 已核事实
- CHPDaemonList.m:107明确排除com.apple.SpringBoard；nice和CPU UI已有SpringBoard的敏感项确认。
- .app路径默认按App身份解析，不能靠删列表条件使daemon规则生效。
- 本轮只读核实：系统launchd Label=com.apple.SpringBoard；bundle ID=com.apple.springboard；程序与当前proc_pidpath均为 `/System/Library/CoreServices/SpringBoard.app/SpringBoard`。RootHide终端/System视图未见文件，但/rootfs视图读到原文件；这不是Settings不可见证据。未运行任何设置nice或重启命令。

## 最小方案
1. 在现有daemon目录中种入唯一的已知SpringBoard条目，名字/配置key仍为SpringBoard，type仍Daemon。不依赖LaunchServices把它列为普通App。保留现有重复名称去重和原生排序；移除旧明确排除。
2. `SpringBoard` 保留为系统专用规则名：仅完整可执行路径严格等于上述系统路径才匹配；不接受仅basename、p_comm、其他App内同名程序、RootHide镜像或任意后缀。
3. 只为该精确系统路径检查显式daemon规则，第一条配置优先（含disabled）。未设该条则沿用旧App解析；若手工配置同时有App与daemon规则，以显式SpringBoard daemon项为准，避免双重执行。其他.app禁止落入daemon的保护原样保留。
4. 目标依旧携带同一PID/启动时间/完整路径，CPU和nice所有读写前仍走原fresh guard。CPU限制、nice值和恢复状态机不改。
5. 两开关默认关闭、CPU和nice分别确认、Preferences/launchd/runningboardd禁项等维持原样。列表可见不等于已对设备采取策略。

## 验收与独立失败信号
- 原列表代码会拒绝SpringBoard；新列表种入一个且不重复，不加入已启用默认值。
- 生产身份helper的正反测试：真实完整路径成功；nil/空/同名其他路径/大小写/后缀/子进程/仅名字失败。
- 真正生产VDTProcessManager在Foundation+fake proc API下执行：daemon解析、没有LS代理、仅nice启用、CPU-only、默认disabled、global off、App/daemon双规则优先级、所有其他App保护、PID复用/路径变化拒写、关闭/删除恢复。
- C tests及SDK语法可本地运行；Foundation集成必须在macOS CI运行，Linux返回77 SKIP不得计为pass。测试不写真实设备策略。
- 旧冻结断言只允许这里列明的解析/list增量，不能放过其他CPU源变更；保留旧负例并新增错误matcher的可执行变异拒绝。
- 重编rootless/roothide，核实际版本/路径/依赖/签名权限与原算法冻结；只发布新-2产物，不发布旧-1。之前三旧APT Vedette保留备份，其他75包不得改。

## 边界
路径一致+进程实例复验不是内核原子CAS。源码/模拟内核及云构建可证明入口接通，不等于真实SpringBoard已调值或权限已验；真机调参仍由用户选择，关键进程警告保留。
