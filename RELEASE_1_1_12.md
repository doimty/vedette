# Vedette 1.1.12 正式双环境发布计划

## 范围与授权
- 用户确认nice2“测试了一切正常”，并要求改正式版本/包描述、同步编译arm64版、发布到doimty.github.io、下架旧Vedette。
- 源码基线 `de411f7917d529de91c947312ce3cf6eb07bf161`（nice2），隔离分支 `release/1.1.12`。稳定版本选 `1.1.12-1`，已用dpkg比较确认高于nice2，避免删除后缀导致降级。
- 源码与APT仓库只推新分支。软件源当前Pages为main根目录；以正常发布PR合并来完成明确获准的上线，不force push或改Pages配置。不修改其他插件，不设备安装/调nice/重启。

## 实现与冻结
1. Description 更新为“按应用与守护进程独立管理 CPU 限制和 nice 调度优先级”，发布身份、维护者doimty、原作者udevs保持；图标/介绍链接改用本站Vedette页面（发布时一起提供）。
2. 两包分别：roothide `iphoneos-arm64e`（根布局）和rootless `iphoneos-arm64`（/var/jb布局）。每包Mach-O保持arm64+arm64e，最低iOS15；不能只把已有deb改名或改Architecture字段。
3. runtime/CPU/nice/UI/配置域/四项tool权限全部冻结nice2。官方固定roothide头的stub已核会转发ROOT_PATH给rootless，故不改运行逻辑。
4. rootless新增专用维护脚本路径，不要求手机存在jbroot命令；打包时移除RootHide依赖。roothide维护脚本字节冻结。默认不生成rootful包。
5. 保留Foundation、nice状态机/文件安全/签名hash/数字root/原CPU测试。新增scheme感知的归档、工具依赖和路径验证；rootless不能带libroothide依赖，roothide必须带标准依赖。签名权限两scheme均逐切片校验。

## 验收
- 本地正反fixture：两种scheme路径、控制字段、版本序、不同scheme的包互不接受；rootless维护脚本mock测试保留恢复失败阻卸载，权限与日志不清掉。
- GitHub Actions两job实际编译/签名/门禁通过，下载原artifact与API digest匹配，实际包路径依赖和arm64/arm64e slice检查通过。
- APT旧包按Package/Name/control确认；备份后只移除Vedette旧包，确保其他条目/文件逐byte不改；同ID同版本两Architecture同时被索引。
- 发布后HTTP实读Packages与所有压缩索引、Release hash/size、两个deb内容哈希、描述/depiction、旧Vedette无索引且旧文件URL不可下载。
- 失败信号：旧包残留/跨架构依赖混淆/真实签名缺失/非root元数据/任务SKIP当pass/缺产物/误改其他包/页面尚未更新，均不报告已全部上线。

## 边界
用户反馈仅证明nice2在当前设备所测行为正常。rootless无本轮可用实机环境，云原生编译与静态/fixture验证不等于rootless真机测试，公开说明此限制。源码许可GPLv3需提供可获取的对应源码。
