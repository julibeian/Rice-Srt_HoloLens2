#!/usr/bin/env python3
"""Mount the dynamic frame module into the existing V2 API, once.

The patch is additive and marker-checked. It does not touch model loading,
weights, static /predict or the relay bypass added by patch_upstream.py.
"""
import argparse
import ast
from pathlib import Path

MARKER = "# Rice HoloLens dynamic recognition: versioned frame channel"
MOUNT = (
    "# Rice HoloLens dynamic recognition: versioned frame channel\n"
    "from api.dynamic import install_dynamic as _install_rice_dynamic\n"
    "_install_rice_dynamic(app, globals())\n"
)


def patch(source):
    ast.parse(source)
    if MARKER in source:
        if source.count(MOUNT) != 1 or "app = FastAPI(" not in source:
            raise ValueError("Partially changed dynamic mount; manual inspection required")
        return source
    if "install_dynamic" in source or "_install_rice_dynamic" in source:
        raise ValueError("Dynamic mount exists without its guarded marker")
    if source.count("app = FastAPI(") != 1:
        raise ValueError("Expected exactly one FastAPI application")
    main_block = 'if __name__ == "__main__":'
    if source.count(main_block) == 1:
        source = source.replace(main_block, MOUNT + "\n" + main_block, 1)
    else:
        source = source.rstrip("\n") + "\n\n" + MOUNT
    ast.parse(source)
    if source.count(MARKER) != 1:
        raise ValueError("Dynamic mount marker was not written exactly once")
    return source


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    path = Path(args.source)
    old = path.read_text(encoding="utf-8")
    new = patch(old)
    if args.apply and new != old:
        path.write_text(new, encoding="utf-8")
    print("dynamic_mount_ready" if new != old else "dynamic_mount_already_present")
