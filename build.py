#!/usr/bin/env python3
"""Package src/ into build/roku_streambar.c4z (unencrypted dev build)."""
import pathlib, zipfile

root = pathlib.Path(__file__).resolve().parent
src = root / "src"
out = root / "build" / "roku_streambar.c4z"
out.parent.mkdir(exist_ok=True)

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(src.rglob("*")):
        if f.is_file():
            z.write(f, f.relative_to(src).as_posix())
print(f"wrote {out}")
