# 表情语义索引：开发交接与运行说明

## 目标与边界

这个功能用于改善“我的表情”搜索。视觉模型在 Mac 上离线读取每个表情的 GIF 关键帧，生成：

- 客观画面描述；
- 确认看清的图中文字；
- 受控的情绪标签；
- 受控的动作标签；
- 由代码规则推导的聊天意图；
- 最终供 App 搜索使用的关键词。

视觉模型不会进入 iPhone App，也不会在用户每次搜索时解码 GIF。iPhone 只加载预先生成的少量文本标签并进行本地评分，因此搜索快、离线、不会因为模型推理导致手机发热。

不要把聊天记录、用户照片或手机容器交给模型。当前流水线只读取仓库中的 `.stickerpack`。

## 当前状态（2026-09-25）

- 分支：`codex/message-replies-reactions`
- App Bundle ID：`private.couple.space.development`
- 表情包目录：`Sources/UI/BundledStickerPacks/`
- 当前内置表情包：143 套
- 当前 manifest 条目：3,138 个
- 其中“我们的收藏表情”：207 个；它们也直接从最终 stickerpack 读取，不依赖微信导出源码。
- 内容 ID 格式：`sha256:<digest>`。语义索引同样以 SHA-256 为主键，因此表情包改名或重新打包后仍能复用结果。
- 生成器：`scripts/generate_sticker_semantics.py`
- 推荐模型：`qwen3-vl:4b-instruct`，约 3.3 GB。
- Ollama 通过 Homebrew 安装，验证版本为 0.34.4。
- 12 个样本已验证。4B 对文字、动作和简短描述明显优于 2B。
- 2B 模型已删除，避免重复占用磁盘。
- App 端的语义字段与评分尚未接入；不要误以为当前手机版本已经具备新搜索。

生成器已经采用以下防幻觉设计：

1. 模型只负责 `description`、`visibleText`、`emotions`、`actions`。
2. `emotions` 和 `actions` 必须来自代码里的固定枚举。
3. 模型不再自由生成聊天意图。
4. `derived_intents()` 根据文字、情绪和动作确定性地产生意图，例如：
   - 竖大拇指 → 赞同、夸奖、鼓励；
   - 拥抱 → 求抱抱、安慰；
   - 哭泣 + 委屈 → 难过回应、表达委屈；
   - “在吗” → 确认在线、问候。
5. 禁止词过滤会移除“表情包、搜索、自然口语”等没有检索价值的输出。

先前测试过让模型自由生成 `scenarios/intents`，结果出现“点赞→不理你”“包在我身上→拒绝”等无依据推断，因此不要恢复自由意图生成。

## 本地依赖

### 1. Ollama

确认安装：

```bash
/opt/homebrew/opt/ollama/bin/ollama --version
/opt/homebrew/opt/ollama/bin/ollama list
```

如果未安装：

```bash
brew install ollama
```

如果模型不存在：

```bash
/opt/homebrew/opt/ollama/bin/ollama pull qwen3-vl:4b-instruct
```

启动只监听本机的服务：

```bash
OLLAMA_FLASH_ATTENTION=1 \
OLLAMA_KV_CACHE_TYPE=q8_0 \
/opt/homebrew/opt/ollama/bin/ollama serve
```

默认端点为 `http://127.0.0.1:11434`。不要改成对局域网公开监听。

检查服务：

```bash
curl -fsS http://127.0.0.1:11434/api/tags
```

### 2. Python 与 Pillow

脚本只额外依赖 Pillow。建议把环境放在临时目录，避免污染仓库：

```bash
python3 -m venv /private/tmp/couple-sticker-semantics-venv
/private/tmp/couple-sticker-semantics-venv/bin/pip install Pillow
```

运行结束后，这个 venv 可以删除并随时重建。

## 生成器如何工作

`generate_sticker_semantics.py` 会：

1. 枚举 `Sources/UI/BundledStickerPacks/*.stickerpack`；
2. 从 ZIP 内解析 `manifest.json`；
3. 校验媒体实际 SHA-256 是否与 manifest ID 一致；
4. 对 GIF 取首帧、中间帧和末帧，生成一个横向 JPEG 故事板；
5. 通过本机 Ollama `/api/chat` 请求结构化 JSON；
6. 清洗输出并由代码推导意图；
7. 每成功处理一张就原子写入输出 JSON。

它不会解压并永久保存 GIF 帧，也不会上传媒体。相同内容哈希只分析一次。

输出结构为：

```json
{
  "formatVersion": 2,
  "model": "qwen3-vl:4b-instruct",
  "stickers": {
    "<sha256>": {
      "packTitle": "表情包名称",
      "description": "角色挥手并询问对方是否在线",
      "visibleText": ["在吗？"],
      "emotions": ["期待"],
      "actions": ["挥手", "打招呼"],
      "intents": ["确认在线", "问候"],
      "keywords": ["在吗？", "期待", "挥手", "打招呼", "确认在线", "问候"]
    }
  },
  "errors": {}
}
```

