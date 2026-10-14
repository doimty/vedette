# 资源写入与耐久恢复：1.1.14-1 构建候选

## 推送构建授权（2026-10-14）

用户追加“推送构建”授权，版本升为 `1.1.14-1`，将当前全放行候选推到公开仓库的新功能分支并运行 GitHub Actions。仍不包含安装、APT发布或业务PID写入。下面的“本地未提交/未构建”均为上个实现阶段的证据快照；本次构建、tested SHA、原生执行及成品结果以交付报告为准，不预先宣称通过。

基线 `4c9af10d6cb5c2a39a9ab94a1c9266994edbba26`；分支 `feat/resource-writeback-20261014`。用户“做收尾吧”授权本地实现，不含提交、推送、云构建、安装、APT 或业务 PID 写入。发布中的 `1.1.13-4` 仍是 NULL 后端/仅保存，不因本地候选变化而追改线上说明。

## 产品路径

- 新 `resourceWriteEnabled` 默认关闭，升级不自动施加旧保存规则。新写同时要求 Vedette 总开关、资源写入开关和具体规则开启。关闭/删除/重置按本生命周期的 journal 请求恢复，不能把 raw 0/-1 当作原系统状态。
- 用户随后明确要求“后端全放行，不要卡这么死”。本候选已删除机型、构建号、内核字符串及精确版本白名单，原生 iOS 15+ 后端可用；只保留 root/目标身份/读回/耐久恢复等操作保护，系统拒绝由真实返回值处理。策略接受 Darwin21 及后续版本，21 使用旧档，22+ 沿用现代档；这不是所有系统版本已经真机验收的声明。
- 固定系统传输：内存 GET/SET 命令 8/7，16 字节 active/attrs/inactive/attrs；单 PID priority GET 命令 1，严格检查返回 24 字节、PID、有效值及 user_data=0；priority SET 命令 2，16 字节，flags=0。读取失败不改调用者输出。非零 user_data 不写优先级，避免丢失无法恢复的数据。
- 每个真实回调复核目标；C 引擎逐操作复核出生 token，任一身份失效禁止后续写。PID<=1、管理进程自身、Preferences、runningboardd 拒写。路径/实例读取失败保留恢复证据，不能冒称进程消亡。
- 内存仅正数/正数或两侧 -1；混合默认/无限/自定义不偷放行。无限采用 M3 四证核验的 INT32_MAX/attrs=0，不把 SET(-1) 或 nonfatal 单独称为无限。高 Jetsam 档不免内存上限和全局回收。
- 新输入 raw priority 在同一次偏好写入保存 `sourceDarwinMajor`。旧条目缺来源不伪标为当前系统，需重新输入；跨 major 的 raw 值不自动换算。

## 执行与恢复

新增 `VDTResourceRuntime` 只在现有 runningboardd 串行队列使用；不新建守护服务或常驻轮询。资源启动/重载/100ms 合并补扫/有界延期不经过 CPU 的 launch 去重。CPU 策略核、身份核、nice runtime/store、已修列表字节保持冻结。

独立目录 `/var/tmp/com.doimty.vedette.resource`（按 RootHide/rootless 重定位）复用安全原子文件组件：

1. 保存目标实例、首次 original、last、待写 wanted/phase 后才 SET；保存失败零写。
2. original 不被再次改值覆盖；SET 成功但读回或提交失败保留意图，不当成未发生。
3. 同 boot 重启从 pending 重新观测；已达到 wanted 不重复 SET。未确认改道不反复抢写；发现外部漂移不覆盖。只允许与 last/wanted 匹配的当前值进入后续写。
4. 恢复也是先记录意图，确切读回原记录后才清该侧；部分失败保留另一侧。空 journal 最后提交失败可以重试，不陷入永久错误。
5. journal 存储 `darwinMajor`，original/last/wanted 与传输共同使用对应代际值域：Darwin21 为 0..21，22+ 为 0..210；现代 180/210 档可保存、重启后加载并恢复。同 boot 错配或损坏记录闭锁，不同 boot 丢弃旧实例恢复授权。不同 token/ESRCH 才能清消亡记录，无效 BSD 读数不算死亡。记录上限 2048，达到上限只拒新目标，不破坏既有恢复。
6. 初始动作+最多两次自动延期，成功/漂移/已确认改道不耗无效写预算。旧代次回调失效；没有无限强制覆写。
7. 移除使用 root 工具的 `resource-restore-for-removal`，以 boot+nonce、paused、storeError=0、recordCount=0 与实际空 journal 共同确认。失败保留文件，dpkg best-effort 继续；重装 `resource-resume` 解除移除暂停。

恢复使用 GET 观测值，**不是** requested/default/assertion 原系统策略的无损快照；read-compare-write **不是 CAS**。RunningBoard、其他管理者的写入和极小 PID 复用窗口仍是设备验证事项。卸载失败可能需目标退出、重启或重装重试，不承诺卸载后所有活进程立即原样。

## 偏好与回执

详情区区分保存值与最近真实读回，显示时间、未确认、部分成功、漂移、记录故障与不支持；明确历史不是实时监控。手动刷新仅刷新显示，不写内核。扩展内存和回收优先级可分别恢复跟随 App，失败回读旧保存值并反馈，不改变 CPU/nice 或另一资源。

## 验证与发布阻断

本地证据目录 `workspace/vedette-resource-finish-validation/`：全量宿主/C/源码合同、18 个引擎编译后运行变异、15 个资源策略变异、8 个固定传输编译后运行变异、双架构 iPhoneOS SDK 语法、已有扩展/新协调器/提取 UI 夹具编译、字面逆投影及独立补丁应用检查。iSH 的 Foundation 原生运行明确 SKIP/77，`--require-native` 必须返回 1；SDK 语法和编译变异不等于 Apple 链接/原生击杀。

新增真实 Foundation 协调器+原子存储夹具，kernel 回调才是假后端；覆盖 opt-in、原值保持、配置变化、关闭/删除、重启、WAL 提交失败、未确认读回、漂移、复用 PID、现代及后续代际、同 boot 错配、部分失败、记录上限、损坏 journal/请求与移除。十一个协调器源变异必须先编译，再命中目标运行断言。`ci/run_host_tests.sh` 强制 `sudo python3 -B tests/test_resource_runtime_native.py --require-native`；旧原生夹具与签名门禁保留。

**未完成**：Darwin Foundation 真运行和十一个运行变异、完整 Theos 链接/新包审计、受控自建 PID 的插件正式链路 A/B、业务 App/RunningBoard 漂移、Preferences 真机点击与卸载恢复。四个早期子代理超时不计成功；独立窄审只有静态证据。完成这些前不能称发布验收完成。未来打包必须另升新版本，不可用 `1.1.13-4` 发布不同字节。
