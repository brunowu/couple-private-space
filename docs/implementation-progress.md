# 产品实现进度

更新：2026-09-13。范围以 [产品规格](product-spec.md) 为准。真机前整体工作量粗估 60%–65%，口径见 [进度估计](pre-device-progress.md)；不代表整份产品规格已验收。

## 已落地

| 模块 | 本次实现 |
| --- | --- |
| 正式应用入口 | 网络客户端移入 Application 模块，Debug/Release 复用真实入口；旧双端演练仍为 Debug；自动测试驱动仅限 Debug 模拟器 |
| 配对引导 | 创建/加入分支、限时邀请、二维码展示与照片导入、双端 16 位身份码核对、断网/过期/资料错误反馈、重启恢复；第一台等待双方在中继完成确认才进入空间；配对后隐私页展示双方设备和核对码，创建方可重显最终确认；可解除配对，双方停止旧身份同步并保留本机已收到的加密数据 |
| 隐私保护 | 可选设备认证应用锁；仅在认证成功后开启，离开前台时遮住页面；已配对设备与身份码可在隐私页查看 |
| 原生 UI | 对话、愿望、回忆、我们四入口；暖白/陶土色与深色适配；正常页面隐藏开发工具栏 |
| 文字聊天 | 显示本地待发、等待送达和加密回执确认的已送达；失败保留输入；长按加入共同回忆 |
| 愿望 | 按状态筛选；状态变更与完成时间；已实现愿望可按完成日期留作回忆 |
| 本地提醒 | 系统通知授权、1–30 天自定义窗口及 1/3/7/30 天快捷选项、未来计划重排、固定请求 ID 防重复、完成或关闭后取消；过期不重新立即弹出 |
| 愿望静默时段 | 本机按小时设置，可跨午夜；默认关闭，默认选项 22:00–08:00；仅在允许时段随机排程。支持夏令时与非整点时区，时区变化后打开 App 重排未来提醒；不改变胶囊或小心意通知 |
| 双人清单 | 分类、添加、编辑、完成/恢复、删除；完成项可留作回忆 |
| 文字回忆 | 添加、详情、编辑、删除、来源关联；相同来源复用 ID 防重复 |
| 周期 | 本人记录开始/结束日期、通常长度及私人备注；当前天数与单次下次日期估算；日期、估算、阶段分别选择是否共享；关闭共享同步撤销，伴侣只读 |
| 纪念日 | 关系开始日、普通纪念日；每年或单次、闰日规则、倒计时、编辑和删除；双方加密同步，空资料不显示虚构天数 |
| 单方文字胶囊 | 封存标题/正文/开启时间、加密同步、到期查看、作者取消、取消乱序处理；接收者不能取消另一人的封存 |
| 双人文字胶囊 | 发起者约定标题与时间，两人各自封存一份；内容乱序到达可合并；缺少另一份不阻止已到期内容打开；各自只能取消自己的内容 |
| 胶囊本机状态 | 加密草稿自动保存、重启恢复、显式丢弃和重新开始；版本与草稿代次防止延迟保存覆盖；封存与移除草稿同事务；已打开状态持久化，仅在本机保存 |
| 胶囊通知 | 独立授权设置、固定绝对时间、双人胶囊合并为一个提醒、取消/打开后清理；点击通知重新检查本机到期条件后打开；通知不包含标题和正文 |
| 前台轻互动 | “想你了/抱抱/辛苦啦”走独立加密载荷，不写业务历史或聊天；15 分钟过期、同类 10 秒合并、接收后只消费一次；前台提示与回应、可关闭触觉、减少动态效果适配 |
| 后台轻互动接线 | 推送令牌注册/删除、接收设置、20 秒后台同步截止、通用可见通知提供方适配、验证后回应、通知操作幂等；本地模拟通知操作已验收，真实 APNs 待验收 |
| 数据兼容 | 普通清单/回忆事件 schema 2，双人胶囊 schema 3，纪念日及细分周期共享 schema 4；旧本地 schema 1–3 状态可读取，已有消息和身份保留；新功能需两端同时升级 |