## 先跑小样本

不要直接开始全量。先运行 12 个并人工检查：

```bash
/private/tmp/couple-sticker-semantics-venv/bin/python \
  scripts/generate_sticker_semantics.py \
  Sources/UI/BundledStickerPacks \
  outputs/sticker-semantics/sample-index.json \
  --model qwen3-vl:4b-instruct \
  --limit 12
```

可限制到一个或多个包：

```bash
/private/tmp/couple-sticker-semantics-venv/bin/python \
  scripts/generate_sticker_semantics.py \
  Sources/UI/BundledStickerPacks \
  outputs/sticker-semantics/sample-selected.json \
  --model qwen3-vl:4b-instruct \
  --pack '我们的收藏表情' \
  --limit 12
```

验收时重点看：

- `visibleText` 是否只包含确实看得清的文字；
- 情绪和动作是否与画面一致；
- `intents` 是否由画面/文字合理推导；
- 是否还有“表情包、搜索、聊天”等无意义关键词；
- 是否将相邻三帧误认为三个不同角色；这通常不影响关键词，但描述应尽量客观。

## 全量运行与断点续跑

建议输出到：

```text
outputs/sticker-semantics/semantic-index.json
```

前台运行：

```bash
/private/tmp/couple-sticker-semantics-venv/bin/python \
  scripts/generate_sticker_semantics.py \
  Sources/UI/BundledStickerPacks \
  outputs/sticker-semantics/semantic-index.json \
  --model qwen3-vl:4b-instruct
```

后台运行：

```bash
nohup /private/tmp/couple-sticker-semantics-venv/bin/python \
  scripts/generate_sticker_semantics.py \
  Sources/UI/BundledStickerPacks \
  outputs/sticker-semantics/semantic-index.json \
  --model qwen3-vl:4b-instruct \
  > /private/tmp/couple-sticker-semantics.log 2>&1 &
echo $! > /private/tmp/couple-sticker-semantics.pid
```

查看进度：

```bash
tail -f /private/tmp/couple-sticker-semantics.log
python3 - <<'PY'
import json
p = 'outputs/sticker-semantics/semantic-index.json'
x = json.load(open(p))
print('完成', len(x['stickers']), '错误', len(x['errors']))
PY
```

安全停止：

```bash
kill -TERM "$(cat /private/tmp/couple-sticker-semantics.pid)"
```

重新执行同一条完整命令即可续跑；已经存在于 `stickers` 的哈希会跳过。输出每条都原子保存，因此正常中止不会破坏已完成结果。

在 M3 Pro 上，4B 样本约每张数秒，全量预计数小时。不要同时启动两个写同一个 JSON 的进程。Ollama 当前按单并发运行，盲目并行通常只会增加内存压力。

## 全量结果验收

先统计最终 stickerpack 的唯一内容数：

```bash
python3 - <<'PY'
import json, zipfile
from pathlib import Path
ids = set()
for path in Path('Sources/UI/BundledStickerPacks').glob('*.stickerpack'):
    with zipfile.ZipFile(path) as z:
        m = json.loads(z.read('manifest.json'))
        ids.update(x['id'].removeprefix('sha256:') for x in m['stickers'])
index = json.load(open('outputs/sticker-semantics/semantic-index.json'))
done = set(index['stickers'])
print('需要', len(ids), '完成', len(done), '缺少', len(ids - done), '错误', len(index['errors']))
PY
```

要求：

- `errors` 为空，或每个错误都经人工确认并重新执行成功；
- `缺少` 为 0；
- `formatVersion == 2`；
- `model == qwen3-vl:4b-instruct`；
- 随机抽查至少 50 个；
- 高频词人工验收：哈哈哈、爱你、想你、抱抱、亲亲、委屈、生气、无语、晚安、早安、谢谢、对不起、加油、在吗、吃饭。

如果只差少量错误，可以给脚本增加按哈希重试选项，或从 `errors` 删除相应键后再次运行。不要手工伪造大批结果。

## 与 stickerpack 对接

全量分析完成后，新增一个独立脚本，例如：

```text
scripts/apply_sticker_semantics.py
```

输入：

1. `Sources/UI/BundledStickerPacks/`
2. `outputs/sticker-semantics/semantic-index.json`
3. 一个新的 staging 输出目录

对每个 manifest record：

1. 从 `record.id` 取 SHA-256；
2. 查找语义记录；
3. 保留原有 `keywords`，再合并新的 `keywords` 并去重，最多 64 个；
4. 写入：
   - `semanticDescription`
   - `emotions`
   - `actions`
   - `intents`
