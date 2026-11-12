#!/usr/bin/env python3
"""Regenerate checked-in geometric TunnelOne icons (requires Pillow)."""
from pathlib import Path
import json
from PIL import Image, ImageDraw

base = Path(__file__).resolve().parent.parent / "Sources/WireGuardApp/UI/macOS/Assets.xcassets"
icons = base / "AppIcon.appiconset"
for item in json.loads((icons / "Contents.json").read_text())["images"]:
    size = int(float(item["size"].split("x")[0]) * float(item["scale"].rstrip("x")))
    scale = 4
    image = Image.new("RGBA", (size * scale, size * scale))
    draw = ImageDraw.Draw(image)

    def xy(value):
        return int(value * size * scale / 96)

    draw.rounded_rectangle((xy(4), xy(4), xy(92), xy(92)), radius=xy(22), fill="#153c36")
    for coordinates in [(25, 30, 71, 30), (38, 30, 38, 67), (58, 44, 58, 67)]:
        draw.line(tuple(xy(value) for value in coordinates), fill="#9ef8ca", width=max(1, xy(9)))
        for x, y in [(coordinates[0], coordinates[1]), (coordinates[2], coordinates[3])]:
            draw.ellipse((xy(x - 4.5), xy(y - 4.5), xy(x + 4.5), xy(y + 4.5)), fill="#9ef8ca")
    draw.ellipse((xy(53), xy(25), xy(63), xy(35)), fill="white")
    image.resize((size, size), Image.Resampling.LANCZOS).save(icons / item["filename"])

for directory in ["StatusBarIcon.imageset", "StatusBarIconDimmed.imageset",
                  "StatusBarIconDot1.imageset", "StatusBarIconDot3.imageset"]:
    for path in (base / directory).glob("*.png"):
        with Image.open(path) as original:
            width, height = original.size
        image = Image.new("RGBA", (width * 4, height * 4))
        draw = ImageDraw.Draw(image)
        color = (0, 0, 0, 110 if "Dimmed" in directory else 255)
        for a, b, c, d in [(.22, .24, .78, .24), (.39, .24, .39, .8), (.62, .45, .62, .8)]:
            draw.line((a * width * 4, b * height * 4, c * width * 4, d * height * 4),
                      fill=color, width=max(2, int(width * 4 * .11)))
        image.resize((width, height), Image.Resampling.LANCZOS).save(path)
print("TunnelOne icons generated.")