胶囊正文只在到期的详情页渲染；到期判断持续更新，时钟回退或取消后不继续展示。此机制是正常 App 的时间访问限制，不是密码学定时解密。

## 验证证据

- Swift 核心测试：33 项通过；另 1 项需要独立 HTTP 实例的测试本次未配置，明确跳过。新增静默时段跨午夜、两次夏令时变化、非整点时区、无效全天静默配置及系统通知整秒精度边界测试。
- 推送适配：14 项 Worker 测试通过，含 ES256 签名与 Apple 请求 mock。两独立模拟器 HTTP 回归、新通知操作冷启动回应均通过。细节和实测边界见 [推送开发](push-development.md)。
- 双人胶囊实际 HTTP 验收通过：A 发起并同步，B 写下另一份，双方最终合并为一个双人胶囊，发送事件取得加密回执。
- 胶囊 UI：自动保存后杀进程、重启继续写、保留双人模式、封存后隐藏正文均已通过。到期本地通知实际触发后，杀进程状态点击通知冷启动打开正文的测试通过；修复了冷启动主页面早于数据读取完成的跳转竞争。
- 双独立 iOS 18.6 模拟器实际 HTTP 验收通过：文字、愿望、周期、清单、回忆、胶囊及取消、双向变更、离线保存、杀进程重启、加密回执、正常前台自动同步，以及独立轻互动的合并、一次消费与不新增聊天记录。正常接收方前台“伴侣给了你一个抱抱”提示已截图并目视确认。
- 正常网络模式 UI 测试通过：点击创建和完成清单、创建回忆、封存胶囊、验证正文未展示、重启验证记录仍在。对应截图保留在 Xcode 测试结果中。
- 愿望通知 UI 测试通过：打开提醒、系统授权、安排已有接收愿望、关闭后取消；没有等待数天后的真实定时触发，不将排程成功当成锁屏展示已验收。
- Debug 和 Release 模拟器构建通过；浅色回忆/胶囊截图与深色聊天截图已目视检查。完整大字号、小屏、VoiceOver 验收尚未完成。
- 测试驱动启动时禁止前台自动同步，修复测试手动同步与生命周期同步竞争；开始统计前先清理已有发送队列，不清空模拟器数据。

## 当前不能宣称完成的部分

- 愿望：延期/恢复、打开后取消、静默时段与点击导航已接入；通知实际点击冷启动 UI 验收已通过。新增 1–30 天自定义窗口及完成时间记录，验证见本页末尾。
- 轻互动：客户端与服务端推送接线、通知操作已实现并完成本地模拟验收；真实 APNs / Worker HTTP/2 兼容、锁屏和触觉未验收。新轻互动信封在服务器也按业务截止时间清理；新收到互动的去重记录在有效期后额外保留 24 小时，旧无截止标记的去重记录尚未迁移。
- 胶囊：照片已能直接从加密草稿选入并封存，开启动画、短视频和语音仍待实现。到期提醒依赖本机提前接收内容并完成排程；不等同于远程 APNs。愿望最多排程 30 条，胶囊按最近到期优先补足总计 60 条本地通知，超出部分下次前台协调时补排。
- 照片已能在两台在线设备间经 Worker 临时转发密文，接收方完整校验保存后回执；聊天照片可加入共同回忆，也可在回忆或胶囊里直接选择。P2P、断点续传、短视频、语音、回复/reaction、周期历史或更复杂健康分析、摄像头扫码、换机迁移、正式公网配置仍待实现或完善。应用锁的真实面容 ID、锁屏快照与生命周期还须真机验收。当前周期只做最近一轮的日期估算，没有医疗预测能力。
- 公网部署、Apple 凭据配置、真实 APNs 投递及真机背景/锁屏/触觉与 iOS 18.3.2 验收未完成。

