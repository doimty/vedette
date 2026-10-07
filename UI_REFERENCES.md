# UI 源码参考与许可

本次不是只看宣传截图。已阅读以下 GPLv3 项目的真实 Preferences 源码，并以其“自定义 PSTableCell 头部 + 同一原生分组内的总开关 + 标准下钻/分段控件”结构作为实现参考。

## Kayoko（mlgm66 fork）

- 固定提交：`a1b71e7765cb34fc2a714caad2c03c1db0b882b4`
- 仓库：https://github.com/mlgm66/Kayoko
- `Preferences/Cells/KayokoHeaderCell.m`：PSTableCell initializer、图标/标题/简介 Auto Layout。
- `Preferences/Resources/Root.plist`：header cell 与 PSSwitchCell 同组。
- `Preferences/Controllers/KayokoRootListController.m`：导航标题、重载确认、本地化调用。
- License：仓库 `COPYING`，GPLv3。

## PullOver X（mlgm66）

- 固定提交：`9c1e5cdf6dea0fee5df214f268ce8055bdac49ec`
- 仓库：https://github.com/mlgm66/PullOver-X
- `PullOverXPreferences/PullOverXPreferencesController.m`：POHeaderCell、原生控件与设置控制器。
- License：仓库 `LICENSE`，GPLv3。

Vedette 本身采用 GPLv3，相关原始版权与许可证保留。新的 `VDTHeaderCell` 参考上述类的原生构造方式，但使用 Vedette 自有图标、自己的配置键、统一 Localizable 表和可测量动态文字高度；未复制两款插件的图标、功能代码或资源表。新列表排序 helper 单独标注 MIT，不改变项目整体 GPLv3 许可。

## 已核对的 UI 细节

- 两者图标约 46pt、22pt semibold 标题、较小的灰色简介；顶部不是巨大宣传横幅。
- 头部和开关同卡片，搜索属于具体页面；Kayoko 首页输入栏是测试输入，不是设置搜索。
- Vedette 使用 InsetGrouped、系统语义背景/文字色、青绿色点缀、原生绿色开关；列表是真实名称过滤。
- 不带参考项目的悬浮窗口、动画轮询、网络逻辑。

## AltList 接口基线

已读当前 CI 固定的 `opa334/AltList` 提交 `9db09f92eff0404ae7fa9c2fe6c25ba13d5e02d7`：
`ATLApplicationListControllerBase.h/.m` 与 `ATLApplicationListSubcontrollerController.h/.m`。

保留父类 `_allSpecifiers`、图标加载、应用安装/卸载观察者和身份键；仅对父类过滤后结果做独立分组。关闭跨两组不成立的 A–Z 边栏，但保留组内本地化字母排序。搜索回调在 UIKit 主线程更新查询与显示缓存，不借用父类异步队列重排。

参考原图：
- https://mlgm66.github.io/depictions/com.mlgm.kayoko/1.png
- https://mlgm66.github.io/depictions/com.mlgm.pulloverx/1.png

截图对应的精确发布版本未经证实；本次没有安装或运行这些参考插件。
