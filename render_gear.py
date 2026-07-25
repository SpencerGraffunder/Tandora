"""Render U+2699 GEAR glyph from Apple Symbols font to a PNG sprite."""
from PIL import Image, ImageDraw, ImageFont

GLYPH = "\u2699"  # ⚙
FONT_PATH = "/System/Library/Fonts/Apple Symbols.ttf"
OUT_PATH = "assets/gear_icon.png"

font = ImageFont.truetype(FONT_PATH, size=120)

img = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

bbox = draw.textbbox((0, 0), GLYPH, font=font)
tw = bbox[2] - bbox[0]
th = bbox[3] - bbox[1]
x = (200 - tw) // 2 - bbox[0]
y = (200 - th) // 2 - bbox[1]

draw.text((x, y), GLYPH, font=font, fill=(255, 255, 255, 255))

crop = img.getbbox()
if crop:
    img = img.crop(crop)
    padded = Image.new("RGBA", (img.width + 8, img.height + 8), (0, 0, 0, 0))
    padded.paste(img, (4, 4))
    img = padded

img.save(OUT_PATH)
print(f"Saved {img.size[0]}x{img.size[1]} {OUT_PATH}")
