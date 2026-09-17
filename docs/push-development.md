# 推送开发与验收边界

更新：2026-09-14。当前完成客户端注册、后台同步入口、聊天/新愿望/小心意可见推送、通知操作、愿望/胶囊/纪念日本地提醒及本地验收。测试 Worker 已部署到 `https://couple-private-relay.couple-private-relay.workers.dev`，`/health` 返回 `{"status":"ok"}`，并已配置随机的 `BOOTSTRAP_TOKEN` Cloudflare Secret；本地副本保存在被 Git 忽略、权限为 600 的 `Backend/.wrangler-config/test-bootstrap-token`。APNs Sandbox 的 Team ID、Key ID、Topic 与 `.p8` 私钥已配置为 Cloudflare Secrets，只有名称和 Worker 健康接口通过核对，尚未执行真机投递。Xcode 项目已填开发团队 `7UBMFSCK2T`；重新登录 Xcode 后，Debug 的 generic iOS 真机构建与签名验证通过，嵌入的描述文件确认 Team ID `7UBMFSCK2T` 且 `aps-environment=development`，Info.plist 为 `APNSEnvironment=sandbox`。iPhone 17 (iOS 26.1) 已与 Xcode 开发配对，但真机目标构建提示 Developer Mode disabled；需在手机“设置 → 隐私与安全性”开启开发者模式并重启。独立“我们 · 真机搭档”iOS 18.6 模拟器已构建、安装并启动。已有 A/B 模拟器配对仍指向本地中继，公网测试需要在新设备上重新配对。

## 路由与隐私

- 普通业务信封继续使用外层 wireVersion 1；聊天及新愿望另带 `alertKind` 粗类别。服务器能看到类别，但看不到姓名、正文、愿望文字或附件。其余业务信封使用通用静默唤醒。
- 新轻互动使用外层 wireVersion 2，额外字段 `pushExpiresAt` 是 Unix 秒。服务器因此知道这是需要短期处理的通用通知，但不知道“想你了/抱抱/辛苦啦”的具体类型。
- 服务器只接受严格字段白名单，将此类邮箱密文的截止时间限制到轻互动有效期；接收端解密后核对外层截止时间与加密内容一致。
- 可见通知只含类别通用文案，不含姓名、正文或解密密钥；按接收设备与类别合并。接收方可分别关闭聊天、新愿望与小心意通知，全部关闭后通过认证接口删除自己的推送令牌。
- 可见推送也请求后台同步，系统不保证给予后台运行机会；点击后在 App 中同步并查看。愿望、胶囊与纪念日的定时提醒由本机安排。纪念日可选当天或提前 1/3/7 天加当天，按本机时区 09:00 排程；编辑、删除、权限或时区变更后协调待发通知。愿望/胶囊/纪念日分别最多占 30/22/12 个待发槽位。
- 回应操作打开 App，解密验证有效配对、信封和 15 分钟有效期，再发送对应类型的全新轻互动。处理标记和发送队列在同一事务提交，重复操作不重复发送。
- 回应缓存只保留到轻互动到期；新收到轻互动的最少去重信息在到期后额外保留 24 小时再清理。升级前已存在且没有过期标记的历史去重条目暂不迁移。

## Apple 与客户端配置

Xcode 生成器写入 `CouplePrivateSpace.entitlements` 与 `PushInfo.plist`。Debug 使用 development entitlement / sandbox 路由；Release 使用 production。正式签名时仍需有效团队、开启 Push Notifications 的 App ID 和匹配描述文件。

后台通知运行机会使用同一客户端实例，同步设置 20 秒截止并传播取消；成功后协调本地提醒。前台接收通用远程通知时不重复展示系统横幅；小心意由正常同步后的已验证互动显示前台反馈。

通知“回应这份心意”采用 foreground 操作，系统会按需要解锁并打开 App。这避免把数据库可用性与锁屏后台解密当作必然条件。[Apple 通知操作](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/foreground)

服务端配置项为 `APNS_TEAM_ID`、`APNS_KEY_ID`、`APNS_PRIVATE_KEY`、`APNS_TOPIC`，其中私钥通过部署平台 secret 管理，不能写进仓库。topic 由服务端固定，不接受客户端任意 topic。ES256 provider token 在当前运行实例内缓存 50 分钟；无效设备令牌删除，认证/请求错误停止当前任务，429/5xx 按有限重试及 Retry-After 处理。

[Apple provider token 时效要求](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns) 与 [HTTP/2 连接要求](https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns) 仍须在实际 Worker→APNs 环境验证。当前 fetch 适配器的模拟请求成功不证明实际 HTTP/2 投递可用；必要时再调整最小推送网关。

## 已执行的本地验收

- Swift：通知回应只接受已验证且未过期的轻互动、重复操作、过期字段篡改后的事务回滚、真实加密会话与临时邮箱 TTL。
- Worker：接收方授权、令牌删除、严格字段白名单、短期 mailbox 与 push job、generic alert / background 请求字段、实际 ES256 签名验证（Apple 网络请求 mock）、错误分类。
- 两台独立模拟器：新信封通过实际 HTTP 中继，旧业务同步、双人胶囊、离线/重启、加密回执及前台轻互动回归通过。
- 接收方模拟器：基于真实已接收的加密轻互动安排本地模拟通知，终止 App，长按通知→点击回应→冷启动→验证→回应发送通过。测试名 `ProductFlowTests.testVerifiedAffectionNotificationAction`。此测试需要先运行双模拟器脚本，在 15 分钟内于“我们 · B”运行；不能把它混入没有接收数据的空模拟器套件。
- 2026-09-14 补充：Swift 端粗类别信封与纪念日闰年/删除规划测试通过；Worker 16 项测试及类型检查通过。使用保留配对资料的 iOS 18.6“我们 · A”模拟器，纪念日新增/编辑/删除及重启、胶囊到期通知冷启动、新消息通用通知冷启动、愿望通知冷启动均通过。最初以 Xcode 自动生成的空白 iOS 26.5 副本运行时没有配对资料，无法执行上述产品流程；改为指定已配对设备并关闭并行测试后完成验收。

实际截图：[回应结果](design/implementation-03/affection-response.png)。真实 APNs、后台时间预算、强制退出、锁屏触觉与 iOS 18.3.2 均保留待真机验收。
