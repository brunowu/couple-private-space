# 两台真实 iPhone 从零安装与配对

更新：2026-09-15

本文记录 Couple Private Space 最终绑定两台真实 iPhone 的完整操作。配对本身不要求两台手机连接同一个 Wi‑Fi：两台手机只要能通过 Wi‑Fi 或蜂窝网络访问同一个 HTTPS Cloudflare Worker，就可以交换消息与加密资料。

## 一、开始前需要准备的内容

### 两台手机

- 两台支持 iOS 18.0 或更高版本的 iPhone。
- 两台手机都开启“设置 → 隐私与安全性 → 开发者模式”，按系统要求重启并确认。
- 两台手机在 Xcode 的 Devices and Simulators 中可见。第一次连接时，在手机上点“信任此电脑”。
- 两台手机都能访问互联网。配对时建议放在身边，方便当面比较身份核对码。

两台手机不需要同时一直连接电脑。安装开发版时，每台手机需要分别连接 Mac；安装完成后，配对和日常同步不依赖电脑。

### Apple 开发配置

当前项目使用以下开发配置：

| 项目 | 当前值 |
| --- | --- |
| Bundle ID / APNs Topic | `private.couple.space.development` |
| Apple Team ID | `7UBMFSCK2T` |
| APNs Key ID | `Y44N62KN42` |
| Debug APNs 环境 | `sandbox` |
| Release APNs 环境 | `production` |
| APNs 私钥本机路径 | `~/Desktop/AuthKey_<KEY_ID>.p8` |

Apple Developer 网站的 Identifiers 中，App ID `private.couple.space.development` 必须开启 **Push Notifications**。不需要开启 Broadcast Capability。

`.p8` 是长期有效的敏感私钥。不要把文件内容粘贴到聊天、配对资料或代码中，也不要提交到 Git。

### Cloudflare 中继配置

当前测试中继地址是：

```text
https://couple-private-relay.couple-private-relay.workers.dev
```

这个测试实例已经绑定了“手机 + 模拟器”，不能直接用于最终的两台手机。后端当前只保存一对设备；即使在 App 中解除配对，旧 pair 记录仍存在，新的第一台设备不能再次调用 bootstrap。

最终双手机绑定前，应部署一个名称不同的新 Worker，例如：

```text
couple-private-relay-personal
```

对应地址通常会是：

```text
https://couple-private-relay-personal.<你的-workers.dev子域>.workers.dev
```

以 Wrangler 部署成功后打印的实际 HTTPS 地址为准。

## 二、创建全新的 Cloudflare Worker

在 Mac 终端执行：

```bash
cd "<项目目录>/Backend"
npx wrangler login
```

浏览器显示授权成功后，把 `Backend/wrangler.jsonc` 中的 `name` 临时改为最终 Worker 名称，例如 `couple-private-relay-personal`，然后部署：

```bash
npx wrangler deploy
```

记录部署输出中的 HTTPS 地址。它就是两台手机配对时使用的“中继地址”。先验证：

```bash
curl -fsS "https://你的实际Worker地址/health"
```

正常结果为：

```json
{"status":"ok"}
```

### 设置初始化口令

初始化口令只在第一台手机创建空间时使用。生成一个随机口令并保存到本机被 Git 忽略的目录：

```bash
mkdir -p .wrangler-config
openssl rand -base64 36 > .wrangler-config/final-bootstrap-token
chmod 600 .wrangler-config/final-bootstrap-token
npx wrangler secret put BOOTSTRAP_TOKEN
```

`wrangler secret put` 等待输入时，把文件内容粘贴进去。不要把这个口令写入文档或源码。需要复制到第一台手机时，在 Mac 执行：

```bash
pbcopy < .wrangler-config/final-bootstrap-token
```

然后利用 Apple 通用剪贴板，在第一台 iPhone 的“本地服务启动口令”中粘贴。也可以通过端到端的线下方式交给第一台手机，但不要发到普通聊天群或截图保存。

### 设置 APNs 凭据

依次执行下面的命令。每次命令提示输入时，只粘贴该项对应的值：

```bash
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TOPIC
npx wrangler secret put APNS_PRIVATE_KEY
```

填写对应关系：

| Secret 名称 | 填写内容 |
| --- | --- |
| `APNS_TEAM_ID` | `7UBMFSCK2T` |
| `APNS_KEY_ID` | `Y44N62KN42` |
| `APNS_TOPIC` | `private.couple.space.development` |
| `APNS_PRIVATE_KEY` | `AuthKey_Y44N62KN42.p8` 文件的完整内容，包括 BEGIN/END 行 |

