# Vedette 置顶、本地化、新设置 UI：本地候选报告

> 2026-10-07 后续更新：用户已授权独立分支推送与 roothide 云构建。当前候选版本调整为 `1.1.10-1+ui1`，仅额外修改发布版本/CI测试与资源验证；下述“未提交”等状态是上一阶段记录。真机安装、导航及大字验证仍未执行。

## 当前状态

- 已修改源码，尚未 commit / push / 触发 CI / Apple 编译 / 生成 deb / 安装 / 重启。
- 工作树：`/var/minis/workspace/vedette-ui`
- 分支：`feat/localized-modern-prefs`
- 基线：`d54fc36cb03e75fbe8699099abc747199ae570b6`（最新修复分支 1.1.10，不是 main 1.1.5）。
- control 版本未变；此为本地 UI 候选，不能与既有发布包混淆。构建发布前须使用新版本并同步 workflow 固定包名。

## 实现

1. App 和 daemon 列表按已保存的单进程开关分成“已启用”“其他”，启用组优先；组内本地化字母排序，身份去重。同名不同 bundle ID 不合并。
2. 保留名称搜索；搜索结果也已启用优先，从详情返回重新排序并保留查询。开启总开关与否不改变单进程规则的置顶状态。
3. 仍在详情页改开关，列表是下钻行，没有新增绕过关键进程确认的快捷开关。状态是用户配置，不是假装已验证内核控制成功。
4. 中英各72键（含保留的旧资源），所有新增标题/说明/提示/状态/空列表文案接入 VDTLoc。进程名称、标识符、品牌、URL不翻译。
5. 原生 InsetGrouped 设置页、自定义 PSTableCell 紧凑头部、同组总开关；保留Vedette图标、系统动态背景/文字色、青绿点缀，无持续动画。
6. 首页保留总开关、两类规则入口、恢复默认、关于。作者链接/致谢收进关于页。重载系统界面加确认提示，未改实际动作。
7. 详情参数、默认值、存储键、关键进程警告与CPU控制保持原语义，仅增加精确范围说明，未把本次范围扩展为输入校验或恢复机制重构。

## 确实阅读了参考源码

已核对 Kayoko a1b71e7 的 HeaderCell / Root.plist / RootListController，PullOver X 9c1e5cd 的 PreferencesController（含 POHeaderCell），以及固定 AltList 9db09f9 的父类和子类源码。详见 UI_REFERENCES.md。

用户强调两个参考也是开源，应该直接看源码而非只参照截图。本实现采用其原生组件组合方式；GPLv3 允许按许可复用，参考来源和原有署名保留。没有复制它们的插件功能代码或图标资源。

## 验证

- 生产 C 排序内核：固定边界 fixtures + 1000随机组，与独立 qsort oracle 对比通过；cc和clang各跑通过，Clang UBSan通过。
- 新 UI/资源/冻结源码测试9项通过，含缺译和格式占位符负对照。
- 原有 process identity、policy transition C suites、auto monitor source contract通过。
- 后端、VDTShared、通知名、CPU policy、filter、控制版本、Makefile、workflow、安装卸载脚本、daemon枚举器与基线逐字节相同；原main/最新审查副本均干净。
- 独立源码复核发现一个头卡手工测高不考虑横屏真实contentView宽度的问题。已移除固定边距高度计算，改为完整约束+UITableViewAutomaticDimension，增加源码防回归检查并复跑通过。
- 可点击HTML预览已在390×844打开检查明暗两种页面；7项交互检查通过（置顶、启用后移组、搜索跨组、返回保留查询、无结果、总开关不改变置顶、明暗切换）。这是设计预览，不是运行原生UIKit的证据。

## 待验证及风险边界

- 尚无iOS原生编译或真机UI结果：需验Preferences自定义cell自适应高度、横屏/大字/长名字、导航搜索和返回重排、实际中文资源装载。
- UIKit/Preferences桥接未通过host C测试执行；不能把排序1000组扩大成全部原生UI测试通过。
- 已有恢复结果不回传、管理进程重启丢记录、设置写入无回执等问题按用户本轮UI范围保留，没有宣称修复。
- AltList两组模式禁用旧单列表A–Z侧边索引，避免点击字母跳错section；名称排序仍在。
- 排序内核对通常数百/上千项列表采用简单稳定插入排序及身份去重；没有新增后台轮询或网络请求，真实大列表时延仍待设备测试。

## 查看

- 设计预览：`../vedette-ui-reference/preview/index.html`
- 源码：当前目录
- 后续验证命令：

```sh
sh tests/run_list_order_tests.sh
python3 -B tests/test_preferences_ui.py
bash tests/run_process_identity_tests.sh
python3 -B tests/check_auto_monitor_path.py
git diff --check
```
