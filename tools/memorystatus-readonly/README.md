# memorystatus-readonly（Vedette MEMORY_PLAN M1 独立候选）

独立 C11 命令行工具，仅对**一个明确正整数 PID**查询。未接入 Vedette UI、生产策略、CPU 引擎或 Theos 包；不导入配置，不创建状态文件，不枚举其它应用。源码不依赖 Foundation、RootHide 或其它代理的策略接口。

## 边界与调用契约

```text
memorystatus-readonly PID
memorystatus-readonly --help
```

没有 `--all`、任意 command、SET、策略写 API 或运行时版本覆盖选项。手机诊断只可在后续**明确设备授权**后手动运行；本次未连接设备，也未运行设备 GET/SET。

两种静态、强类型 GET 后端：
- `GET_MEMLIMIT_PROPERTIES` = 8，flags=0，v1=16 字节；成功返回 **0**（不是16）。
- `GET_PRIORITY_LIST` = 1，flags=0，PID 必须>0，单条24字节；成功返回 **24**。

内存 v1 四个32位成员偏移0/4/8/12。Priority pid/band/user_data/limit/state 偏移0/4/8/16/20。BSDINFO=136字节，pid偏移12，启动秒/微秒偏移120/128。大小、宽度、alignment 和所消费字段的 offset 均由 `_Static_assert` 守卫（arm64/arm64e）。只声明必要的只读 libproc 与外部 OS API，不引入既有头里的 CPU 写策略原型。

## 运行时系统/ABI 门禁

手机执行时只读 `sysctlbyname`：`kern.ostype`、`kern.osrelease`、`kern.osproductversion`、`kern.version`，`newp=NULL/newlen=0`。不读取 iSH 的 uname/sysctl 来猜手机，不使用编译 SDK 版本决定手机系统，也不接受 CLI 指定版本。

保守 allowlist：

| iOS major / Darwin major | kern.version 中精确 XNU tag | reference 最大 band |
|---|---|---|
| 15 / 21 | 8019.41.5 | 21 |
| 16 / 22 | 8792.41.9 | 210 |
| 17 / 23 | 10002.1.13 | 210 |
| 18 / 24 | 11215.1.10 | 210 |

必须同时匹配 mobile arm64/arm64e ABI、Darwin类型、OS/Darwin配对与完整 tag 边界（不能让8792.41.90命中8792.41.9）。这**不是支持这四个 iOS 系列所有补丁版本**的承诺。未核 tag、未知版本、缺失 sysctl、macOS/模拟器 ABI 都拒绝 memorystatus 调用，只输出指定PID的元数据与原因。`runtime_patch_verified=false` 永远不因字符串匹配变成true。

euid/root只作为信息，不阻止非root尝试GET，也不将root当实际授权成功；每次 syscall 的返回/errno才是这次权限证据。RootHide与MACF实际权限未实测。

## JSON 和身份

- 单个 JSON 对象写 stdout；每个元数据/身份/GET 调用保留 `attempted/raw_return/errno/errno_text`。errno在每次调用**前**重置，在返回后立即保存；失败 errno 不被后续身份查询清掉。
- 每个 GET 都有前后 PID+start-time+绝对路径复核。中间身份读共用于内存的后核与priority的前核；检测漂移后不继续读已改变PID的priority。
- `identity.status=unstable` 或 `unknown` 时，解释后的 MiB/fatal/flags/band/user_data 都为null；成功但无法归属的原始观测只放在 `raw_observation`，可信度明确标注。返回PID不符的priority整条原始数据也不展示，以防泄露其它PID的数据。
- 身份前后相同仍只是 `stable_observed_not_atomic`，不是CAS、内核原子绑定或一致性快照；GET本身和两种GET之间也非事务。`atomic_snapshot/atomic_binding=false`，不提供稳定有效策略/恢复结论。
- GET失败或异常/部分返回：所有该资源数据为null/unknown，不能把初始化0、旧buffer或负哨兵当0 MiB/无限。成功的非正数保留原始读值，但解释MiB为null；单个资源失败不会抹掉另一GET的成功证据。
- FATAL bit=1；未知attr位单独输出，不发明其语义。active/inactive是内核状态，不等同前台/后台，不根据band推断当前活跃状态。
- `user_data`仅为这个明确PID的值，用固定宽度十六进制字符串保留64位精度；不查询完整priority列表。
- `default_sentinel=null/original_mode=unknown_GET_normalizes_default_sentinel`；`requested_priority/assertion_priority=null`、原因 `not_exposed_by_GET`。effective读回不等于requested，也不够无损恢复默认策略。
- JSON为ASCII转义输出：引号、反斜线、控制字节安全转义；有效UTF-8保留码点，非法字节逐字节映射U+00xx（编码说明也输出）。
- 退出码：0=两GET按契约成功且身份观测稳定；1=未知能力/身份、部分结果或失败；2=usage；3=stdout写失败。0不表示原子一致、无限已生效、可恢复或设备补丁已验证。

## 本地验证（没有设备操作）

```sh
make test
make syntax SDK_ROOT=/var/minis/workspace/netshield2-review/apple-sdk/iPhoneOS16.5.sdk
```

`make`默认只显示帮助。测试编译host stub与`VDT_READONLY_FAKE`隔离后端；fake的Apple版本/进程来自fixture，不调用宿主sysctl或设备API。临时产物位于相邻`vedette-memory-plan/m1-diagnostics/`并严格清理；其它宿主可指定`VDT_DIAGNOSTICS_LOG_DIR`。测试涵盖成功、权限/进程不存在/入参错误、部分返回、copyout失败、PID复用、路径故障、JSON转义和未知kernel，另执行至少8个有效变异。

后续在获授权且有Apple链接工具链时可用独立 `device-arm64` / `device-arm64e` 目标，必须显式传 `SDK_ROOT` 与 `OUT_DIR`；仅生成独立二进制，不签名、不打包、不安装、不执行。本次仅Apple SDK语法检查，Apple/macOS完整链接与真机均未做。

## API 来源

Apple官方仓库 `https://github.com/apple-oss-distributions/xnu/blob/xnu-<tag>/bsd/sys/kern_memorystatus.h` 与相同tag的 `bsd/kern/kern_memorystatus.c`，tag见上表。本地已核源码：`/var/minis/workspace/vedette-extensions/memory-research/{src,version-comparison}/`。精确行号、哈希与结果详见本次诊断 REPORT.md；结构身份原型对照冻结 `libproc/libproc.h:8-12` 与 `libproc_internal.h:10-40,48`。