私钥可以避免显示在终端历史中：

```bash
npx wrangler secret put APNS_PRIVATE_KEY < "$HOME/Desktop/AuthKey_<KEY_ID>.p8"
```

Debug 版必须使用 APNs `sandbox`；当前项目已这样配置。若以后安装 Release 版，Worker 可以继续使用同一枚 APNs Key，但客户端会登记为 `production`。

## 三、把 App 安装到两台 iPhone

打开：

```text
<项目目录>/Apps/iOS/CouplePrivateSpace.xcodeproj
```

对每台手机分别完成一次：

1. 用数据线连接手机并解锁。
2. 在 Xcode 顶部运行目标中选择这台 iPhone。
3. Scheme 选择 `CouplePrivateSpace`。
4. 确认 Signing & Capabilities 的 Team 是当前有效团队，Bundle ID 是 `private.couple.space.development`，Push Notifications 已存在。
5. 点 Run，等待构建、安装和启动。
6. 如果提示未注册设备，让 Xcode 自动注册；如果提示开发者模式未开启，按第一节处理后重试。
7. 在手机系统设置里允许 App 通知，包括锁定屏幕、通知中心、横幅和声音。

覆盖安装会保留 App 数据。只有“删除 App”才会清除该手机上的本地数据库与配对身份。正式配对前如果要从绝对干净状态开始，可以删除两台手机上的旧开发版，再由 Xcode 重新安装；此操作会删除该 App 的本机内容。

## 四、两台手机的角色

把两台手机放在一起，并固定角色：

- **手机 A / 第一台**：创建空间。
- **手机 B / 第二台**：加入空间。

只有手机 A 需要填写中继地址和初始化口令。手机 B 不需要手工填写服务器地址；它会从手机 A 的邀请中读取中继地址和公开配对资料。

“由我记录周期”决定周期数据的拥有者：

- 如果手机 A 的使用者记录周期，就在手机 A 创建空间时打开该开关。
- 如果手机 B 的使用者记录周期，就保持关闭。

该选择应在创建前确定。周期记录者之后可以决定分享范围。

## 五、完整配对流程

配对共有三次资料交换：**邀请、回应、最终确认**。资料看起来像很长的随机文本，这是正常的加密配对载荷。优先使用“复制配对载荷 + 通用剪贴板/AirDrop”，二维码只是备用方式。

### 第 1 步：手机 A 创建邀请

在手机 A：

1. 打开 App，选择“创建空间”。
2. 在“中继地址”填写全新的 Worker HTTPS 地址。必须以 `https://` 开头，不要使用测试用的 `127.0.0.1`。
3. 在“本地服务启动口令”粘贴 `final-bootstrap-token` 的内容。
4. 按实际情况设置“由我记录周期”。
5. 点“创建空间”。
6. 出现“第一台 · 把邀请交给伴侣”后，点“复制配对载荷”。

邀请有效期为 10 分钟。只有手机 B 尚未成功加入且邀请确实过期时，才在手机 A 输入同一启动口令并点“更新邀请”。手机 B 已经生成回应后，不要更新邀请。

### 第 2 步：手机 B 导入邀请并生成回应

把手机 A 复制的邀请交给手机 B。在手机 B：

1. 打开 App，选择“加入空间”。
2. 在“第二台 · 导入邀请”的输入区点 Paste/粘贴。
3. 确认出现“配对资料已填入”。
4. 点“导入邀请并生成回应”。
5. 出现“第二台 · 把回应交回第一台”后，点“复制配对载荷”。

如果通用剪贴板没有同步，可用 AirDrop 把文本保存/打开后完整复制。不要手工分段复制，不要在文本前后加入说明文字。

### 第 3 步：手机 A 导入回应并查看核对码

把手机 B 复制的回应交回手机 A。在手机 A：

1. 找到“导入第二台的回应”。
2. 点 Paste/粘贴。
3. 点“查看双方核对码”。
4. 手机 A 会显示四组十六进制核对码，例如 `ABCD 1234 CDEF 5678` 的形式。

此时先不要确认。

### 第 4 步：当面比较核对码

在手机 B 的配对页找到“当面核对身份”。把两台手机并排，逐组比较核对码：

- 必须每一组、每一个字符都一致。
- 不要通过聊天发送核对码来“核对”；应直接看两台真实设备。
- 任何字符不同都应停止，不要勾选确认，并从全新的 Worker/全新安装状态重新开始。

