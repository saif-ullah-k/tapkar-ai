"""Generate Android launcher icons from the wordmark logo.

Crops the orb portion (left square chunk of the horizontal wordmark) and
exports it at all required mipmap densities. Both ic_launcher.png (regular)
and ic_launcher_round.png (Android 7.1+ adaptive) are written.
"""
from pathlib import Path
from PIL import Image

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / 'branding' / 'logo-wordmark.png'
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


def crop_orb(src: Image.Image) -> Image.Image:
    """Take the leftmost square region of the wordmark — that's the orb
    plus a little breathing room. Background is already black so it tiles
    nicely with the orb's outer glow."""
    w, h = src.size
    side = h  # height defines the square crop
    return src.crop((0, 0, side, side))


def main():
    src = Image.open(SRC).convert('RGBA')
    print(f'source: {SRC.name}  {src.size}')

    orb = crop_orb(src)
    print(f'cropped orb: {orb.size}')

    # Save a clean 1024x1024 master for future use (Play Store, etc.).
    master = orb.resize((1024, 1024), Image.LANCZOS)
    master_path = REPO / 'branding' / 'logo-icon-1024.png'
    master.save(master_path, optimize=True)
    print(f'master icon written: {master_path}')

    # Generate per-density launcher icons.
    for folder, size in DENSITIES.items():
        dest_dir = ANDROID_RES / folder
        dest_dir.mkdir(parents=True, exist_ok=True)
        icon = orb.resize((size, size), Image.LANCZOS)
        icon.save(dest_dir / 'ic_launcher.png', optimize=True)
        # Round variant — same pixels, Android masks it to a circle at
        # display time anyway. Keeps both filenames present so the
        # AndroidManifest's `android:roundIcon="@mipmap/ic_launcher_round"`
        # ref resolves on every density.
        icon.save(dest_dir / 'ic_launcher_round.png', optimize=True)
        print(f'  wrote {folder}/ic_launcher.png + _round  ({size}x{size})')


if __name__ == '__main__':
    main()
