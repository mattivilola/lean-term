#!/usr/bin/env python3
"""Package the approved artwork. These tools resize/encode; they do not redesign it."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
APPROVED = ROOT / 'approved/crt-family'
OUTLINES = json.loads((ROOT / 'sources/wordmark-outlines.json').read_text())
SIZES = [16, 32, 48, 64, 128, 180, 192, 256, 512]
LEFT_BRACE = 'M38 18H26V22H22V38H18V42H12V54H18V58H22V74H26V78H38V68H32V56H28V40H32V28H38Z'
PROMPT = 'M18 18H26V26H34V34H42V42H50V50H42V58H34V66H26V74H18V62H26V54H34V46H38V42H34V38H26V30H18ZM54 62H78V74H54Z'


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


def embedded(path):
    return 'data:image/png;base64,' + base64.b64encode(path.read_bytes()).decode()


def svg(body, width=96, height=96, title=''):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            f'viewBox="0 0 {width} {height}" role="img" aria-label="{title}">'
            f'<title>{title}</title>{body}</svg>\n')


for slug, name, icns, tile, ink, accent in [
    ('lean-term', 'Lean Term', 'LeanTerm.icns', '#103e30', '#11382c', '#81ff95'),
    ('lean-vs-code', 'Lean VS Code', 'LeanVSCode.icns', '#073e46', '#0b363b', '#84ffdf')
]:
    folder = APPROVED / slug
    master = folder / 'app-icon-1024.png'
    for size in SIZES:
        run('/usr/bin/sips', '-z', str(size), str(size), str(master), '--out', str(folder / f'icon-{size}.png'))
    iconset = folder / 'AppIcon.iconset'
    iconset.mkdir(exist_ok=True)
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            filename = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
            source = master if size * scale == 1024 else folder / f'icon-{size * scale}.png'
            (iconset / filename).write_bytes(source.read_bytes())
    if slug == 'lean-term':
        with tempfile.TemporaryDirectory(prefix='leanterm-icon-') as temporary:
            extracted = Path(temporary) / 'Inherited.iconset'
            run('/usr/bin/iconutil', '--convert', 'iconset', str(folder / icns), '--output', str(extracted))
            for path in extracted.glob('*.png'):
                (iconset / path.name).write_bytes(path.read_bytes())
    # Keep the terminal's exact inherited ICNS; the editor is newly encoded.
    if slug == 'lean-vs-code' and '--skip-icns' not in sys.argv:
        run('/usr/bin/iconutil', '--convert', 'icns', str(iconset), '--output', str(folder / icns))
    run('/opt/homebrew/bin/magick', str(folder / 'icon-16.png'), str(folder / 'icon-32.png'), str(folder / 'icon-48.png'), str(folder / 'favicon.ico'))
    (folder / 'favicon-16x16.png').write_bytes((folder / 'icon-16.png').read_bytes())
    (folder / 'favicon-32x32.png').write_bytes((folder / 'icon-32.png').read_bytes())
    (folder / 'apple-touch-icon.png').write_bytes((folder / 'icon-180.png').read_bytes())
    image = f'<image width="96" height="96" xlink:href="{embedded(folder / "icon-128.png")}"/>'
    (folder / 'logo-mark.svg').write_text(svg(image, title=name))
    small_image = f'<image width="96" height="96" xlink:href="{embedded(folder / "icon-64.png")}"/>'
    (folder / 'favicon.svg').write_text(svg(small_image, title=name))
    if slug == 'lean-term':
        symbol = f'<path d="{PROMPT}"/>'
    else:
        symbol = f'<path d="{LEFT_BRACE}"/><path d="{LEFT_BRACE}" transform="translate(96 0) scale(-1 1)"/>'
    (folder / 'symbol.svg').write_text(svg(f'<g fill="{tile}">{symbol}</g>', title=name))
    (folder / 'symbol-monochrome.svg').write_text(svg(f'<g fill="currentColor">{symbol}</g>', title=name))
    (folder / 'safari-pinned-tab.svg').write_text(svg(f'<g fill="#000">{symbol}</g>', title=name))
    for theme, color in [('on-light', ink), ('on-dark', '#e8f7ef')]:
        text = OUTLINES[name]
        width = round(78 + text['width'] + 4, 3)
        body = (f'<image width="64" height="64" xlink:href="{embedded(folder / "icon-128.png")}"/>'
                f'<path fill="{color}" transform="translate(78 44) scale(1 -1)" d="{text["path"]}"/>')
        logo = folder / f'wordmark-{theme}.svg'
        logo.write_text(svg(body, width, 64, name))
        run('/opt/homebrew/bin/magick', '-background', 'none', '-density', '384', f'MSVG:{logo}', '-resize', '50%', str(folder / f'wordmark-{theme}@2x.png'))
    manifest = {'name': name, 'short_name': name, 'start_url': '/', 'display': 'browser',
                'background_color': '#f2f7f3', 'theme_color': tile,
                'icons': [{'src': f'icon-{size}.png', 'sizes': f'{size}x{size}', 'type': 'image/png', 'purpose': 'any'} for size in [192, 512]]}
    (folder / 'site.webmanifest').write_text(json.dumps(manifest, indent=2) + '\n')

files = sorted(path for path in APPROVED.rglob('*') if path.is_file() and path.name != 'manifest.json')
manifest = {'family': 'CRT family', 'approved_option': '01', 'date': '2026-11-04',
            'lean_term': 'Exact inherited emerald CRT >_ artwork from Lean VS Code; now assigned to the terminal.',
            'lean_vs_code': 'New teal CRT with mint curly braces, generated with built-in imagegen from approved option 01.',
            'files': {str(path.relative_to(APPROVED)): {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for path in files}}
(APPROVED / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Packaged {len(files)} approved brand files.')
