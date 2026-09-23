#!/usr/bin/env python3
"""Build a private v1 stickerpack from WeChat favorites without touching WeChat data."""
import hashlib, json, os, plistlib, shutil, struct, sys, tempfile, urllib.error, urllib.parse, urllib.request, zipfile

MAX_FILE = 10 * 1024 * 1024
MAX_TOTAL = 500 * 1024 * 1024


def records(path):
    with open(path, "rb") as f: archive = plistlib.load(f)
    objects = archive["$objects"]
    def uid(v): return v.data if isinstance(v, plistlib.UID) else None
    def cls(v):
        if not isinstance(v, dict) or "$class" not in v: return None
        item = objects[uid(v["$class"])]
        return item.get("$classname") if isinstance(item, dict) else None
    def dec(v, seen=frozenset()):
        number = uid(v)
        if number is not None:
            return None if number in seen else dec(objects[number], seen | {number})
        if v == "$null": return None
        if isinstance(v, list): return [dec(x, seen) for x in v]
        if not isinstance(v, dict): return v
        if cls(v) in {"NSString", "NSMutableString"}: return dec(v.get("NS.string"), seen)
        return {k: dec(x, seen) for k, x in v.items() if k != "$class"}
    return [{k: dec(v) for k, v in x.items() if k != "$class"} for x in objects
            if isinstance(x, dict) and cls(x) == "MMEmoticonData"]


def identify(data):
    if data[:6] in (b"GIF87a", b"GIF89a"):
        width, height = struct.unpack("<HH", data[6:10]); return "image/gif", "gif", width, height
    if data.startswith(b"\x89PNG\r\n\x1a\n") and data[12:16] == b"IHDR":
        width, height = struct.unpack(">II", data[16:24]); return "image/png", "png", width, height
    if data.startswith(b"\xff\xd8\xff"):
        offset = 2
        while offset + 9 < len(data):
            if data[offset] != 0xFF: offset += 1; continue
            marker = data[offset + 1]; offset += 2
            if marker in (0xD8, 0xD9): continue
            if offset + 2 > len(data): break
            length = int.from_bytes(data[offset:offset + 2], "big")
            if marker in range(0xC0, 0xC4) and offset + 7 < len(data):
                height = int.from_bytes(data[offset + 3:offset + 5], "big")
                width = int.from_bytes(data[offset + 5:offset + 7], "big")
                return "image/jpeg", "jpg", width, height
            offset += max(length, 2)
    raise ValueError("unsupported or invalid image")


def download(record):
    request = urllib.request.Request(record["cdnurl"], headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        announced = response.headers.get("Content-Length")
        if announced and int(announced) > MAX_FILE: raise ValueError("tooLarge")
        data = response.read(MAX_FILE + 1)
    if len(data) > MAX_FILE: raise ValueError("tooLarge")
    if hashlib.md5(data).hexdigest() != record["md5"].lower(): raise ValueError("md5Mismatch")
    return data


def main(archive_path, destination):
    destination = os.path.abspath(destination)
    os.makedirs(destination, exist_ok=True)
    staging = tempfile.mkdtemp(prefix="wechat-stickers-", dir=destination)
    report, manifest, total = [], [], 0
    media = os.path.join(staging, "media"); os.makedirs(media)
    try:
        for number, record in enumerate(records(archive_path), 1):
            source = record.get("md5")
            host = urllib.parse.urlparse(record.get("cdnurl") or "").hostname
            try:
                data = download(record); media_type, ext, width, height = identify(data)
                total += len(data)
                if total > MAX_TOTAL: raise ValueError("totalTooLarge")
                digest = hashlib.sha256(data).hexdigest(); filename = f"media/{digest}.{ext}"
                target = os.path.join(staging, filename)
                if not os.path.exists(target):
                    with open(target, "wb") as f: f.write(data)
                manifest.append({"id": f"sha256:{digest}", "file": filename, "mediaType": media_type,
                                 "byteCount": len(data), "width": width, "height": height, "keywords": []})
                report.append({"sourceMD5": source, "host": host, "status": "exported", "id": f"sha256:{digest}"})
            except urllib.error.HTTPError as error:
                report.append({"sourceMD5": source, "host": host, "status": "missing", "reason": f"HTTP{error.code}"})
            except Exception as error:
                report.append({"sourceMD5": source, "host": host, "status": "skipped", "reason": str(error)})
            if number % 25 == 0: print(f"processed={number}", flush=True)

        pack = {"formatVersion": 1, "packID": "family-wechat-favorites", "title": "我们的收藏表情",
                "stickers": manifest}
        with open(os.path.join(staging, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(pack, f, ensure_ascii=False, indent=2)
        archive_dir = os.path.join(destination, "WeChatStickerArchive")
        os.makedirs(os.path.join(archive_dir, "raw"), exist_ok=True)
        os.makedirs(os.path.join(archive_dir, "metadata"), exist_ok=True)
        os.makedirs(os.path.join(archive_dir, "exported"), exist_ok=True)
        os.makedirs(os.path.join(archive_dir, "iPhone"), exist_ok=True)
        shutil.copy2(archive_path, os.path.join(archive_dir, "raw", "fav.archive"))
        with open(os.path.join(archive_dir, "metadata", "export-report.json"), "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        for name in os.listdir(media): shutil.copy2(os.path.join(media, name), os.path.join(archive_dir, "exported", name))
        output = os.path.join(archive_dir, "iPhone", "family.stickerpack")
        temporary = output + ".tmp"
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED) as package:
            package.write(os.path.join(staging, "manifest.json"), "manifest.json")
            for name in sorted(os.listdir(media)): package.write(os.path.join(media, name), f"media/{name}")
        os.replace(temporary, output)
        exported = sum(item["status"] == "exported" for item in report)
        missing = sum(item["status"] != "exported" for item in report)
        print(f"exported={exported} missingOrSkipped={missing} bytes={total}")
        print(f"pack={output}")
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 3: raise SystemExit("usage: build_wechat_stickerpack.py fav.archive destination-parent")
    main(sys.argv[1], sys.argv[2])