完全一致后，在手机 A 打开“我已与伴侣确认完全一致”，点“核对一致，确认这台设备”。

### 第 5 步：手机 B 导入最终确认

手机 A 确认后会显示“第一台 · 最终确认”或弹出“最后一步 · 交给伴侣”：

1. 在手机 A 点“复制配对载荷”。
2. 把最终确认交给手机 B。
3. 手机 B 在“导入第一台的最终确认”中粘贴。
4. 再次确认页面显示的核对码与刚才一致。
5. 手机 B 打开“我已与伴侣确认完全一致”。
6. 点“核对一致，完成配对”。

两台手机之后应进入主界面，并显示“已连接”。如果手机 A 仍显示“等待伴侣完成确认”，点“现在检查配对状态”，或回到前台等待自动刷新。

## 六、配对成功后立即设置通知

两台手机都要分别操作：

1. 进入底部“我们”。
2. 找到“后台通知”。
3. 打开“新消息”“收到新愿望”“小心意”。
4. 按需要打开“前台触觉反馈”。
5. 点“保存后台通知设置”。
6. 状态应最终显示“设备通知已登记”，而不是“正在向系统注册推送”或“推送设置尚未同步”。
7. 再到 iPhone“设置 → 通知 → 我们”，确认允许通知、锁定屏幕、通知中心、横幅和声音。

系统通知权限和 App 内三类开关是两层独立设置，两层都必须打开。锁屏通知只显示“你有一条新消息”“你有一个新愿望”或“你收到了一份小心意”等通用文案，正文和姓名要打开 App 才能看到。

## 七、配对完成后的验收顺序

按以下顺序测试，每项都从 A→B 和 B→A 各做一次：

1. 两边 App 都在前台：发送文字，确认几秒内同步并出现送达状态。
2. 两边 App 都在前台：发送小图片，确认对方看到完整图片；当前媒体通道要求双方同时在线。
3. 接收手机锁屏：发送文字，确认收到通用系统通知，打开后看到正文。
4. 接收手机锁屏：发送“想你了”或“抱抱”，确认收到通用“小心意”通知，打开后显示实际类型。
5. 接收手机锁屏：创建新愿望，确认收到通用愿望通知。
6. 分别用 Wi‑Fi 和蜂窝数据重复文字与通知测试，证明配对不依赖同一局域网。
7. 创建纪念日、愿望提醒和短时间测试胶囊，检查本机定时通知。

照片后台发送目前有单独限制：照片文件经临时 WebSocket 转发，最可靠的测试方式是发送时两边 App 都打开。可见 APNs 通知与照片文件本身的后台续传不是同一件事。

## 八、常见错误

### “服务口令不正确或设备身份未获授权”

- 第一台填写的初始化口令不等于 Worker 的 `BOOTSTRAP_TOKEN`。
- 复制时包含了多余字符或漏掉字符。
- App 指向了另一个 Worker。

### “中继已有另一组配对进度”

- 这个 Worker 已被旧的一对设备占用。
- 对最终两台手机部署一个全新名称的 Worker，不要更新邀请反复尝试。

### “邀请已失效”

- 邀请超过 10 分钟。
- 如果第二台还没有成功加入，在第一台用启动口令更新邀请。
- 如果第二台已经显示“把回应交给第一台”，不要更新邀请，继续传回应。

### “配对资料格式不完整或版本不兼容”

- 剪贴板里不是完整载荷，或仍是上一次的邀请/回应。
- 重新在发送方点“复制配对载荷”，再在接收方清空后粘贴。

### 系统允许通知但锁屏没有通知

- 检查 App 内三个通知开关并点保存。
- 检查状态是否为“设备通知已登记”。
- 确认 Debug 客户端登记的是 `sandbox`，Worker 的 APNs Topic 与 Bundle ID 完全一致。
- 当前真实 Worker→APNs 锁屏投递仍属于真机验收项，不能只凭本地测试判断成功。

## 九、需要长期保存的信息

建议只保存以下非秘密信息：

- 最终 Worker HTTPS 地址。
- Worker 名称和 Cloudflare 账号归属。
- Bundle ID、Team ID、APNs Key ID。
- 哪台手机是周期记录者。

秘密只保存在安全位置：

- `BOOTSTRAP_TOKEN` 本地文件。
- Apple `.p8` 私钥原件及安全备份。

配对邀请、回应和最终确认都是短期配对资料，完成后无需长期保存。不要把它们提交到 Git、工单或聊天记录。
