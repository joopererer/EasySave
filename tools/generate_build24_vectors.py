"""Generate synthetic container vectors without site/account data (Pillow)."""
from pathlib import Path
from PIL import Image

root = Path('app/test/fixtures/build24')
root.mkdir(parents=True, exist_ok=True)
image = Image.new('RGB', (80, 120), (208, 64, 96))
for extension in ['jpeg', 'png', 'webp']:
    image.save(root / f'portrait.{extension}', format=extension.upper())
