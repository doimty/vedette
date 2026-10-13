# Vedette 列表再进入修复计划

## 基线与范围（本地实施阶段）
- 实施基线 HEAD b03088431c263a2855da1a6d7efc58dc98b046e5；当时为 release/1.1.13，本地修复与测试阶段未 commit/push/CI/安装。后续推送授权见文末。
- 输入证据：10/13 正确路径「进守护 → 返回 Vedette 根页 → 再进」的零注入复现、新 IPS 和 Frida spawn 日志。第二次 viewWillAppear 后首个估高进入无返回；对象释放细节是结合源码推断，非释放栈直接观测。
- 相同缺陷也存在于 VDTExtensionListController。只修两处生命周期缓存失效，不改 catalog 枚举、搜索算法、分组、nice/CPU/资源策略、配置、版本或视觉。

## 最小方案与依据
- 删除两控制器 viewWillAppear 中的 `_specifiers = nil`，保留 visible=false、needsReload=true、super 生命周期及 catalog ensure。
- 保留已有 viewDidAppear → 可见门控 reload → super reloadSpecifiers。**不增加手动清空**：原包 23:42:44.626 的 psl_reload 内已调用 specifiers 并从1行重建为636条；已有父类完整重载是缓存重建入口，不必提前破坏其内部状态。
- 原建议「把 nil 移进 reload」进一步收敛成让 super 全权重载，避免父类清理前的额外释放窗口。

## 成功标准 / 独立失败信号
1. 出现/消失转场不直接清缓存，也不直接调用父类重载；已形成的表格和数组快照在转场期间保持一致。
2. catalog 回填、搜索或规则修改在不可见时只置 dirty；显示后一次重载并清 dirty。可见时修改仍走完整重载，不保留过期分组。
3. 同实例返回、重新创建控制器的暖目录进入、交互取消及重复回填均覆盖。旧源码须失败，而非只让新源码通过。
4. 保留历史测试方法，严格字面投影只允许这两处已审核差异，不扩大冻结范围；未知改动负例仍失败。
5. Linux 合同与完整既有回归通过；Apple SDK 编译独立注明；Foundation 假宿主测试也不能替代 UIKit/Preferences 真机。

## 验证方法
- 原生产生命周期方法逐字提取的 Foundation 生命周期夹具（Darwin原生；Linux标明SKIP），模拟系统转场持有表格索引但不额外持有 specifier 数组；旧源码与指定错误变体必须被运行时断言击杀。
- Linux 源码门禁及负例、两架构 iPhoneOS SDK 对象编译（工具/SDK可用时）、make -f Makefile.tests test、git diff --check。
- 本轮不推送、不装机。最终闭环仍是编译新包后在真机重复8-10次正确路径，并测冷loading回填/搜索/规则分组/取消转场；不能拿本地测试冒称真机不再崩。

## 本地结果
- 最终生产差异仅两行：将两控制器 viewWillAppear 的手动 nil 替换为说明注释；字面逆变换可逐字回到 b030884，其他生产路径未变。严格冻结仍是33路径/83区域，仅两控制器区域及对应索引哈希变化。
- `make -f Makefile.tests test` 最终 exit0，完整日志在证据目录。第一次运行被 SIGTERM 中断，已保留 interrupted 日志；没有把中断算通过，重跑入口成功。
- 原 Preferences UI 全部9个测试保留，加1个两列表生命周期合同，共10个通过。隔离A/B拒绝原版与17个错误场景，未写回生产源码。
- 新回归脚本逐字提取两控制器4个生命周期/重载方法；Linux源契约通过，原版2个类及22个单类错误变体均拒绝。Foundation假宿主覆盖冷/暖新实例、同实例重进、可重入/合并回填、模拟搜索/规则刷新和双向取消转场；这些**原生场景尚未执行**。
- 两生产完整TU × arm64/arm64e：4个Apple Mach-O对象编译通过（iPhoneOS16.5 SDK，部署iOS15.0，-Werror）。新原生夹具的正例两架构SDK语法通过；两者都非链接/原生运行/真机证据。
- Linux Foundation/native 共4处明确SKIP；新脚本默认exit77，`--require-native` exit1。已接Makefile测试和未来CI的`--require-native`门禁，CI不能把原生缺失当绿。
- 独立只读审查代理超时无结论，不计通过；实现代理超时前交付两份测试文件，主代理已读代码并独立执行上述测试，不将其未交付结论当审查结果。
- `git diff --check`通过；HEAD仍b030884。未commit/push/触发CI/改版本/安装/新设备操作。

证据目录：`../vedette-reentry-fix-validation/`（make-test、源码A/B、SDK对象、范围核对）。仍待Darwin真实夹具运行及云成品/真机8-10次正确路径闭环，不能宣称设备已不崩。

## 后续推送授权（2026-10-14）
用户明确要求「推」。准备将已验证修复提交到公开 `doimty/vedette` 的新分支 `fix/list-reentry-20261014`，以 b030884 为审核基线；默认 main 和既有 release/1.1.13 不动。
本次只推源码，不改版本、不自动安装或发布软件源。现有工作流 push 分支过滤未包含该新分支，不自动生成同版本新包。正式打包前须升级包版本，并执行新 Foundation 原生门禁和真机正确路径验收。
上述本地结果是提交前检查点，不能当作新云构建或真机结果。推送的提交 SHA 和远端核验另留证。