## 接续顺序

1. 完成隐私锁的模拟器回归与换机边界说明；真实 APNs 配置与投递保留到设备验收阶段。
2. 短视频、语音、P2P/断点续传与回复/reaction；照片回忆和照片胶囊已实现，继续完善界面验收。
3. 按产品规格整体验收，最后进入真机。

开发入口：`./scripts/open_xcode.sh`。本地服务：`./scripts/start_local_relay.sh`。已构建版本打开两台模拟器：`python3 scripts/open_two_simulators.py`。Debug 若需显示离线测试工具，加启动参数 `--developer-tools`。

轻互动额外保护：最多允许 32 个尚未由对方加密回执确认的轻互动加密位置。达到上限暂停新增，正常聊天仍可发送；后续已验证回执推进确认位置后恢复。此上限防止过期丢弃的包使 Signal 跳过密钥窗口无限增长。只保留累计位置，不记录互动种类历史。

首批实际截图：[回忆](design/implementation-01/memories.png)、[文字胶囊](design/implementation-01/capsule.png)、[前台抱抱](design/implementation-01/affection.png)。截图含自动测试样本，并非最终展示内容；后续会持续完善视觉与交互。

本批实际截图：[双人胶囊草稿恢复](design/implementation-02/capsule-draft.png)、[到期通知打开正文](design/implementation-02/capsule-opened.png)。2026-09-12 21:42 的完整 ProductFlowTests 验收 4 项全部通过；核心日志 `/private/tmp/couple-product-tests.log`，UI 日志 `/private/tmp/couple-product-ui-tests-final.log`。通知整秒排程边界另做了定向复测。

推送批次：`/private/tmp/couple-push-core-tests.log`（29 通过、1 跳过）、`/private/tmp/couple-push-backend-tests.log`（14 通过）、`/private/tmp/couple-push-action-ui.log`（接收方通知回应通过）、`/private/tmp/couple-push-regression-ui.log`（原有 4 项 UI 回归通过）。Debug / Release 构建均通过；产物分别确认 APNSEnvironment 为 sandbox / production。模拟器保留原身份、配对与数据。

2026-09-13 愿望批次：`/private/tmp/couple-quiet-tests.log`（33 通过、1 跳过）；`/private/tmp/couple-quiet-ui-tests.log`（6 项 UI 通过，包括静默设置重启恢复和愿望通知冷启动跳转）。愿望排程改为固定 UTC 日期触发，旧相对触发器会在协调时替换，避免调时导致偏离计划；整秒取整不会跨入静默时段。截图：[静默设置](design/implementation-04/quiet-hours.png)、[愿望通知跳转](design/implementation-04/wish-notification.png)。

固定日期排程的最终定向 UI 复测通过（`/private/tmp/couple-quiet-scheduler-ui.log`）；Release 构建通过（`/private/tmp/couple-quiet-release.log`）。真实设备系统延迟、专注模式和后台条件仍由真机阶段验收。

2026-09-13 愿望细节批次：支持未来 1–30 天任意整数天窗口，保留 1/3/7/30 天快捷选择，继续应用静默时段与未来排程重置规则。完成时间取胜出的“已实现”事件创建时间，不取接收时间；离开已实现状态清除当前完成时间，再次实现记录新时间。旧快照缺失日期时明确提示未记录；收藏新完成愿望使用完成日期，收藏旧记录明确说明使用收藏日期。事件格式无需升级。Debug 测试构建与 Release 构建均通过（Release 日志 `/private/tmp/couple-wish-details-release.log`）。

核心测试 `/private/tmp/couple-wish-details-tests.log`：35 项通过、1 项独立 HTTP 测试跳过，覆盖乱序、重启、旧数据解码、延迟加密同步后两端完成时间一致。UI `/private/tmp/couple-wish-details-ui.log`：自定义窗口重启恢复及静默设置回归 2 项通过。首轮按钮查找失败后补充稳定辅助功能标识，复测通过。截图已检查：[自定义窗口](design/implementation-04/custom-wish-window.png)。两台模拟器已安装本批 Debug 版本并保留原数据。本批未重跑完整双模拟器 HTTP 流程，也未验收真机。

