#!/usr/bin/env python3
"""Generate resumable, local-only semantic metadata for bundled stickers.

Requires Pillow and a local Ollama server with a vision model. The output is
keyed by the sticker's content SHA-256 so it survives pack renames and rebuilds.
"""

import argparse
import base64
import hashlib
import io
import json
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

from PIL import Image, ImageOps


EMOTIONS = [
    "开心", "兴奋", "满足", "感动", "喜欢", "害羞", "撒娇", "期待", "平静", "认真",
    "自信", "得意", "困惑", "惊讶", "震惊", "尴尬", "无语", "无聊", "疲惫", "困倦",
    "委屈", "难过", "悲伤", "失望", "害怕", "紧张", "生气", "愤怒", "嫌弃", "吃醋",
]
ACTIONS = [
    "大笑", "微笑", "哭泣", "流泪", "拥抱", "亲吻", "比心", "挥手", "点头", "摇头",
    "鼓掌", "竖大拇指", "鞠躬", "跪下", "捂脸", "翻白眼", "瞪眼", "发呆", "睡觉", "起床",
    "吃饭", "喝水", "跳舞", "跳跃", "欢呼", "逃跑", "跺脚", "求饶", "送花", "递礼物",
    "发红包", "等待", "偷看", "思考", "打招呼", "告别", "摸头", "加油", "庆祝", "叹气",
    "躺平", "工作", "学习", "指向自己", "握拳", "张嘴大喊", "递出爱心", "转身离开",
]
INTENTS = [
    "早安", "晚安", "问候", "确认在线", "赞同", "拒绝", "答应", "感谢", "道歉", "鼓励",
    "夸奖", "庆祝", "表达爱意", "表达想念", "求抱抱", "求亲亲", "撒娇", "安慰", "关心", "告别",
    "催促", "等待回复", "疑问", "震惊", "无语", "吐槽", "警告", "表达生气", "表达委屈", "求原谅",
    "求助", "拜托", "邀请见面", "提醒吃饭", "提醒喝水", "提醒休息", "工作加油", "生日祝福", "节日祝福", "发红包",
    "收红包", "作出承诺", "表示收到", "表示没问题", "表示不理你", "表达吃醋", "调侃", "开心回应", "难过回应",
]

SCHEMA = {
    "type": "object",
    "properties": {
        "description": {"type": "string"},
        "visibleText": {"type": "array", "items": {"type": "string"}},
        "emotions": {"type": "array", "items": {"type": "string", "enum": EMOTIONS}, "maxItems": 4},
        "actions": {"type": "array", "items": {"type": "string", "enum": ACTIONS}, "maxItems": 4},
    },
    "required": ["description", "visibleText", "emotions", "actions"],
}

PROMPT = """你正在为情侣聊天 App 建立表情搜索索引。
图片是同一个动画表情的关键帧，从左到右表示时间顺序。请只根据可见内容生成中文 JSON：
- description：一句简短、客观的画面、情绪和动作描述；不要提到关键帧、图片或表情包。
- visibleText：只抄写确信看清的文字；看不清则为空数组。
- emotions：从给定枚举中选最多 4 个画面明确表达的情绪；不明确则为空数组。
- actions：从给定枚举中选最多 4 个画面明确发生的动作；不明确则为空数组。
严禁把以下内容放入任何字段：包名、角色或作品名称、表情包、图片、动画、关键帧、搜索、聊天、日常、可爱表情、情侣聊天。
不要描述画风、颜色或帧数，不要猜测看不清的文字，不要输出 JSON 以外的内容。
"""


def normalized_strings(values, maximum):
    result = []
    for value in values if isinstance(values, list) else []:
        text = str(value).strip()
        if text and text not in result:
            result.append(text)
    return result[:maximum]


def useful_keywords(values):
    forbidden_fragments = ("表情包", "搜索", "自然口语", "情侣聊天", "关键帧")
    forbidden_exact = {"表情", "情绪", "动作", "表达", "卡通", "图片", "动画", "聊天", "日常"}
    return [
        value for value in normalized_strings(values, 32)
        if value not in forbidden_exact and not any(fragment in value for fragment in forbidden_fragments)
    ][:20]


def derived_intents(visible_text, emotions, actions):
    text = "".join(visible_text)
    values = []
    def add(*items):
        for item in items:
            if item not in values:
                values.append(item)
    emotion_rules = {
        "开心": ["开心回应"], "兴奋": ["开心回应"], "委屈": ["表达委屈"],
        "难过": ["难过回应"], "悲伤": ["难过回应"], "生气": ["表达生气"],
        "愤怒": ["表达生气"], "吃醋": ["表达吃醋"], "无语": ["无语"],
        "惊讶": ["震惊"], "震惊": ["震惊"], "撒娇": ["撒娇"],
    }
    action_rules = {
        "拥抱": ["求抱抱", "安慰"], "亲吻": ["求亲亲", "表达爱意"],
        "比心": ["表达爱意"], "递出爱心": ["表达爱意"], "挥手": ["问候"],
        "打招呼": ["问候"], "点头": ["赞同", "答应"], "摇头": ["拒绝"],
        "竖大拇指": ["赞同", "夸奖", "鼓励"], "鞠躬": ["感谢", "道歉"],
        "睡觉": ["晚安", "提醒休息"], "起床": ["早安"], "哭泣": ["难过回应"],
        "流泪": ["难过回应"], "告别": ["告别"], "转身离开": ["告别", "表示不理你"],
        "摸头": ["安慰"], "加油": ["鼓励"], "欢呼": ["庆祝"], "庆祝": ["庆祝"],
        "发红包": ["发红包"], "等待": ["等待回复"], "跪下": ["求助", "拜托"],
    }
    for value in emotions:
        add(*emotion_rules.get(value, []))
    for value in actions:
        add(*action_rules.get(value, []))
    text_rules = [
        (("早安", "早上好", "早晨"), ["早安", "问候"]),
        (("晚安", "睡觉"), ["晚安"]), (("在吗",), ["确认在线", "问候"]),
        (("谢谢", "感谢"), ["感谢"]), (("对不起", "抱歉", "错了"), ["道歉", "求原谅"]),
        (("爱你", "喜欢你", "么么", "亲亲"), ["表达爱意"]),
        (("想你", "想念"), ["表达想念"]), (("抱抱",), ["求抱抱", "安慰"]),
        (("赞", "完美", "真棒", "厉害"), ["夸奖", "赞同"]),
        (("我会回来的", "包在我身上", "一定"), ["作出承诺", "表示没问题"]),
        (("不要", "不行", "拒绝", "才不要"), ["拒绝"]),
    ]
    for needles, intents in text_rules:
        if any(needle in text for needle in needles):
            add(*intents)
    return values[:8]


