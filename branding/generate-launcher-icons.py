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

    # Generate per-density launcher icons by resizing the full square logo.
    for folder, size in DENSITIES.items():
        dest_dir = ANDROID_RES / folder
        dest_dir.mkdir(parents=True, exist_ok=True)
        icon = src.resize((size, size), Image.LANCZOS)
        icon.save(dest_dir / 'ic_launcher.png', optimize=True)
        # Round variant — same pixels. Android masks it to a circle at
        # display time. Keeps both filenames present so the
        # AndroidManifest's `android:roundIcon="@mipmap/ic_launcher_round"`
        # ref resolves on every density.
        icon.save(dest_dir / 'ic_launcher_round.png', optimize=True)
        print(f'  wrote {folder}/ic_launcher.png + _round  ({size}x{size})')


if __name__ == '__main__':
    main()
