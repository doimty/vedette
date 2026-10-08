# Nice2：RootHide 工具签名修复

## 故障证据与范围
- 用户安装nice1日志：新版成功解包，但postinst执行`vedette-nicectl resume`在main之前dyld报`@loader_path/.jbroot/usr/lib/libroothide.dylib`找不到；不能说nice syscall失败，也不能认为软件已完成配置。
- 已交付nice1固定为430e89c/run37736628381；实际包tool的arm64/arm64e切片均无entitlements。
- 对照已工作的QuietHosts native6 helper：相同目录/相同libroothide加载路径，包含四项官方权限；Theos模块已自动链接roothide，追加`-lroothide`本身不是修复。
- RootHide Developer@c53cc199说明独立可执行文件默认sandbox，需要platform-application/no-sandbox/storage.AppBundles/storage.AppDataContainers。固定Theos@88506b2的tool规则没有额外自建`.jbroot`步骤。
- 本轮root SSH仅只读：当前设备已是`ui21 install ok installed`，nicectl和nice状态目录不存在；libroothide、usr/libexec/.jbroot存在。用户当前已回退，未修改设备，不把当前状态当故障瞬间布局证据。

## 最小修复与假设
- 仅nicectl Makefile显式加入`-SEntitlements.plist`和对应官方四项，root-only权限检查、0755非setuid、标准RootHide依赖路径保持。
- 包版本1.1.11-1+nice2；runtime、CPU、UI、postinst/prerm、日志路径与恢复算法逐字冻结nice1。
- 不安装/不重启/不创建设备链接或改状态，不关闭postinst/卸载安全门禁。
- 假设：缺少容器/沙盒权限解释同路径库不能加载。源码/成品可验证缺失被补齐，但是否是这台设备加载失败的全部原因必须由后续实际重装验收，不承诺已复现或已修到设备。

## 成功标准与独立失败信号
1. 四项权限实际出现在nicectl**每一个**Mach-O切片签名中；源码plist本身不够。
2. 上一nice1真包被新增门禁拒绝；缺任一项、false、没有签名、错误fat slice、unexpected extra权限、未签XML等负例必须拒绝。
3. 签名代码页和special slots、数字root归档/0755、标准依赖保持、运行时源码冻结与原回归通过。
4. 云端Foundation集成真正执行，不把Linux SKIP算pass；修复当前已请求云交付，不创建默认分支提交。保留旧nice1分支/源包，不覆盖历史。

## 验收边界
签名权限匹配只证明符合官方可执行文件要求；库在故障瞬间是否被沙盒隐藏、RootHide加载钩子执行、真实进程nice权限仍需设备验证。先让新版完成配置，再单独验证nice功能。独立研究子任务超时未交付，不计独立通过。
