#!/usr/bin/env python3
"""Probe a few favorite-sticker CDN objects without printing private URLs."""
import collections
import hashlib
import os
import plistlib
import sys
import urllib.parse
import urllib.error
import urllib.request


def favorite_records(path):
    with open(path, "rb") as handle:
        archive = plistlib.load(handle)
    objects = archive["$objects"]

    def uid(value):
        return value.data if isinstance(value, plistlib.UID) else None

    def class_name(value):
        if not isinstance(value, dict) or "$class" not in value:
            return None
        item = objects[uid(value["$class"])]
        return item.get("$classname") if isinstance(item, dict) else None

    def decode(value, seen=None):
        seen = set() if seen is None else seen
        number = uid(value)
        if number is not None:
            if number in seen:
                return None
            return decode(objects[number], seen | {number})
        if value == "$null":
            return None
        if isinstance(value, list):
            return [decode(item, seen) for item in value]
        if not isinstance(value, dict):
            return value
        kind = class_name(value)
        if kind in {"NSString", "NSMutableString"}:
            return decode(value.get("NS.string"), seen)
        return {key: decode(item, seen) for key, item in value.items() if key != "$class"}

    return [
        {key: decode(value) for key, value in item.items() if key != "$class"}
        for item in objects
        if isinstance(item, dict) and class_name(item) == "MMEmoticonData"
    ]


def media_type(data):
    head = data[:12]
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if head.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if head.startswith(b"RIFF") and head[8:12] == b"WEBP":
        return "webp"
    return "unknown"


def main(archive_path, output_dir):
    records = favorite_records(archive_path)
    by_host = collections.defaultdict(list)
    for record in records:
        url = record.get("cdnurl")
        if isinstance(url, str) and url:
            by_host[urllib.parse.urlparse(url).hostname or "<relative>"].append(record)

    os.makedirs(output_dir, exist_ok=True)
    print(f"favorites={len(records)} hosts={len(by_host)}")
    for host, items in sorted(by_host.items()):
        print(f"host={host} available={len(items)} probing={min(2, len(items))}")
        for ordinal, record in enumerate(items[:2], 1):
            expected = record.get("md5")
            try:
                request = urllib.request.Request(record["cdnurl"], headers={"User-Agent": "Mozilla/5.0"})
                with urllib.request.urlopen(request, timeout=20) as response:
                    announced = response.headers.get("Content-Length")
                    if announced and int(announced) > 10 * 1024 * 1024:
                        raise ValueError("declared object exceeds 10 MB")
                    data = response.read(10 * 1024 * 1024 + 1)
                if len(data) > 10 * 1024 * 1024:
                    raise ValueError("object exceeds 10 MB")
                actual = hashlib.md5(data).hexdigest()
                kind = media_type(data)
                verified = isinstance(expected, str) and actual == expected.lower()
                print(f"  sample={ordinal} status=ok bytes={len(data)} type={kind} md5Match={str(verified).lower()}")
                if verified and kind != "unknown":
                    with open(os.path.join(output_dir, f"{expected}.{kind}"), "wb") as handle:
                        handle.write(data)
            except urllib.error.HTTPError as error:
                print(f"  sample={ordinal} status=failed error=HTTP{error.code}")
            except Exception as error:
                print(f"  sample={ordinal} status=failed error={type(error).__name__}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: probe_wechat_sticker_media.py fav.archive output-directory")
    main(sys.argv[1], sys.argv[2])
