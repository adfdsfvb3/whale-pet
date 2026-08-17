#!/usr/bin/env python3
"""Extract webm pet animations to keyed transparent PNG sequences.

The dsh-pet webms are VP9 with a separate alpha plane that PyAV/ffmpeg
cannot decode; the color plane is black where the browser shows
transparency. We key on that black: alpha = smoothstep(maxRGB, 24, 48),
slightly blurred, then quantize to a 255-color palette to keep size down.

Usage: extract_frames.py <src-thumb-dir> <out-dir>
Output: <out-dir>/<action>/NNN.png at 12 fps, 240x240.
"""
import os
import sys

import av
import numpy as np
from PIL import Image, ImageFilter

ACTIONS = {
    "idle": "待机呼吸休闲",
    "drag": "被鼠标拖拽悬空反馈",
    "happy": "点击回应 - 开心跃动",
    "shy": "点击回应 - 害羞惊讶",
    "angry": "点击回应 - 傲娇生气（侧身展示）",
    "look": "东张西望",
    "hum": "悠闲哼歌",
    "stretch": "超大伸懒腰",
    "cube": "原地专心玩魔方",
    "crab": "螃蟹走路",
}


def extract(src: str, out_dir: str, size: int = 240, step: int = 2) -> int:
    os.makedirs(out_dir, exist_ok=True)
    container = av.open(src)
    saved = 0
    for i, frame in enumerate(container.decode(video=0)):
        if i % step:
            continue
        img = frame.to_image().resize((size, size), Image.LANCZOS).convert("RGB")
        rgb = np.asarray(img).astype(np.float32)
        alpha = np.clip((rgb.max(axis=2) - 24.0) / 24.0, 0, 1)
        matte = Image.fromarray((alpha * 255).astype(np.uint8)).filter(
            ImageFilter.GaussianBlur(0.6)
        )
        rgba = img.convert("RGBA")
        rgba.putalpha(matte)
        rgba.quantize(
            colors=255, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG
        ).save(f"{out_dir}/{saved:03d}.png")
        saved += 1
    container.close()
    return saved


def main() -> None:
    src_dir, out_root = sys.argv[1], sys.argv[2]
    for action, filename in ACTIONS.items():
        n = extract(os.path.join(src_dir, filename + ".webm"), os.path.join(out_root, action))
        print(f"{action}: {n} frames")


if __name__ == "__main__":
    main()
