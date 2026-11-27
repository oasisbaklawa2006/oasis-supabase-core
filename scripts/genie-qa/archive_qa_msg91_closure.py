#!/usr/bin/env python3
"""Archive only independently attested regular local source files + QA config."""
import json
import sys
import tarfile
from pathlib import Path, PurePosixPath
def archive(root, manifest, output):
    root = Path(root).resolve(strict=True)
    files = json.loads(Path(manifest).read_text())["files"]
    paths = ["supabase/config.toml"]
    for entry in files:
        p = PurePosixPath(entry["path"])
        if p.is_absolute() or ".." in p.parts or not p.parts:
            raise ValueError("invalid closure path")
        paths.append("supabase/functions/" + p.as_posix())
    if len(paths) != len(set(paths)):
        raise ValueError("duplicate archive path")
    config = root / paths[0]
    if config.read_text() != 'project_id = "skhpmltfjgqitntkmclb"\n':
        raise ValueError("not QA config")
    with tarfile.open(output, "x:gz") as out:
        for name in sorted(paths):
            p = root / name
            if not p.is_file() or p.is_symlink() or p.resolve() != p:
                raise ValueError("nonregular source")
            out.add(p, arcname=name, recursive=False)
if __name__ == "__main__":
    try:
        archive(*sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError):
        print("QA_ROLLBACK_ARCHIVE_DENIED", file=sys.stderr)
        sys.exit(1)
