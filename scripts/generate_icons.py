#!/usr/bin/env python3
"""Render LRDP's own vector artwork into the platform launcher resources.

Requires Python 3, CairoSVG and Pillow. No Flutter launcher plugin or online
service is needed. The SVG is the single source for all shapes and colours.
"""
from copy import deepcopy
from io import BytesIO
from pathlib import Path
import json
import xml.etree.ElementTree as ET

import cairosvg
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / 'assets/branding'
SVG_NS = 'http://www.w3.org/2000/svg'
ANDROID_NS = 'http://schemas.android.com/apk/res/android'
ET.register_namespace('', SVG_NS)
ET.register_namespace('android', ANDROID_NS)


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def vector(rounded=False):
    svg = ET.parse(BRAND / 'lrdp.svg').getroot()
    if rounded:
        rect = svg.find(f'{{{SVG_NS}}}rect')
        rect.set('x', '32')
        rect.set('y', '32')
        rect.set('width', '960')
        rect.set('height', '960')
        rect.set('rx', '216')
    return ET.tostring(svg)


def render(svg, size):
    return cairosvg.svg2png(bytestring=svg, output_width=size, output_height=size)


def adaptive_drawable(mark):
    def attr(name):
        return f'{{{ANDROID_NS}}}{name}'
    drawable = ET.Element('vector', {
        attr('width'): '108dp', attr('height'): '108dp',
        attr('viewportWidth'): '1024', attr('viewportHeight'): '1024',
    })
    # Keep the complete mark inside Android's central 66 dp safe circle.
    group = ET.SubElement(drawable, 'group', {
        attr('scaleX'): '0.82', attr('scaleY'): '0.82',
        attr('translateX'): '92.16', attr('translateY'): '92.16',
    })
    for source in mark:
        ET.SubElement(group, 'path', {
            attr('pathData'): source.attrib['d'], attr('fillColor'): '#00000000',
            attr('strokeColor'): source.attrib['stroke'],
            attr('strokeWidth'): source.attrib['stroke-width'],
            attr('strokeLineCap'): 'round', attr('strokeLineJoin'): 'round',
        })
    ET.indent(drawable)
    return ET.tostring(drawable, encoding='utf-8', xml_declaration=True) + b'\n'


def main():
    square, rounded = vector(), vector(rounded=True)
    write(BRAND / 'lrdp.png', render(square, 1024))
    write(BRAND / 'lrdp-rounded.png', render(rounded, 1024))
    write(BRAND / 'lrdp-rounded.svg', rounded)
    for size in (36, 64, 128, 256, 512):
        write(BRAND / f'lrdp-{size}.png', render(rounded, size))

    res = ROOT / 'android/app/src/main/res'
    for density, size in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96,
                          'xxhdpi': 144, 'xxxhdpi': 192}.items():
        write(res / f'mipmap-{density}/ic_launcher.png', render(rounded, size))
    source = ET.parse(BRAND / 'lrdp.svg').getroot()
    mark = source.find(f'{{{SVG_NS}}}g')
    write(res / 'drawable/ic_launcher_foreground.xml', adaptive_drawable(mark))
    monochrome = deepcopy(mark)
    for path in monochrome:
        path.set('stroke', '#FFFFFF')
    write(res / 'drawable/ic_launcher_monochrome.xml', adaptive_drawable(monochrome))
    write(res / 'values/icon_colors.xml', f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">{source.attrib['data-adaptive-background']}</color>
</resources>
'''.encode())
    # API 26–32 use the two-layer icon; API 33+ also support themed icons.
    for version in (26, 33):
        themed = ('    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
                  if version >= 33 else '')
        write(res / f'mipmap-anydpi-v{version}/ic_launcher.xml', (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background" />\n'
            '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'
            f'{themed}</adaptive-icon>\n').encode())

    for platform in ('ios', 'macos'):
        iconset = ROOT / platform / 'Runner/Assets.xcassets/AppIcon.appiconset'
        for entry in json.loads((iconset / 'Contents.json').read_text())['images']:
            size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
            data = render(square if platform == 'ios' else rounded, size)
            if platform == 'ios':
                # Apple app icons must be opaque; the OS supplies the mask.
                output = BytesIO()
                Image.open(BytesIO(data)).convert('RGB').save(output, format='PNG')
                data = output.getvalue()
            write(iconset / entry['filename'], data)

    ico = ROOT / 'windows/runner/resources/app_icon.ico'
    ico_data = BytesIO()
    Image.open(BytesIO(render(rounded, 256))).save(
        ico_data, format='ICO', sizes=[(size, size) for size in (16, 20, 24, 32, 40, 48, 64, 128, 256)])
    write(ico, ico_data.getvalue())

    # A review sheet showing the actual exported artwork at small sizes.
    preview = Image.new('RGB', (1200, 680), '#F4F6F3')
    draw = ImageDraw.Draw(preview)
    try:
        font = ImageFont.truetype('DejaVuSans.ttf', 24)
        small = ImageFont.truetype('DejaVuSans.ttf', 18)
    except OSError:
        font = ImageFont.load_default(size=24)
        small = ImageFont.load_default(size=18)
    draw.text((48, 36), 'LRDP', fill='#182D28', font=font)
    draw.text((48, 78), 'Remote desktop', fill='#52635B', font=small)
    icon = Image.open(BytesIO(render(rounded, 416)))
    preview.paste(icon, (40, 150), icon)
    draw.rounded_rectangle((504, 140, 1152, 360), 24, fill='#FFFFFF')
    draw.rounded_rectangle((504, 392, 1152, 612), 24, fill='#17211E')
    for y, colour in ((180, '#182D28'), (432, '#F2FAF4')):
        x = 540
        for size in (16, 24, 32, 48, 64, 96):
            icon = Image.open(BytesIO(render(rounded, size)))
            preview.paste(icon, (x, y + (96 - size) // 2), icon)
            draw.text((x, y + 112), str(size), fill=colour, font=small)
            x += size + 34
    draw.text((48, 612), 'Display + connection arrow', fill='#52635B', font=small)
    preview_data = BytesIO()
    preview.save(preview_data, format='PNG')
    write(BRAND / 'preview.png', preview_data.getvalue())
    print('Generated Android, iOS, macOS, Windows, Linux and Flutter branding icons.')


if __name__ == '__main__':
    main()