2026-09-13 周期与纪念日批次：本人可记录最近一轮开始/结束日期、通常长度与私人备注；备注只写本人的 SQLCipher 库。当前天数及开始日加通常长度的单次估算会显示在本人页面；估算日期已过时标为过期，不继续当作未来日期。开始/结束日期、估算、阶段分别由本人选择是否共享；完全关闭时在本地保存与同步撤销同一事务提交。伴侣只看已授权的共享投影。默认不显示无数据预测，通常长度 28 天只是编辑器初值，保存前不构成实际记录。关系开始日使用固定记录 ID，普通纪念日支持每年或单次、编辑与删除；2 月 29 日在非闰年按 2 月 28 日展示。纪念日/新周期投影使用 schema 4，旧快照及 schema 1–3 事件可继续读取，两端须同时升级。

核心日志 `/private/tmp/couple-together-core.log`：40 项通过、1 项独立 HTTP 测试跳过，包含日期边界、乱序编辑/删除、旧快照、私人备注不进入共享事件、撤销回滚和双端加密送达。B 模拟器 UI 日志 `/private/tmp/couple-together-ui-final.log`：纪念日创建/编辑/删除与重启、周期私人备注重启恢复 2 项通过。截图目视检查：[纪念日](design/implementation-05/anniversary.png)、[周期本人页](design/implementation-05/cycle-owner.png)，含自动测试样本。两独立模拟器完整 HTTP 日志 `/private/tmp/couple-together-http-final.log` 通过新增选择性周期共享/撤销及纪念日增删改，也复测原消息、愿望、清单、回忆、胶囊、轻互动与加密回执；脚本先排空旧离线队列，并清理本批测试写入的示例私人备注。最终 Debug 与 Release 构建日志为 `/private/tmp/couple-together-debug-final.log`、`/private/tmp/couple-together-release-final.log`，均通过。真实设备和 iOS 18.3.2 仍待后续阶段。

原有“我们”页提醒入口因新日期区块增长而变深，已移到页面靠前位置。A 模拟器 `/private/tmp/couple-together-regression-ui.log` 的首次回归发现入口不可见；修正后 `/private/tmp/couple-together-regression-ui-final.log` 的静默设置和愿望排程 2 项通过，原有清单/回忆/胶囊 UI 流程在首次回归中通过。最终 Debug 已重新安装并在两台模拟器正常打开，不重置配对或数据。

仅模拟器 Debug 的 HTTP 验收报告现以布尔值表示是否共享周期日期或估算，不再把共享日期写入 `Documents/network-smoke.json`；这些字段不属于正式 App 的事件格式。验收脚本结束时恢复周期本人原先保存的共享选项。

最终重复运行 `/private/tmp/couple-together-http-final.log` 再次通过；A 端测试报告核对为 `hasSharedCycleDate=true`、`hasCycleEstimate=true`、`cycleRevoked=false`、`pending=0`，旧的日期字段缺席。最终 Debug 构建 `/private/tmp/couple-together-debug-final.log` 通过，最终 Release 构建 `/private/tmp/couple-together-release-final.log` 通过。两台模拟器保持正常 App 界面，原有身份、配对和数据未清空。

2026-09-13 配对引导批次：邀请与回应保留原有加密协议，二维码使用压缩与 QR 字母数字编码；真实邀请一度超过 QR 字节模式容量，改造后系统条码识别器能够读回真实模拟器截图。双方核对码由两端 Signal 身份与空间 ID 确定。第一台确认后停在等待页，直到第二台也确认、Worker 报告空间活跃才进入共享页面。过期邀请显示明确提示；重启后更新邀请须重新输入服务口令。已配对的原 A/B 身份和数据没有清空。

