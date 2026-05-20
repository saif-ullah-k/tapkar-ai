"""Generate Android launcher icons from the square logo.

Source is logo-square.png — already 1024×1024 with orb + wordmark + tagline
laid out for a square crop. We resize directly (no cropping) so the
launcher icon carries the full brand mark. Both ic_launcher.png (regular)
and ic_launcher_round.png (Android 7.1+ adaptive) are written.
"""
from pathlib import Path
from PIL import Image

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / 'branding' / 'logo-square.png'
ANDROID_RES = REPO / 'mobile' / 'tapkar_ai' / 'android' / 'app' / 'src' / 'main' / 'res'

# Material design recommends these densities (pixel sizes for the legacy
# square icon; adaptive icons use 108x108dp foreground sized to the same
# pixel resolutions).
DENSITIES = {
    'mipmap-mdpi':    48,
    'mipmap-hdpi':    72,
    'mipmap-xhdpi':   96,
    'mipmap-xxhdpi':  144,
    'mipmap-xxxhdpi': 192,
}


def main():
    src = Image.open(SRC).convert('RGBA')
    print(f'source: {SRC.name}  {src.size}')

    # Legacy launcher icons (Android <8). Full-bleed square logo at each
    # density. Newer Androids ignore these in favor of the adaptive
    # icon XML written separately below.
    for folder, size in DENSITIES.items():
        dest_dir = ANDROID_RES / folder
        dest_dir.mkdir(parents=True, exist_ok=True)
        icon = src.resize((size, size), Image.LANCZOS)
        icon.save(dest_dir / 'ic_launcher.png', optimize=True)
        icon.save(dest_dir / 'ic_launcher_round.png', optimize=True)
        print(f'  wrote {folder}/ic_launcher.png + _round  ({size}x{size})')

    # Adaptive icon foreground (Android 8+). Adaptive icons render on a
    # 108dp canvas but only the inner 66dp is the "safe zone" that's
    # guaranteed visible — the outer 21dp on each side gets cropped by
    # the launcher's mask (circle / squircle / squared-off, etc.). So
    # the actual logo content must fit inside that 66/108 = ~61% center.
    # We paint the logo onto a black 108-unit canvas, sized so it lives
    # in the safe zone with a sliver of breathing room.
    # Foreground PNGs ship at xxxhdpi (432px = 108dp × 4) at every
    # density, alongside the legacy ic_launcher.png.
    SAFE_RATIO = 0.85  # logo fills 85% of the safe zone for slight margin
    for folder, size in DENSITIES.items():
        dest_dir = ANDROID_RES / folder
        # Adaptive icon foregrounds use the 108dp coordinate space.
        # Pixel dimension is 108/48 * mdpi-size for each density.
        fg_size = size * 108 // 48
        canvas = Image.new('RGBA', (fg_size, fg_size), (0, 0, 0, 255))
        # Inner safe zone is 66dp of 108dp → 0.611 * fg_size.
        safe = int(fg_size * 0.611 * SAFE_RATIO)
        logo = src.resize((safe, safe), Image.LANCZOS)
        offset = (fg_size - safe) // 2
        canvas.paste(logo, (offset, offset), logo)
        canvas.save(dest_dir / 'ic_launcher_foreground.png', optimize=True)
        print(f'  wrote {folder}/ic_launcher_foreground.png  ({fg_size}x{fg_size})')

    # Adaptive icon descriptors — one shared XML in mipmap-anydpi-v26
    # tells Android to compose foreground + black background. Both
    # ic_launcher.xml and ic_launcher_round.xml so the round-icon
    # manifest reference resolves.
    anydpi = ANDROID_RES / 'mipmap-anydpi-v26'
    anydpi.mkdir(parents=True, exist_ok=True)
    adaptive_xml = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
'''
    for name in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        (anydpi / name).write_text(adaptive_xml, encoding='utf-8')
        print(f'  wrote mipmap-anydpi-v26/{name}')

    # Background color resource — solid black so it merges with the
    # logo's own black background and no white ring appears.
    values = ANDROID_RES / 'values'
    values.mkdir(parents=True, exist_ok=True)
    colors_path = values / 'ic_launcher_background.xml'
    colors_path.write_text('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#000000</color>
</resources>
''', encoding='utf-8')
    print(f'  wrote values/ic_launcher_background.xml')


if __name__ == '__main__':
    main()
