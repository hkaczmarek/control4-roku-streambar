#!/usr/bin/env python3
"""Package src/ into build/roku_streambar.c4z (unencrypted dev build) and copy it to release/."""
import pathlib, shutil, zipfile

root = pathlib.Path(__file__).resolve().parent
src = root / "src"
out = root / "build" / "roku_streambar.c4z"
out.parent.mkdir(exist_ok=True)

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(src.rglob("*")):
        if f.is_file():
            z.write(f, f.relative_to(src).as_posix())
print(f"wrote {out}")

# tracked copy for the repo
rel = root / "release" / out.name
rel.parent.mkdir(exist_ok=True)
shutil.copy2(out, rel)
print(f"copied to {rel}")