本批核心与独立 HTTP 测试 `/private/tmp/couple-pairing-core-confirmed.log`：43 项通过，覆盖真实 QR 编码/解码与 Vision 识别、身份码对称与身份变化、篡改回应拒绝、先等待后放行、重启恢复。独立 iPhone 16 模拟器邀请创建/二维码/重启 UI 测试 `/private/tmp/couple-pairing-ui-final.log` 通过；恢复后续期口令门槛 UI 测试 `/private/tmp/couple-pairing-renew-ui-final.log` 通过。iPhone 16 Plus 照片选择器实际点选二维码截图并自动填入邀请的 UI 测试 `/private/tmp/couple-pairing-photo-ui-fallback.log` 通过；该运行时 Vision 无法创建推理上下文，客户端已回退到 Core Image 识别。原 A/B 双模拟器完整 HTTP 回归 `/private/tmp/couple-pairing-two-sim.log` 通过，包含既有文字、愿望、周期、纪念日、清单、回忆、胶囊、轻互动、加密回执及重启恢复。最终 Debug 在 UI 测试中构建通过，Release `/private/tmp/couple-pairing-release-complete.log` 构建通过；新版已重新安装至 A/B。摄像头扫描、解除配对、换机、真实网络与真机仍待后续。

2026-09-13 隐私批次：隐私页增加解除配对的后果确认；服务端递增配对代次、停止同步并删除待送密文与推送路由，另一台在下次联网时识别代次变化并停止写入。本机加密数据库、密钥和已收到的内容不自动清除，可只读查看对话、愿望与文字回忆。独立 HTTP 测试覆盖双端失效、禁止旧身份继续写入和重启后的数据留存；完整 Swift 核心测试 43 项通过（`/private/tmp/couple-unpair-core.log`）。可选设备认证应用锁已接入隐私页，只有系统认证成功才保存开启设置；App 离开前台时纯色遮挡并隐藏底层辅助功能内容。Debug 与 Release 构建通过（`/private/tmp/couple-privacy-debug-final.log`、`/private/tmp/couple-privacy-release.log`）；A 模拟器隐私入口和取消解除配对 UI 测试通过（`/private/tmp/couple-privacy-ui.log`），原 A/B 配对和数据未清除。真实生物识别、后台快照与锁屏仍需真机验收。

2026-09-13 媒体第一步：照片导入后统一压缩成最大 1600 像素、2 MB 的 JPEG，生成每文件随机密钥，用 AES-GCM 加密后保存在本机 SQLCipher；经现有 Signal 会话只同步尺寸、摘要和密钥等照片描述，不把文件塞进小消息邮箱。接收方文件未实际到达时显示等待且不生成加密送达回执；传入密文必须通过认证、长度与摘要校验，成功写入后才生成回执。核心 44 项测试通过（`/private/tmp/couple-media-core-final.log`），独立 HTTP 配对/照片描述/撤销测试通过（`/private/tmp/couple-media-http.log`），Debug 与 Release iOS 构建通过（`/private/tmp/couple-media-debug-final.log`、`/private/tmp/couple-media-release.log`）。修正了绘图器默认使用屏幕 3 倍倍率导致小照片被错误放大、压缩后超限的问题，并对大照片逐级缩放；核心测试使用 2×2 像素 JPEG 验证小图也可保存。跨设备文件通道尚未接通；Debug 模拟器保留明确标注的试验入口，Release 暂不开放照片发送。下一步接入真实媒体传输及断线恢复，之后才可宣称照片送达。

