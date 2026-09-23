#!/usr/bin/env python3
"""Build a v1 stickerpack from WeChat's locally installed standard emoji assets."""

import hashlib
import json
import struct
import sys
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree


def png_size(data: bytes) -> tuple[int, int]:
    if not data.startswith(b"\x89PNG\r\n\x1a\n") or data[12:16] != b"IHDR":
        raise ValueError("not a valid PNG")
    return struct.unpack(">II", data[16:24])


def clean(value: str | None) -> str:
    return (value or "").strip().removeprefix("[").removesuffix("]")


def build(source: Path, output: Path) -> None:
    root = ElementTree.parse(source / "newemoji-config.xml").getroot()
    records: list[dict] = []
    payloads: dict[str, bytes] = {}

    for emoji in root.findall(".//emoji"):
        filename = clean(emoji.findtext("fileName"))
        media = source / filename
        if not filename or not media.is_file():
            continue
        data = media.read_bytes()
        width, height = png_size(data)
        digest = hashlib.sha256(data).hexdigest()
        relative = f"media/{digest}.png"
        keywords = []
        for field in ("cn-value", "qq-value", "tw-value", "en-value", "key"):
            value = clean(emoji.findtext(field))
            if value and value not in keywords:
                keywords.append(value)
        records.append({
            "id": f"sha256:{digest}",
            "file": relative,
            "mediaType": "image/png",
            "byteCount": len(data),
            "width": width,
            "height": height,
            "keywords": keywords,
        })
        payloads[relative] = data

    manifest = {
        "formatVersion": 1,
        "packID": "wechat-official-standard-emoji",
        "title": "微信官方扩展表情",
        "stickers": records,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".tmp", delete=False) as temp:
        temporary = Path(temp.name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED) as archive:
            archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2))
            for relative, data in sorted(payloads.items()):
                archive.writestr(relative, data)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"stickers={len(records)} bytes={output.stat().st_size}")
    print(f"pack={output}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: build_wechat_standard_stickerpack.py SOURCE_DIR OUTPUT")
    build(Path(sys.argv[1]), Path(sys.argv[2]))
