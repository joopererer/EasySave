"""Download published parser bytes through gh without text re-encoding."""
from pathlib import Path
import subprocess
import sys

version = sys.argv[1]
root = Path(__file__).resolve().parents[1]
evidence = root / 'app' / 'build' / ('v' + version.replace('.', ''))
release = evidence / ('release' + version.replace('.', ''))
release.mkdir(parents=True, exist_ok=True)
subprocess.run(['gh', 'release', 'download', 'parser-v' + version,
                '--repo', 'joopererer/EasySave', '--pattern', 'manifest.json',
                '--pattern', 'parser.js', '--dir', str(release)], check=True)
channel = subprocess.run(['gh', 'api',
    'repos/joopererer/EasySave/contents/spec/v2/manifest.json?ref=master',
    '-H', 'Accept: application/vnd.github.raw+json'], stdout=subprocess.PIPE, check=True).stdout
(evidence / 'master-manifest.json').write_bytes(channel)
print(f'Release bytes: {release}')
print(f'Channel bytes: {len(channel)}')
