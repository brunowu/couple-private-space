#!/usr/bin/env python3
"""Convert selected folders from WeChat-Emoticon into independent v1 stickerpacks."""

import hashlib
import json
import struct
import sys
import zipfile
from pathlib import Path

OCR_TAGS = {}


PACK_TAGS = {
    "哈哈哈木子木鱼": ["哈哈哈", "哈哈", "笑", "搞笑", "开心"],
    "蘑菇点点情侣日常": ["情侣", "日常", "爱你", "想你", "抱抱", "亲亲"],
    "撩人蜜语": ["撩", "情话", "爱你", "想你", "亲亲", "甜"],
    "呆呆朵朵最有爱3": ["爱你", "可爱", "情侣", "喜欢", "抱抱"],
    "恋爱季节": ["恋爱", "爱你", "喜欢", "想你", "约会"],
    "秋田君情侣篇": ["情侣", "爱你", "抱抱", "亲亲", "日常"],
    "能发图就别说话": ["斗图", "回复", "无语", "聊天", "梗图"],
    "文字控网络语": ["文字", "网络语", "回复", "聊天", "梗图"],
    "神烦狗的精神污染": ["神烦狗", "搞笑", "无语", "哈哈哈", "斗图"],
    "花式聊撩": ["撩", "情话", "聊天", "喜欢", "爱你"],
    "白果子喜欢撩你": ["撩", "喜欢", "爱你", "想你", "可爱"],
    "陈小包聊天篇": ["聊天", "回复", "日常", "可爱", "斗图"],
}

# Hand-reviewed first-frame semantics. Unreviewed stickers deliberately receive
# no broad pack-level search tags: missing a result is better than returning an
# entire unrelated album for a short query.
ITEM_TAGS = {
    # 哈哈哈木子木鱼
    "07617605e255db020522efb14420bfed": ["哈哈哈", "大笑", "开心", "咧嘴笑"],
    "0aef28a5f4f32558aa9556545eaaf6fa": ["呵呵", "坏笑", "偷笑", "得意"],
    "12d0247fad1be6ea9fba0b9e82de15bc": ["坏笑", "偷笑", "斜眼", "你懂的"],
    "183e07fb4cef03e4559cfedcfcf3c87d": ["淡定", "安静", "看着你"],
    "284a1639faa81cffdd2864a5f7ab5476": ["微笑", "乖巧", "开心"],
    "43fd228d34c246e44c437795319ca965": ["斜眼", "怀疑", "看你表演"],
    "53eadac5c04964a7f5066216f8492591": ["无语", "呆住", "发呆"],
    "58b41b3ac7cb539c67c4e12d720614d8": ["傻笑", "害羞", "卖萌", "开心"],
    "659ad4d40708f12f71777af4716f2832": ["哈哈哈", "大笑", "笑死", "开心"],
    "7600389176179e55b324cacd58f8a4d3": ["鞠躬", "谢谢", "道歉", "拜托"],
    "7ab74a8222213b6176844d4ab4b3db00": ["严肃", "认真", "站好"],
    "80b4b5b799847aeb228a0c924ebf8e86": ["微笑", "乖巧", "开心"],
    "9c1c85ce75f71242ccd461ca44a06ee8": ["哈哈哈", "坏笑", "偷笑"],
    "aa913488c3c701c382f35db3d6c430e3": ["低头", "害羞", "思考"],
    "b89c28add1340e8a798d57592a4e2b4a": ["嘿嘿", "吐舌", "调皮", "搞怪"],
    "ef6c078d917bc2d171aa2bcb03307b8c": ["哈哈哈", "大笑", "开心"],
    # 蘑菇点点情侣日常
    "04930dd0df487e5469429da868075328": ["可爱", "卖萌", "乖巧"],
    "0a5b3978d124a32992c191d2954e8130": ["求包养", "养我", "撒娇"],
    "201588422dc319df65851326786ab8c8": ["吃饭", "开饭", "好吃"],
    "24b014283f87077194aa7a74e5dac76a": ["你抱一我抱一", "分享", "给你", "抱抱"],
    "34a8ec57c55d5a15dfdd50ae60b3d4a0": ["踩", "生气", "发火", "欺负"],
    "3c88bd496976aa4f2222e295c67c9952": ["你真美", "爱你", "喜欢", "花痴"],
    "45725c007954607d422e04f756bc8596": ["睡觉", "晚安", "赖床", "困"],
    "4cb198e415c1fdec3497285614d077cf": ["起床", "早安", "困", "叫醒"],
    "55acef9cb8e3e362c3273f6d0f2cc6ed": ["男子汉", "勇敢", "加油"],
    "5a64beccef38ea312d573fc4ebfb3661": ["害羞", "低头", "不好意思"],
    "5dafb6854bf0b422e04f756bc859421d": ["可爱", "卖萌", "乖巧"],
    "7ed65ed9923bf30c677db00baeb37599": ["睡觉", "晚安", "趴下", "累"],
    "8ae3797194afbb5cf00c1ac93275885f": ["会暖床", "暖床", "陪你睡"],
    "9ec10f263299a77cde3a509ea96f40c3": ["哭", "伤心", "委屈", "呜呜"],
    "a56df2ead0fa44005137f68670aebe62": ["哭", "流泪", "伤心", "委屈"],
    "a5d6fbbe1d5cd4bec05953697b3d35c5": ["好男人", "暖男", "靠谱"],
    "ae88b358b202862268ae84e2ecc7d4d0": ["对不起", "道歉", "求原谅", "拜托"],
    "c8294d14a39fc01c3150dc779dd967d8": ["害羞", "乖巧", "站着"],
    "c9e5c353709d2bcc977159118940c14b": ["治愈你", "安慰", "抱抱", "关心"],
    "cd4cd329c185327fc6c05032239a9618": ["生气", "不开心", "哼"],
    "d5e9808338be1ce022ce2b0b1328be0d": ["萌萌哒", "可爱", "开心", "卖萌"],
    "e610b03379de33cbb13a583438052360": ["一起睡", "晚安", "抱抱", "情侣"],
    "f97edce9bb7de12badf60d8aaca84e39": ["一路一边", "散步", "约会", "一起走"],
    "fb7957123a5c11e54f0b8cad23fa0672": ["转身", "离开", "不理你"],
    # 撩人蜜语（文字清晰的条目）
    "0a425ad7bafbeddda5b95d89538d3444": ["发红包", "红包", "我们"],
    "42c0d96d2e4b4d9fb9b744ec75e4642a": ["不", "拒绝", "不要"],
    "4db9ebe29ff7dddf0c85b3970fcd432f": ["想要吗", "想要", "问你"],
    "577dbb34313d1c728ba89af451738666": ["求我啊", "求我", "傲娇"],
    "585eb770ce0066efa6dc8af460782d09": ["好烦", "烦", "不耐烦"],
    "613b6477800ee3150d2bbdd3aad3a4f4": ["我们", "爱", "情侣"],
    "8717f53a536fe5bdbb316c1dbcf23bb3": ["你并非一无所有", "还有病", "损人", "吐槽"],
    "9f975f7b14ce6203c18333f5805c47a8": ["幻想无数", "幻想", "做梦"],
    "b671938158c221b08c99de91a7e6c868": ["身体被掏空", "累", "没力气"],
    "b8306efb9b60b31e05b72ec446186538": ["别太嚣张", "嚣张", "警告"],
    "cb9b67f5d7d7cf386f6c9ef24e2564ee": ["你说什么我都爱你", "爱你", "情话"],
    "d8811df67d1cc4ad237864b57208b109": ["少一点套路", "多一点真诚", "真诚", "套路"],
    "d94402713c7b2647f580277b644d63fa": ["心疼", "抱抱", "安慰"],
    "ddea04c10d0219cb5841312b1dd7e072": ["睡觉", "上床", "晚安"],
    "f2b2bca910cc672a13d74384938b50ca": ["摸着良心说话", "良心", "说实话"],
}


