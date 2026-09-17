# 我们 · Couple Private Space

当前开发范围、四个页面的功能细节与验收标准统一见 [产品规格](docs/product-spec.md)：涵盖基础功能、第二阶段媒体/回忆/清单、独立轻互动和时间胶囊。该规格是目标，下面“已完成”才是实现现状。

首批功能、测试证据及剩余事项见 [实现进度](docs/implementation-progress.md)。

这是一个只给一对伴侣使用的 iPhone 私密空间。当前仓库完成了可在模拟器验证的本地优先核心和最小界面，以及只保存密文的 Cloudflare Worker 中继服务。

## 已完成

- SQLCipher 加密本地数据库，数据库密钥保存在 Keychain，使用 `AfterFirstUnlockThisDeviceOnly`。
- libsignal 身份固定、预密钥会话、加密、解密与 ratchet 状态的事务持久化。
- 消息、愿望和周期共享投影的事件合并，包括去重、离线 outbox、加密送达回执和 TTL。
- Debug 默认进入独立设备配对：两台模拟器各自持有 Keychain 身份、SQLCipher 数据库和 libsignal 会话，通过本地 Worker 实际联网同步。旧本机演练可通过启动参数 `--local-lab` 进入。
- Worker Durable Object 实现两成员配对、P-256 签名请求、临时密文邮箱、配额、过期清理和 APNs 投递入口。
- 正常客户端已拆入 `Application` 模块，Debug 和 Release 均使用真实客户端入口；旧本机双端演练仍限 Debug。
- 四个原生页面：对话、愿望、回忆、我们。双人清单、可选照片与文字的共同回忆、单方及双人时间胶囊通过同一加密事件流同步。胶囊支持本机加密草稿恢复、各自取消、已打开状态持久化和到期本地通知；点击通知仍检查到期条件。
- 愿望提醒已接入系统授权和本地排程，支持 1/3/7/30 天窗口、重排未来提醒、关闭和状态取消；纪念日也可选择提前 1/3/7 天及当天本地提醒。
- “想你了/抱抱/辛苦啦”已接入独立加密轻互动，不写聊天历史；支持短期过期、合并、去重和回应。聊天、新愿望及小心意有独立的后台通用通知开关，锁屏不显示姓名和正文；真实 APNs 待验收。

完整产品边界、威胁模型和分阶段计划见 [架构说明](docs/architecture-proposal.md)。

## 本地开发

环境需要 Xcode 26.6、Rust/Cargo、make 和 Node.js。首次构建会生成约 9 GB 的 libsignal 中间文件：

```sh
./scripts/bootstrap_dependencies.sh
swift test
```

打开 [CouplePrivateSpace.xcworkspace](CouplePrivateSpace.xcworkspace) 就可以在 iOS 模拟器运行。请使用 Workspace 入口，不要直接打开内部 `.xcodeproj`。命令行界面测试需要保留 Xcode 的“Sign to Run Locally”临时签名，不要加 `CODE_SIGNING_ALLOWED=NO`，否则模拟器 Keychain 会拒绝访问：

不要同时以根目录 Package、内部 Project 和 Workspace 打开同一工程；曾出现 GUI 缺失产品或空 Scheme。关闭本项目重复窗口后，只用下面的入口打开 Workspace：

```sh
./scripts/open_xcode.sh
```

```sh
xcodebuild \
  -workspace CouplePrivateSpace.xcworkspace \
  -scheme CouplePrivateSpace \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .build/xcode \
  test
```

中继服务本地验证：

```sh
cd Backend
npm ci
npm run typecheck
npm test
npm run build
```

`npm run build` 只执行 Wrangler dry run，不会发布。

## 两台独立模拟器手工测试

在项目根目录的终端启动中继，测试期间保持终端运行：

```sh
./scripts/start_local_relay.sh
```

中继只监听 `127.0.0.1:8787`，测试口令为 `local-simulator-only`。该口令仅适用于本机开发，不能用于公网部署。服务数据保存在 `Backend/.wrangler/network-8787`，重新启动会保留配对和未过期密文。

在 Xcode 中选中 `CouplePrivateSpace` Scheme，分别在“我们 · A”和“我们 · B”两台模拟器运行。同一台 Mac 上的模拟器都可通过 `http://127.0.0.1:8787` 连接中继。

当前构建已生成时，可以直接安装并打开这两台模拟器：

```sh
python3 scripts/open_two_simulators.py
```

需要重新构建时使用：

```sh
xcodebuild -workspace CouplePrivateSpace.xcworkspace -scheme CouplePrivateSpace \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode-workspace build
```

首次配对：

1. A 选择“创建空间”，填写本地中继地址和测试口令，明确谁记录周期，点击“创建空间”。邀请有效期 10 分钟。
2. B 选择“加入空间”，从 A 复制邀请并粘贴；也可把 A 的二维码截图导入 B 的模拟器照片，再点“从照片导入二维码”。B 导入后会生成回应和双方身份核对码。
3. 把 B 的回应交回 A。A 先点“查看双方核对码”，与 B 当面逐组比较；两台均勾选“我已与伴侣确认完全一致”，再继续。任一组不同就停止。
4. A 的最终确认通过二维码或复制交给 B。A 会停留在等待页；B 导入后，两台都确认成功才开放空间。如果 A 提前关闭弹窗，等待页仍有最终确认，之后也可在“我们 → 隐私与连接”重新显示。

二维码图片与复制方式传递的是同一份配对资料，包含公钥、路由和加密确认；私钥不离开各自模拟器。模拟器可用 `xcrun simctl addmedia <设备 UDID> <截图路径>` 把二维码图片加入照片，真机摄像头扫描留待设备阶段。若跨模拟器自动剪贴板未开启，可使用 Simulator 的 Edit → Paste，或在 Mac 上中转复制。身份码应在两台设备屏幕上当面核对，不要通过聊天发送。