5. 不修改 `id`、`file`、`mediaType`、`byteCount`、`width`、`height`；
6. 不修改 `packID` 和 `title`；
7. 将原媒体字节原样写回；
8. 先在 staging 校验全部 ZIP，再整体替换 Bundle 目录。

不要就地逐个覆盖而不保留 staging；中途中断会形成一半新、一半旧的资源集合。

manifest record 目标格式：

```json
{
  "id": "sha256:...",
  "file": "media/....gif",
  "mediaType": "image/gif",
  "byteCount": 12345,
  "width": 240,
  "height": 240,
  "keywords": ["在吗", "挥手", "确认在线", "问候"],
  "semanticDescription": "角色挥手询问对方是否在线",
  "emotions": ["期待"],
  "actions": ["挥手", "打招呼"],
  "intents": ["确认在线", "问候"]
}
```

## 与 Swift App 对接

在 `Sources/UI/StickerLibrary.swift` 的 `StickerRecord` 增加可选字段：

```swift
let semanticDescription: String?
let emotions: [String]?
let actions: [String]?
let intents: [String]?
```

必须是可选字段，这样用户现有的旧包和手工导入包仍能正常解码。

在 `performImport` 增加不可信输入限制：

- `semanticDescription` UTF-8 最多 1,024 字节；
- 每个数组最多 12 项；
- 每项 UTF-8 最多 96 字节；
- 原有 `keywords <= 64` 继续保留。

搜索建议按以下优先级评分：

1. 包名完全匹配：120（现有行为）；
2. 原始/新关键词完全匹配：100；
3. 情绪、动作、意图完全匹配：92；
4. 同义词组匹配：78–85；
5. 查询包含标签或标签包含查询：52–55；
6. 描述包含完整查询：42；
7. 用户过去在相同查询下选过的表情仍置顶（现有 `searchChoices` 行为）。

不要在 SwiftUI 的 sort comparator 内重复算分。当前代码已先生成 `(sticker, score)` 再排序，这是为了解决几千张表情输入卡顿，必须保留。

还应把静态分类数组补上 `我的精选`：

```swift
["全部", "我的精选", "情侣撒娇", "软萌日常", "萌宠陪伴"]
```

可以继续扩充现有 `semanticGroups`，尤其是：

- 赞、点赞、支持、同意、竖大拇指；
- 包在我身上、没问题、交给我、放心；
- 在吗、忙吗、干嘛呢、回我；
- 委屈、可怜、心里苦、难受；
- 回来、等你、想你、想念。

第一版无需把文本 embedding 模型塞进 iPhone。受控视觉标签 + 中文同义词 + 使用习惯排序已经能覆盖主要需求，而且包体、耗电和兼容风险更低。只有完成真实用户搜索评估后，仍有大量同义表达无法召回，才考虑 Core ML 文本 embedding。

## 验证顺序

1. Python 校验所有 pack、hash 和索引覆盖率。
2. Swift 单元测试只补关键解码兼容：
   - 无语义字段的旧 manifest 可以解码；
   - 带语义字段的新 manifest 可以解码；
   - 超长字段被 importer 拒绝。
3. 编译模拟器版本。
4. 在模拟器检查高频查询结果和输入流畅度。
5. 两台模拟器确认同一个 sticker ID 仍走本地引用发送。
6. 真机只做同 Bundle ID 覆盖安装；禁止卸载、清除容器或重新配对。

## 真机数据安全

语义升级只允许改变 App Bundle 里的 `.stickerpack`，不得改变：

- Bundle ID；
- Keychain access group；
- Application Support 中的配对与数据库；
- 消息协议中的 sticker SHA-256 ID。

安装使用：

```bash
xcrun devicectl device install app --device <UDID> <CouplePrivateSpace.app>
```

不要先执行 uninstall。Bundle 覆盖安装会保留手机容器。更新后 `installedCollectionSignature` 会因 bundle pack 大小变化而触发重新导入；因为 `packID` 不变，语义版本会替换同一个表情包目录，不会新增重复包。两台手机应安装相同构建，保证本地 sticker ID 引用一致。

## Git 与大文件

`.stickerpack` 当前被 `.gitignore` 忽略，Git 中保存的是生成脚本和选择清单。语义索引预计只有数 MB，完成并验收后可以考虑把压缩后的最终索引作为可复现输入提交；不要提交：

- 模型文件；
- Python venv；
- 故事板 JPEG；
- `.build`；
- Ollama 日志；
- 中途样本输出。

在替换 bundled stickerpacks 前记录 pack 数量、唯一 packID 数量和唯一 sticker ID 数量，替换后必须完全一致。

## 参考资料

- Ollama Qwen3-VL 2B/4B 模型页：<https://ollama.com/library/qwen3-vl>
- Qwen3-VL 官方仓库：<https://github.com/QwenLM/Qwen3-VL>
- Ollama 官方站点：<https://ollama.com/>