def gif_size(data: bytes) -> tuple[int, int]:
    if data[:6] not in (b"GIF87a", b"GIF89a") or len(data) < 10:
        raise ValueError("not a GIF")
    return struct.unpack("<HH", data[6:10])


def build_pack(folder: Path, output_dir: Path, category: str | None = None) -> Path:
    title = folder.name
    records, payloads = [], {}
    for media in sorted(folder.glob("*.gif")):
        data = media.read_bytes()
        # A few upstream files use a .gif suffix for PNG data. The iPhone
        # importer verifies magic bytes, so omit those malformed entries while
        # retaining the rest of the pack instead of aborting the full build.
        try:
            width, height = gif_size(data)
        except ValueError:
            continue
        if not (0 < len(data) <= 10 * 1024 * 1024 and 0 < width <= 4096 and 0 < height <= 4096):
            continue
        digest = hashlib.sha256(data).hexdigest()
        relative = f"media/{digest}.gif"
        records.append({
            "id": f"sha256:{digest}", "file": relative, "mediaType": "image/gif",
            "byteCount": len(data), "width": width, "height": height,
            "keywords": list(dict.fromkeys(ITEM_TAGS.get(media.stem, []) + OCR_TAGS.get(media.stem, [])))[:64],
        })
        payloads[relative] = data
    if not records:
        raise ValueError(f"no valid GIF files in {folder}")
    pack_slug = hashlib.sha256(title.encode()).hexdigest()[:16]
    manifest = {"formatVersion": 1, "packID": f"wechat-emoticon-{pack_slug}",
                "title": title, "category": category, "stickers": records}
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"{pack_slug}.stickerpack"
    temporary = output.with_suffix(".tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
        for relative, data in sorted(payloads.items()): archive.writestr(relative, data)
    temporary.replace(output)
    print(f"{title}: {len(records)} stickers -> {output.name}")
    return output


if __name__ == "__main__":
    ocr_path = Path(__file__).with_name("sticker_ocr_tags.json")
    if ocr_path.exists(): OCR_TAGS.update(json.loads(ocr_path.read_text(encoding="utf-8")))
    if len(sys.argv) == 4 and sys.argv[3].endswith(".json"):
        root, destination, selection = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
        specification = json.loads(selection.read_text(encoding="utf-8"))
        for category, names in specification["categories"].items():
            for name in names: build_pack(root / name, destination, category)
    else:
        if len(sys.argv) < 4:
            raise SystemExit("usage: build_wechat_emoticon_packs.py REPO OUTPUT PACK... | selection.json")
        root, destination = Path(sys.argv[1]), Path(sys.argv[2])
        for name in sys.argv[3:]: build_pack(root / name, destination)