2026-09-13 媒体第二步：Worker 新增通过一次性签名挑战认证的 WebSocket，单对设备各保持一个在线连接，只转发有上限的照片密文帧与重试请求；不在 Durable Object 存储媒体。接收方从元数据识别缺失照片并在同步时重试请求，成功校验、写入本机数据库后才产生加密回执。独立双客户端完整 HTTP/WebSocket 配对、照片和回执测试通过（`/private/tmp/couple-media-socket-http.log`）；Swift 全部 44 项和 Worker 14 项测试通过（`/private/tmp/couple-socket-all-core-final.log`、`/private/tmp/couple-socket-backend-tests.log`），Release iOS 构建通过（`/private/tmp/couple-socket-ios-release.log`）。Debug 使用正常模拟器临时签名构建（`/private/tmp/couple-socket-ios-signed.log`）并安装到原 A/B，既有配对与数据保留；B 原先两张等待中的照片自动显示，A 两张转为“已送达”、待回执 2→0。正式版开放照片入口。当前为临时服务器转发、重试整张文件，尚非 P2P 或字节断点续传；双方须同时在线，真机蜂窝网络与后台收发仍待验证。

2026-09-13 照片回忆：长按聊天照片可加入共同回忆，回忆事件只引用已共享照片，不复制密文或额外上传；回忆卡片和详情在文件未到达时显示等待。照片回忆沿用来源 ID 防止重复，移除后可从原照片恢复；编辑标题或说明保留照片引用。新增可选字段保证已有文字回忆照常解码。Swift 45 项测试通过（`/private/tmp/couple-photo-memory-core.log`），独立双客户端 HTTP/WebSocket 照片与回忆同步测试通过（`/private/tmp/couple-photo-memory-http.log`）。Debug/Release 模拟器构建通过（`/private/tmp/couple-photo-memory-ios-debug-final.log`、`/private/tmp/couple-photo-memory-ios-release-final.log`）；Debug 已安装到原 A/B，保留原配对与照片。照片回忆的实际长按 UI 路径尚待单独自动化验收。

2026-09-13 回忆/胶囊直接照片：两处编辑器均允许文字或照片任选其一，标题可留空自动填写。直接照片带 schema 6 归属标记，只进入回忆或胶囊，不插入聊天。回忆照片与回忆事件、胶囊照片与封存事件在同一 SQLCipher 事务中落盘；无效记录会回滚照片。胶囊照片先保存在本机加密草稿，重启后可恢复；封存后仍须到期并打开才在界面展示。照片描述经 Signal 会话、文件经现有临时 WebSocket 转发，接收校验后才回执。Swift 47 项测试通过（`/private/tmp/couple-direct-photo-core.log`），独立双客户端 HTTP/WebSocket 文字聊天照片、直接回忆照片及照片胶囊同步测试通过（`/private/tmp/couple-direct-photo-http.log`）。真机后台传输和独立照片选择器 UI 自动化仍待验收。

2026-09-14 照片预览与双人资料：照片共用组件接入系统 Quick Look 预览和相册“仅添加”保存；模拟器已实际打开 Quick Look 并确认相册权限与保存成功。每人在“我们”页编辑自己的用户名与头像，schema 7 的资料事件和 avatar 照片归属经 Signal 加密同步，聊天行与前台轻互动显示双方资料；头像传输沿用已验证的 WebSocket 密文路径，不额外插入聊天。Swift 48 项核心测试通过（`/private/tmp/couple-profile-core.log`），全新本地 Worker 的双客户端 HTTP/WebSocket 测试通过（`/private/tmp/couple-profile-http-8801.log`），最终 Debug/Release 构建通过（`/private/tmp/couple-profile-debug-final.log`、`/private/tmp/couple-profile-release.log`）。最终 Debug 已覆盖安装原 A/B 两台模拟器，既有配对数据保留，A 已重新联网。后台 APNs 仍发送通用隐私文案，不在中继保存或明文传播用户名；锁屏个性化通知需设备侧通知扩展，留待后续。

