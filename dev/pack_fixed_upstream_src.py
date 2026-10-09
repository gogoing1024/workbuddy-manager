"""Regenerate the wb2api source asset with the reviewed manager patches."""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

if __package__:
    from .apply_upstream_patches import apply_patches
else:
    from apply_upstream_patches import apply_patches


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('-o', '--out', type=Path, default=Path('.'))
    parser.add_argument('--stamp', default='Fix tool-result notices and request-level 11148 handling')
    args = parser.parse_args()
    source = args.source.resolve()
    packer = Path(__file__).with_name('pack_upstream_src.py')
    if not packer.is_file():
        parser.exit(1, 'Run this from a manager checkout containing dev/pack_upstream_src.py.\n')

    def ignore(directory: str, names: list[str]) -> set[str]:
        omitted = {'.git', '__pycache__', 'node_modules'}
        if Path(directory).resolve() == source:
            omitted |= {'config.json', 'auths', 'data'}
        return set(names) & omitted

    try:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / 'workbuddy2api'
            shutil.copytree(source, work, ignore=ignore)
            for result in apply_patches(work, Path(__file__).parent / 'upstream-patches'):
                print(result, flush=True)
            return subprocess.run([
                sys.executable, str(packer), str(work), '-o', str(args.out.resolve()),
                '--stamp', args.stamp,
            ]).returncode
    except (ValueError, RuntimeError, OSError) as exc:
        parser.exit(1, f'{exc}\n')


if __name__ == '__main__':
    raise SystemExit(main())
