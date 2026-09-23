#!/usr/bin/env python3
"""Safely inspect WeChat's NSKeyedArchiver sticker metadata without loading private classes."""
import collections
import hashlib
import json
import os
import plistlib
import sys
import urllib.parse


def main(path: str) -> None:
    with open(path, "rb") as handle:
        archive = plistlib.load(handle)
    objects = archive["$objects"]

    def index(value):
        return value.data if isinstance(value, plistlib.UID) else None

    def class_name(value):
        if not isinstance(value, dict) or "$class" not in value:
            return None
        item = objects[index(value["$class"])]
        return item.get("$classname") if isinstance(item, dict) else None

    def decode(value, seen=None):
        seen = set() if seen is None else seen
        uid = index(value)
        if uid is not None:
            if uid in seen:
                return "<cycle>"
            return decode(objects[uid], seen | {uid})
        if isinstance(value, list):
            return [decode(item, seen) for item in value]
        if not isinstance(value, dict):
            return None if value == "$null" else value
        kind = class_name(value)
        if kind in {"NSArray", "NSMutableArray", "NSSet", "NSMutableSet"}:
            return [decode(item, seen) for item in value.get("NS.objects", [])]
        if kind in {"NSDictionary", "NSMutableDictionary"}:
            keys = [decode(item, seen) for item in value.get("NS.keys", [])]
            vals = [decode(item, seen) for item in value.get("NS.objects", [])]
            return dict(zip(keys, vals))
        if kind in {"NSString", "NSMutableString"} and "NS.string" in value:
            return decode(value["NS.string"], seen)
        if kind == "NSData" and "NS.data" in value:
            data = value["NS.data"]
            return {"dataBytes": len(data) if isinstance(data, bytes) else None}
        return {key: decode(item, seen) for key, item in value.items() if key != "$class"}

    stickers = []
    for obj in objects:
        if isinstance(obj, dict) and class_name(obj) == "MMEmoticonData":
            stickers.append({key: decode(value) for key, value in obj.items() if key != "$class"})

    fields = collections.Counter()
    nonempty = collections.Counter()
    types = collections.Counter()
    hosts = collections.Counter()
    md5s = []
    for sticker in stickers:
        fields.update(sticker.keys())
        for key, value in sticker.items():
            if value not in (None, "", 0, [], {}):
                nonempty[key] += 1
        types[str(sticker.get("type"))] += 1
        md5 = sticker.get("md5")
        if isinstance(md5, str):
            md5s.append(md5)
        for key in ("cdnurl", "tpurl"):
            value = sticker.get(key)
            if isinstance(value, str) and value:
                hosts[urllib.parse.urlparse(value).hostname or "<relative>"] += 1

    summary = {
        "archiveVersion": archive.get("$version"),
        "archiver": archive.get("$archiver"),
        "objectCount": len(objects),
        "stickerCount": len(stickers),
        "uniqueMD5Count": len(set(md5s)),
        "duplicateMD5Count": len(md5s) - len(set(md5s)),
        "fields": {key: {"present": fields[key], "nonempty": nonempty[key]}
                   for key in sorted(fields)},
        "typeDistribution": dict(types),
        "urlHosts": dict(hosts),
        "sample": [
            {
                key: ((value[:8] + "…") if key == "md5" and isinstance(value, str)
                      else urllib.parse.urlparse(value).hostname if key in {"cdnurl", "tpurl"} and isinstance(value, str)
                      else value)
                for key, value in sticker.items()
            }
            for sticker in stickers[:3]
        ],
    }
    if len(sys.argv) == 3:
        root = sys.argv[2]
        media = {}
        magic_counts = collections.Counter()
        content_md5_matches = 0
        for folder in ("Persistence", "NonPersistence", "Thumbs"):
            directory = os.path.join(root, folder)
            names = set(os.listdir(directory)) if os.path.isdir(directory) else set()
            matched = 0
            for md5 in md5s:
                candidates = [name for name in names if name == md5 or name.startswith(md5 + ".")]
                if not candidates:
                    continue
                matched += 1
                if folder != "Persistence":
                    continue
                path = os.path.join(directory, candidates[0])
                with open(path, "rb") as handle:
                    data = handle.read()
                if hashlib.md5(data).hexdigest() == md5:
                    content_md5_matches += 1
                head = data[:12]
                if head[:6] in (b"GIF87a", b"GIF89a"): kind = "gif"
                elif head.startswith(b"\x89PNG\r\n\x1a\n"): kind = "png"
                elif head.startswith(b"\xff\xd8\xff"): kind = "jpeg"
                elif head.startswith(b"RIFF") and head[8:12] == b"WEBP": kind = "webp"
                else: kind = "unknown"
                magic_counts[kind] += 1
            media[folder] = matched
        summary["localMedia"] = {
            "matchedFavoriteNames": media,
            "persistenceContentMD5Matches": content_md5_matches,
            "persistenceMagic": dict(magic_counts),
        }
    print(json.dumps(summary, ensure_ascii=False, indent=2, default=str))


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        raise SystemExit("usage: inspect_wechat_favorites.py /path/to/fav.archive [Stickers directory]")
    main(sys.argv[1])
