# App 扩展 CPU 独立规则：本地候选报告

## 状态

基线 `2994f24bbc73a6081d958f8f64ba4ff76640b8af`，本地工作树 `vedette-appex` / 分支 `feat/appex-process-rules`。本轮用户授权添加 `.appex`；已实现本地候选并做宿主回归与双架构 Apple SDK 语法核验。**未 commit、push、触发云构建、安装、重启或操作设备；不是已可安装的新版包。** 原 ui2.1 工作树干净、未改动。

## 已落地

- 主页新增原生“App 扩展”入口。标准已装 App 的 `PlugIns/*.appex` 只扫描一层，由 LSApplicationWorkspace 枚举 app 路径；后台读元数据，主线程创建行/刷新。没有全盘搜索、常驻轮询或内存控制。
- 列表支持名称、扩展 ID、所属 App 名搜索；已启用独立规则置顶，独立 ID 去重，同名不同 ID 不合并。
- 扩展独立类型为2，App=0/Daemon=1保持。新增 `extensionConfigs` / `extensionIdentifier`，旧路径、通知、存储、CPU策略参数保留。
- 识别最近 `.appex`，校验 Info.plist 的独立 ID、NSExtension、主可执行名称及确切执行路径；不按短进程名猜扩展。一个 PID 只产生一个 target。
- **有独立记录优先，无独立记录继承 App**。关闭或坏参数的独立记录仍覆盖宿主，避免扩展关掉后又被宿主规则限速；“跟随所属 App”确认按钮删除所有同 ID 独立记录并发原通知，恢复继承。
- 无法验证的 `.appex` 元数据不匹配 App/daemon，避免错误控制；标准外的独立系统扩展若有明确规则可在后端解析，但 UI 没有全盘枚举这类目录。
- CPU策略迁移、逐syscall身份复核、serial queue、100ms补扫、重载与恢复代码保持原样。新增规则沿用这些路径。

## 验证证据

- `make -f Makefile.tests test`：45个Python测试通过，0失败；含旧UI/日志/资源/包ID测试与扩展集成9项、生产C核驱动2项。
- 生产C核：32个优先级组合，最近app/appex路径、非规范路径、执行名和边界缓冲区检查；7个真实编译执行的缺陷变异全部拒绝。
- 集成门禁：12个扩展源码错误和3个旧CPU/存储边界错误全部拒绝。**总22个有效变异拒绝**。
- 旧源码保护：已审查增量逐字逆映射回2994f24，再与git基线整个文件比对；仍保留ui2视觉基线、CPU策略/身份/配置安全冻结，不用删掉旧断言掩盖新增功能。
- 原排序fixtures+1000随机生产核对照、auto-monitor、安全identity/policy套件通过。
- Apple SDK16.5头+clang19：arm64/arm64e，各7个文件，其中manager额外Debug/Release两模式，总16项严格语法检查通过；原生隔离夹具另两架构语法通过。
- 已添加macOS Foundation原生元数据/存储/重复ID/通知夹具，文件和通知都隔离。**iSH运行明确SKIP（1项，exit77），未执行原生Foundation**。CI未来用 `--require-native` 强制运行，不让skip伪装通过。这轮未跑CI。
- `git diff --check`通过；原ui2.1树未改；本地控制文件版本尚保持基线，真正发布前必须另定新版本并核对CI元数据。

## 未验证 / 风险

1. Apple完整链接/Theos实际包装，iOS15原生导航/搜索/插件枚举显示、扩展启动与CPU策略真机验证尚未执行。
2. PSListController私有API与LS服务已做能力检查/复用已验证入口，但SDK语法不是运行时证明。
3. 仅对确切主执行路径的有效 `.appex` 接入；元数据不可用时安全不管，可能改变旧包对这类坏元数据进程的宿主继承行为。
4. 旧CPU策略syscall和PID复核不是内核原子绑定，本轮没有宣称消除原有最后一刻PID竞态。
5. 内存上限/Jetsam优先级仅有官方源码调研，没有接口探测或SET测试，未写入生产实现；详见独立内存报告。

## 本地环境排障

验证途中iSH的null/zero/tty字符设备打开曾均ENXIO，BusyBox重建1:3初次仍失败；为完成Git/编译检查临时用本地普通空文件替代null。结束后以Python `os.mknod(..., os.makedev(1,3))` 恢复标准1:3字符节点，实际stat和O_RDWR打开已验证成功，临时普通文件已移除。此为本地iSH环境恢复，不是手机系统变更，不改源码行为；未进一步改zero/tty。
