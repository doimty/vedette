# Vedette 1.1.13-2 正式修复

本轮授权：扩展 nice 完整接线、CPU/nice/内存/Jetsam 任一独立开关置顶，正式版本编译、开发源码私有、验收后软件源更新；不自动安装设备。

## 实现

- Extension nice 独立存储与严格 `.appex`/执行路径/启动时间身份；无自身 nice 字段继承宿主，disabled/invalid 自身记录阻断继承。CPU 与 nice 的存在/继承/解析/launch/retry/apply 完全分开。
- 持久 nice journal 保留扩展真实身份、宿主来源和 revision；当前规则 source-aware receipt，旧 App/Daemon journal 与卸载尽力恢复行为保留。
- 三类型四类独立开关统一置顶；全局执行开关不改变分组，填值不自动启用，继承本身不算独立置顶。扩展资源/nice-only 副标题不再误报整体跟随宿主。
- nice Follow 只清 nice 三字段；CPU Follow 只清 CPU 四字段，清全部重复 ID、保留另一族及所有资源段。保存失败不广播成功，界面回读旧值并反馈。
- 混合重复记录采用首个该族 intent，disabled/invalid 阻断后续；保存选择与读/执行一致，切 nice 开关不把后行数值意外改0。nice hotpath 用 serial queue 规范化快照，避免逐 PID 反复解析。

## 证据边界

- iSH `make -f Makefile.tests test` 全量通过；Foundation native 按设计 SKIP 77，不能当 PASS。
- 新 UI 独立门禁8 tests / 11错误变体静态拒绝；资源原文门禁17 tests；正式字面投影21 paths / 56 reviewed hunks回到固定1dfce93，再串完整788发布/历史CPU与UI冻结，未知差异负例均拒。
- 双架构 iPhoneOS16.5 SDK：扩展 nice 真实 TU 与fakekernel fixture均通过；UI生产原文 + 两套fixture×2架构8个语法编译通过。不是Applelink/native/真机证明。
- 独审发现重复记录F1/F2与CPUFollow失败反馈F4，已修并补真实文件测试；宿主CPU-only无nice继承F3也加固。原报告为变更前快照，不篡改原结论。
- Cloud CI已接 `--require-native` 两新套件，原 nice/SpringBoard/资源保存原生必须继续执行；待新run实际验证，没有借旧run包冒充正式包。

## 发布与兼容性

正式版本 **1.1.13-2** 大于1.1.13-1+rc1，已dpkg核验。新功能只推非fork私有 `doimty/vedette-private`，旧公开fork/defaultmain不改。

用户确认另一机装PanCake，第二段搜索滑返不能视为纯原生gesturebaseline；不强制开启/禁用返回手势。真机冷push卡顿与PanCake search/popcancel兼容仍待A/B，未声称已修UI阻塞，不拿Foundation测试证明真机转场。

内存/Jetsam生产backend NULL、所有写能力false，本轮仅配置/列表，不宣称两侧生效。

GPLv3派生deb：私有开发仓库不取消对应源码义务。用户尚未明确允许仅正式包对应源码归档公开；在确认与正式包验收前不发布APT，也不擅自公开私有repo历史/其他项目源码。不自动装机。

详细checkpoint、独审与本地日志：`/var/minis/workspace/vedette-final-1113/`。
