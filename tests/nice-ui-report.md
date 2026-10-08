# Nice 原生设置 UI 增量报告

## 变更文件
- `vedetteprefs/VDTProcessConfiguration.h/.m`：主详情 controller 只强持有 helper、暴露 weak-owner 所需 identifier/type accessor、在 CPU 配置末尾 append nice specifiers；旧 CPU 的 setter、默认值、策略、间隔和原关键进程提示逻辑不改。旧 `enabled` 开关文案改为“启用 CPU 限制 / Enable CPU limits”。
- `vedetteprefs/VDTNicePreferences.h/.m`：独立 `NSObject` helper，生成 nice 开关、value 选择、最近回执、检查/重试按钮；保存仅调用 `VDTNiceSavePreference`，检查失败弹原生 alert 并重读 UI 值；通过 `VDTNiceMatchingStatus(identifier,type,getPrefs())` 渲染匹配回执。
- `vedetteprefs/VDTNiceValueListController.h/.m`：专用原生 PSListItems 子 controller，把选择读写委派回 helper，不改 `VDTActionListController`。
- `vedetteprefs/VDTListPresentation.m`：列表启用判定为旧 CPU 开关语义 OR 严格 CFBoolean true 的 niceEnabled，不折入全局开关。
- `vedetteprefs/Resources/en.lproj/Localizable.strings`、`zh-Hans` 对应资源：添加等量、同 key 的完整双语文案，不删旧键。

## 实现要点
- 保留 ui21 inset-grouped / 原生 specifier 视觉；nice 独立组位于进程详情末尾。开关默认 NO；nice value 是 -20…20 全 41 个整数的普通 PSLinkListCell 选择，缺省 0 仅为预选，不暗示干预。关闭时 value 可继续选择和保存。
- `com.apple.Preferences` App 与 daemon `launchd` / `runningboardd` 不允许启用 nice（开关禁用，已有 true 值仍允许关闭）；`SpringBoard`、`SB`、`backboardd`、`xpcproxy`、`sshd` 启用前走独立 nice 确认，不复用或更改旧 CPU 提示语义。
- 执行状态只表示与当前规则/全局开关匹配的最近回执，页面初次仅读回执；重试先显示 pending 并发 `VDT_NICE_RETRY_NOTIFICATION`，成功仅在后续结果通知抵达后重新读取回执。notify observer 使用弱引用、main queue，dealloc cancel；无 timer/轮询。当前/原值和 errno 仅在回执字段为 NSNumber 时显示，并显示待恢复数。

## 验证
- 双语 `.strings` 经仓库 `read_strings` 解析；106 个 key/locale 且 key 集合完全一致。
- 运行 `tests/test_preferences_ui.py`、`tests/test_ui21_baseline.py` 未执行；其旧断言要求 `VDTProcessConfiguration.m` 字节等于 ui21 原版本，而本任务明确允许对此文件做窄 UI 接入/CPU label 增量，故该固定基线断言预期会失败。未改旧测试。
- 本环境为 Alpine Linux，无 UIKit/Preferences SDK；未声称 iOS 编译、界面运行或真机权限验证。未运行全套测试（父分支同时有未提交的运行端 nice 改动）。

## 父代理需关注
1. 确认 shared header 对 UI target 的 include 路径、VDTNiceShared.mm 的 symbol 可链接；需将 `notify` API 的 Preferences bundle 链接依赖纳入父侧允许的构建接入（本任务未改构建配置）。
2. helper 状态 UI 假设回执字段为 `state/error/original/observed|current/pendingCount`，state 为计划约定稳定码；请与运行端 publisher 字段核对。notify 回调后延一轮 main queue 再取匹配回执，若 publisher 通知先于原子文件提交，考虑 publisher 确保提交后 post。
3. 保护目标名称基于详情 identifier 字符串；daemon catalog 若使用 bundle/launchd label 变体，须据实际标识补齐匹配。敏感 target 支持大小写归一化的已列名称。
4. 建议父侧在 macOS/iOS SDK 构建和真机上重点核对 PSListItemsController parent chain / specifier 选择 target 路由、notify framework 链接、失败保存 NSError 展示、主线程刷新，以及 protected/sensitive daemon identity。
