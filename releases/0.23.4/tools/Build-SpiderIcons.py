"""Export the supplied SVG size variants without changing fixed eyes/background.

Build-time only: Pillow + Playwright and a local Chrome installation.
Runtime uses pre-rendered PNG/ICO assets and has no SVG/browser dependency.
"""
from pathlib import Path
from io import BytesIO
import argparse
import json
import struct
from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright


def write_ico(path, frames):
    chunks = [(size, image) for size, image in sorted(frames.items())]
    header = struct.pack('<HHH', 0, 1, len(chunks))
    offset = 6 + 16 * len(chunks)
    entries = []
    for size, data in chunks:
        entries.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    path.write_bytes(header + b''.join(entries) + b''.join(data for _, data in chunks))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    args.assets.mkdir(parents=True, exist_ok=True)
    args.report.mkdir(parents=True, exist_ok=True)
    source = args.source.read_text(encoding='utf-8-sig')
    states = {'TradeChannel': '#FFFFFF', 'TradeChannel-connected': '#22C55E',
              'TradeChannel-busy': '#F5A524', 'TradeChannel-idle': '#98A2B3',
              'TradeChannel-fault': '#98A2B3'}
    sizes = (16, 20, 24, 32, 40, 48, 64, 128, 256)
    rendered = {}
    with sync_playwright() as pw:
        browser = pw.chromium.launch(executable_path=r'C:\Program Files\Google\Chrome\Application\chrome.exe', headless=True)
        page = browser.new_page(viewport={'width': 300, 'height': 300}, device_scale_factor=1)
        page.route('**/*', lambda route: route.abort())
        for name, color in states.items():
            frames = {}
            for size in sizes:
                page.set_content('<html><body style="margin:0;background:transparent">' + source + '</body></html>')
                page.evaluate('''([size, color, fault]) => {
                    const svg = document.querySelector('svg'); svg.setAttribute('width', size); svg.setAttribute('height', size);
                    const small = size <= 24;
                    document.getElementById('zMaster').setAttribute('visibility', small ? 'hidden' : 'visible');
                    document.getElementById('zMaster16').setAttribute('visibility', small ? 'visible' : 'hidden');
                    for (const group of ['zMaster', 'zMaster16']) {
                        const g = document.getElementById(group);
                        g.querySelector('use').setAttribute('stroke', color); g.querySelector('ellipse').setAttribute('fill', color);
                    }
                    if (fault) {
                        const ns = 'http://www.w3.org/2000/svg';
                        const circle = document.createElementNS(ns,'circle'); circle.setAttribute('cx','204'); circle.setAttribute('cy','52'); circle.setAttribute('r','45'); circle.setAttribute('fill','#0F1A38'); circle.setAttribute('stroke','#FFFFFF'); circle.setAttribute('stroke-width','12'); svg.appendChild(circle);
                        const line = document.createElementNS(ns,'path'); line.setAttribute('d','M204 25 L204 54 M204 73 L204 74'); line.setAttribute('stroke','#FFFFFF'); line.setAttribute('stroke-width','14'); line.setAttribute('stroke-linecap','round'); svg.appendChild(line);
                    }
                }''', [size, color, name.endswith('fault')])
                data = page.locator('svg').screenshot(omit_background=True)
                image = Image.open(BytesIO(data)).convert('RGBA')
                if image.size != (size, size) or image.getbbox() is None:
                    raise RuntimeError('Empty or wrong-size frame')
                frames[size] = data
                rendered[(name, size)] = image.copy()
            write_ico(args.assets / (name + '.ico'), frames)
            (args.assets / (name + '.png')).write_bytes(frames[256])
            if name == 'TradeChannel':
                (args.assets / 'TradeChannel-small.png').write_bytes(frames[24])
            with Image.open(args.assets / (name + '.ico')) as icon:
                if icon.ico.sizes() != {(s, s) for s in sizes}:
                    raise RuntimeError('ICO size table mismatch')
                for size in sizes:
                    decoded = icon.ico.getimage((size, size)).convert('RGBA')
                    if decoded.tobytes() != rendered[(name, size)].tobytes():
                        raise RuntimeError('ICO embedded frame differs from rendered size variant')
        browser.close()
    sheet = Image.new('RGB', (1000, 430), '#F5F6F8')
    draw = ImageDraw.Draw(sheet)
    for row, name in enumerate(states):
        draw.text((12, row * 82 + 20), name.replace('TradeChannel', 'TC'), fill='#15181D')
        for col, size in enumerate(sizes):
            x = 160 + col * 90
            im = rendered[(name, size)]
            if size > 48:
                im = im.resize((48, 48), Image.Resampling.LANCZOS)
            sheet.paste(im, (x, row * 82 + 4), im)
            draw.text((x, row * 82 + 56), str(size), fill='#4B5360')
    sheet.save(args.report / 'icon-size-sheet.png')
    (args.report / 'icon-build.json').write_text(json.dumps({'States': list(states), 'Sizes': list(sizes),
        'EmbeddedFramesVerified': True, 'SmallVariant': 'zMaster16', 'ExternalRequestsBlocked': True}, indent=2), encoding='utf-8')
    print(json.dumps({'States': len(states), 'Sizes': list(sizes), 'VerifiedFrames': len(states) * len(sizes)}))


if __name__ == '__main__':
    main()