双方 App 在前台时每 3 秒同步，也可点击顶部刷新。A 发消息后 B 应出现；B 创建愿望后 A 应出现；周期本人共享或撤销日期后，对方应更新。“待回执”只有收到对方的加密持久化回执才减少，上传到中继不等于送达。

Debug 启动参数加入 `--developer-tools` 可显示“模拟离线/恢复连接”等工具；正常页面不显示开发工具栏。离线创建内容先存本机，恢复连接后补发。也可以关闭一方 App，另一方先发送，再重新打开接收端验证恢复。

一个 Worker 实例只允许一对设备；不要在第三台模拟器再创建另一个空间。也不要只清空一方数据库或只删除 Worker 数据来重新配对。

## 双模拟器自动验收

先构建 Debug App 并启动上述中继，然后执行：

```sh
python3 scripts/test_two_simulators.py
```

脚本会创建或复用 iOS 18.6 的“我们 · A / 我们 · B”，安装 App，通过显式的仅模拟器 Debug 测试入口调用相同的配对和同步代码。它依次验证双向配对、消息、愿望、周期、加密回执，以及离线写入后杀进程重启恢复。传递的只有公开配对载荷；验收报告只包含状态和数量，不导出私钥或聊天正文。成功后两台 App 会以正常界面启动，供继续手工操作。脚本不抹除模拟器。

独立 HTTP 集成测试需要一个尚未配对的 Worker 实例，例如另一个未使用的本地端口：

```sh
./scripts/start_local_relay.sh 8792
# 在另一个终端：
COUPLE_HTTP_TEST_URL=http://127.0.0.1:8792 swift test --filter independentClientsPairOverHTTPAndRecoverAfterRestart
```

## 当前界限

应用已接入本地 Worker 的 HTTP 配对与同步、APNs token 注册和有截止时间的后台同步入口，已部署专用测试 Worker 到 Cloudflare，真实 APNs 凭据与投递尚未完成。愿望与胶囊使用本地系统提醒；后台同步依赖系统提供运行机会，真实效果未验收。配对支持二维码图片导入、复制载荷和双方身份码核对。隐私页可解除配对：服务端停止两台设备同步并清空待送密文与推送路由；另一台设备下次联网时识别失效。本机加密数据保留且可只读查看已收到的对话、愿望和回忆；解除不能抹去伴侣设备已保存的副本。隐私页可选开启设备认证应用锁，离开前台时以纯色页面遮挡内容；真实面容 ID 与后台快照仍待真机验收。正式推送配置与摄像头扫描仍待后续。自动验收驱动只编译进 Debug 模拟器，Release 使用正常网络客户端。模拟器验证不能替代 iOS 18.3.2 真机、锁屏保护或后台生命周期验收。

照片可在对话中选择并发送：每张照片使用独立密钥加密、本机加密保存，描述经端到端加密会话同步；两台设备在线时，Worker 通过经设备签名认证的临时 WebSocket 转发照片密文，不持久化媒体文件。接收方校验并保存完整文件后才返回送达回执。单张 JPEG 上限 2 MB；离线时显示“等待安全传输”，双方再次在线同步会重试整张文件。图片按实际像素缩放，避免屏幕倍率导致普通照片被误判超限。当前使用服务端临时转发，不是 P2P；断点续传、短视频、语音和真实蜂窝网络仍待后续验收。

长按对话中的照片可将其加入共同回忆。照片回忆同步的是照片引用与标题文字，不重复上传文件；对方的文件尚未到达时会继续显示等待。重复收藏不会产生第二条回忆，移除后可从原照片恢复。

共同回忆和时间胶囊也能直接选择照片、填写文字：照片和文字至少有一种即可，标题留空时应用会自动填写。直接选择的照片只显示在对应回忆或胶囊，不会额外生成聊天消息。胶囊草稿照片仅加密保存在本机；封存时照片文件与胶囊记录一起提交，到期并打开前界面不展示正文或照片。新归属标记使用 schema 6，已配对的两台设备应一起升级。

聊天照片、共同回忆照片和已打开的时间胶囊照片均可点击进入系统 Quick Look 预览，也可点照片上的保存按钮加入本机相册；首次保存会请求仅添加照片的权限。“我们”页可设置自己的用户名和头像，资料与头像加密同步后会显示在双方对话与前台轻互动中。资料事件使用 schema 7，两台设备需一起升级。后台 APNs 推送仍保持不含姓名或头像的通用隐私文案；若要在锁屏通知个性化展示，需后续增加设备侧通知扩展及单独的隐私设置。

目前完成文字日常功能、双人胶囊及照片附件、周期本人记录与选择性共享、纪念日，以及后台轻互动推送接线。推送提供方使用模拟 Apple 请求验证，通知回应已在模拟器验证；真实 APNs 与锁屏效果仍待验收，详见 [推送开发](docs/push-development.md)。视频/语音、P2P 与断点续传、回复/reaction 仍待后续批次完成。胶囊时间限制属于正常 App 访问控制，不是密码学定时解密。普通清单/回忆事件为 schema 2，双人胶囊为 schema 3，纪念日和细分周期共享为 schema 4，照片原归属及照片胶囊为 schema 6，新轻互动外层信封为 wireVersion 2；两端须同时升级，已有数据保留并可读取。

libsignal 仓库使用 AGPL-3.0-only，上游也明确不承诺支持 Signal 自身以外的使用场景。在分发应用前，需要完成开源合规与长期升级成本评估。
