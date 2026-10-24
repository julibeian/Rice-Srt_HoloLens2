"""Read capture artifacts and record exposure metrics without changing images."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("verification", type=Path)
args = parser.parse_args()
verification = json.loads(args.verification.read_text(encoding="utf-8-sig"))
rows = []
for item in verification["Files"]:
    path = Path(item["Path"])
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != item["Sha256"]:
        raise SystemExit("Capture file no longer matches its verified SHA256")
    with Image.open(path) as image:
        image.load()
        rgb = np.asarray(image.convert("RGB"), dtype=np.float32)
        luminance = rgb @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
        rows.append(
            {
                "kind": item["Kind"],
                "sha256": digest,
                "width": image.width,
                "height": image.height,
                "luminance_mean": round(float(luminance.mean()), 3),
                "luminance_p05": round(float(np.percentile(luminance, 5)), 3),
                "luminance_p95": round(float(np.percentile(luminance, 95)), 3),
                "highlight_fraction_ge_250": round(float((luminance >= 250).mean()), 6),
                "shadow_fraction_le_5": round(float((luminance <= 5).mean()), 6),
            }
        )
crop = next(row for row in rows if row["kind"] == "crop")
if (crop["width"], crop["height"]) != (
    verification["CropWidth"], verification["CropHeight"]
):
    raise SystemExit("Decoded crop dimensions differ from capture metadata")
result = {
    "version": verification["Version"],
    "request_id": verification["RequestId"],
    "files": rows,
    "scope": "Measured pixels of this scene; no leaf accuracy or other lighting conditions are inferred.",
}
out = args.verification.with_name("image-quality.json")
out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(result, ensure_ascii=False, indent=2))