2026-09-14 界面风格统一：参照 [周期概念图](design/concepts-v3/cycle-overview.png)，将四个主页面和现有表单调整为暖白底色、陶土色重点、鼠尾草绿辅助色及圆角白色卡片；“我们”页把已有周期入口移到双人资料之后。未更改配对、同步、权限、保存和周期算法，也未加入概念图中的周期圆点/排卵展示。实际模拟器截图：[对话](design/implementation-06/chat.png)、[愿望](design/implementation-06/wishes.png)、[回忆](design/implementation-06/memories.png)、[我们](design/implementation-06/together.png)。四页只读界面检查通过（`/private/tmp/couple-style-ui-reordered.log`）；已有愿望清单/回忆/胶囊界面回归及 B 机周期记录与重启恢复测试通过（`/private/tmp/couple-style-functional-ui.log`、`/private/tmp/couple-style-cycle-ui.log`）；Release 模拟器构建通过（`/private/tmp/couple-style-release.log`）。Debug 已覆盖安装并启动原 A/B 模拟器，保留原配对和数据。

2026-09-14 周期概览与“我们”页第二轮：依照概念图把双人头像、周期、纪念日/愿望及隐私组成首屏卡片。周期使用每行 18 个、最多两行 36 个的紧凑无数字小圆点；第二行不足时居中排列，按实际开始/结束日期、已过去日期和本人设备上的粗略日历估算着色；标题仍显示当前是第几天；设置超过 36 天时概览注明剩余天数，详情保留完整长度。仅周期本人设备显示排卵和易孕区间的粗略标记，伴侣端只有在同时获得开始日期和下次日期估算分享时才推得出网格长度，且不显示排卵/易孕标记。估算参考 [ACOG 关于平均周期和受孕窗口的说明](https://www.acog.org/womens-health/faqs/fertility-awareness-based-methods-of-family-planning)，只在通常周期长度 21–35 天时绘制，不能用于避孕或医疗判断。没有新增同步字段或改变分享权限。实际截图：[B 机周期概览](design/implementation-07/cycle-overview.png)。B 机周期编辑/重启恢复、A 机纪念日新增/编辑/删除、隐私设置与解除配对取消的 UI 回归通过（`/private/tmp/couple-18col-dots-ui.log`、`/private/tmp/couple-overview-other-ui-validated.log`）。最终 Debug/Release 构建通过（`/private/tmp/couple-18col-dots-ui.log`、`/private/tmp/couple-18col-dots-release.log`）；Debug 已覆盖安装并启动原 A/B，既有配对和数据未清空。

2026-09-14 纪念日首屏直显：利用两行小圆点节省的空间，把关系开始日的已走过天数和所有未删除纪念日的名称、下次倒计时直接放进“属于我们的日子”卡片，点击各日期沿用原编辑器；卡片底部保留新增纪念日和愿望入口，移除下方重复的纪念日列表。截图：[直接展示的纪念日卡片](design/implementation-08/together-anniversaries.png)（含 UI 测试样本）。A 模拟器新增、编辑、删除及重启恢复回归通过（`/private/tmp/couple-inline-anniversary-ui.log`），隐私入口与取消解除配对回归通过（`/private/tmp/couple-inline-privacy-ui.log`）；Release 构建通过（`/private/tmp/couple-inline-anniversary-release.log`）。Debug 已覆盖安装并启动原 A/B，配对和数据未清空。

2026-09-14 通知收敛：聊天和新愿望采用仅暴露粗类别的 APNs 通用文案，小心意保留加密验证后的回应；本机愿望、时间胶囊和纪念日按各自设置排程通用提醒。纪念日支持当天或提前 1/3/7 天加当天，年度重复和闰年规则沿用原日期模型；待发数量总计控制在系统 64 个以内。详见 [真机测试前通知清单](pre-device-notification-checklist.md)。Worker 16 项测试、Swift 核心测试、iOS 18.6 配对模拟器上的纪念日与通知冷启动定向 UI 测试通过；Debug/Release 模拟器构建和 Worker dry-run 打包通过。最新 Debug 已覆盖安装在原 A/B 并启动，配对资料与本机数据未清空。真实 APNs、锁屏触觉及后台投递仍需真机。
