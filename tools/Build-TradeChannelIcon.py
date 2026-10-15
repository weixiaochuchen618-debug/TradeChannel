"""Render the application's geometric mark for the Windows launcher and tray."""
from pathlib import Path
from PIL import Image, ImageDraw

assets = Path(__file__).resolve().parents[1] / "product" / "assets"
scale = 4
canvas = Image.new("RGBA", (256 * scale, 256 * scale), (0, 0, 0, 0))
draw = ImageDraw.Draw(canvas)
draw.rounded_rectangle((8 * scale, 8 * scale, 248 * scale, 248 * scale),
                       radius=65 * scale, fill="#315EEB")
points = [(65, 63), (111, 63), (111, 111), (190, 111),
          (190, 190), (144, 190), (144, 144), (65, 144), (65, 63)]
points = [(x * scale, y * scale) for x, y in points]
draw.line(points, fill="white", width=13 * scale, joint="curve")
for x, y in points:
    draw.ellipse((x - 6.5 * scale, y - 6.5 * scale,
                  x + 6.5 * scale, y + 6.5 * scale), fill="white")
mark = canvas.resize((256, 256), Image.Resampling.LANCZOS)
mark.save(assets / "TradeChannel.png")
mark.save(assets / "TradeChannel.ico", format="ICO",
          sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