def storyboard(data: bytes, cell=240) -> bytes:
    image = Image.open(io.BytesIO(data))
    frame_count = getattr(image, "n_frames", 1)
    indices = sorted(set([0, frame_count // 2, max(0, frame_count - 1)]))
    frames = []
    for index in indices:
        image.seek(index)
        frame = image.convert("RGBA")
        frame.thumbnail((cell - 16, cell - 16), Image.Resampling.LANCZOS)
        tile = Image.new("RGB", (cell, cell), (250, 248, 244))
        x, y = (cell - frame.width) // 2, (cell - frame.height) // 2
        tile.paste(frame, (x, y), frame)
        frames.append(tile)
    canvas = Image.new("RGB", (cell * len(frames), cell), "white")
    for index, frame in enumerate(frames):
        canvas.paste(ImageOps.exif_transpose(frame), (index * cell, 0))
    output = io.BytesIO()
    canvas.save(output, "JPEG", quality=88, optimize=True)
    return output.getvalue()


def iter_stickers(pack_root: Path):
    for archive_path in sorted(pack_root.glob("*.stickerpack")):
        with zipfile.ZipFile(archive_path) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            for record in manifest["stickers"]:
                data = archive.read(record["file"])
                digest = record["id"].removeprefix("sha256:").lower()
                if hashlib.sha256(data).hexdigest() != digest:
                    raise ValueError(f"digest mismatch: {archive_path.name}/{record['file']}")
                yield digest, manifest["title"], record.get("keywords", []), data


def request_semantics(endpoint: str, model: str, pack_title: str, existing_keywords, image: bytes):
    payload = {
        "model": model,
        "stream": False,
        "format": SCHEMA,
        "messages": [{
            "role": "user",
            "content": PROMPT,
            "images": [base64.b64encode(image).decode("ascii")],
        }],
        "options": {"temperature": 0.1, "num_predict": 320},
        "keep_alive": "20m",
    }
    request = urllib.request.Request(
        endpoint.rstrip("/") + "/api/chat",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        envelope = json.load(response)
    value = json.loads(envelope["message"]["content"])
    description = str(value.get("description", "")).strip()
    if not description:
        raise ValueError("empty description")
    visible_text = normalized_strings(value.get("visibleText"), 8)
    emotions = normalized_strings(value.get("emotions"), 4)
    actions = normalized_strings(value.get("actions"), 4)
    intents = derived_intents(visible_text, emotions, actions)
    return {
        "packTitle": pack_title,
        "description": description,
        "visibleText": visible_text,
        "emotions": emotions,
        "actions": actions,
        "intents": intents,
        "keywords": useful_keywords(list(existing_keywords) + visible_text + emotions + actions + intents),
    }


def write_atomic(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pack_root", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--model", default="qwen3-vl:2b-instruct")
    parser.add_argument("--endpoint", default="http://127.0.0.1:11434")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--pack", action="append", default=[])
    args = parser.parse_args()

    if args.output.exists():
        result = json.loads(args.output.read_text(encoding="utf-8"))
    else:
        result = {"formatVersion": 2, "model": args.model, "stickers": {}, "errors": {}}
    completed = result["stickers"]
    seen, added = set(), 0
    for digest, pack_title, existing_keywords, data in iter_stickers(args.pack_root):
        if digest in seen or digest in completed:
            continue
        seen.add(digest)
        if args.pack and pack_title not in args.pack:
            continue
        if args.limit is not None and added >= args.limit:
            break
        try:
            preview = storyboard(data)
            last_error = None
            for attempt in range(3):
                try:
                    completed[digest] = request_semantics(
                        args.endpoint, args.model, pack_title, existing_keywords, preview
                    )
                    result["errors"].pop(digest, None)
                    break
                except (OSError, ValueError, KeyError, json.JSONDecodeError, urllib.error.URLError) as error:
                    last_error = error
                    if attempt < 2:
                        time.sleep(2 ** attempt)
            else:
                raise last_error or RuntimeError("unknown recognition failure")
            added += 1
            print(f"{len(completed)}: {pack_title} / {digest[:10]} / {completed[digest]['description']}", flush=True)
        except Exception as error:
            result["errors"][digest] = {"packTitle": pack_title, "message": str(error)}
            print(f"ERROR {pack_title} / {digest[:10]}: {error}", flush=True)
        write_atomic(args.output, result)
    print(f"complete={len(completed)} errors={len(result['errors'])} added={added}")


if __name__ == "__main__":
    main()
