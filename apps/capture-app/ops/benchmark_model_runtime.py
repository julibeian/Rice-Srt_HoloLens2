"""Isolated runtime benchmark of the published V2; never binds or changes a service.
Only memory layout/thread count change within this temporary process.
"""
import hashlib
import json
import os
from pathlib import Path
import signal
import statistics
import sys
import time

signal.alarm(120)
available = int(next(line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines()
                     if line.startswith('MemAvailable:'))) * 1024
if available < 1400 * 1024 * 1024:
    raise SystemExit('Insufficient spare memory for isolated runtime check; no service changed.')
os.environ['RICE_API_ROOT'] = '/opt/rice_disease'
os.environ['RICE_CKPT_PATH'] = '/opt/rice_disease/checkpoints/convnextv2_v2_best.pth'
os.environ['RICE_CLASS_INDICES_PATH'] = '/opt/rice_disease/configs/class_indices_v2.json'
sys.path.insert(0, '/opt/rice_disease')
import torch
from PIL import Image
from api import app_v2 as api

image_path = Path('/var/lib/hololens-capture/evidence/latest-capture.bin')
image_hash = hashlib.sha256(image_path.read_bytes()).hexdigest()
api.load_model()
image = Image.open(image_path).convert('RGB')
tensor = api.INFER_TRANSFORM(image).unsqueeze(0)
rows = []
reference = None
for layout, threads in [('contiguous', 1), ('contiguous', 2), ('channels_last', 1), ('channels_last', 2)]:
    torch.set_num_threads(threads)
    memory_format = torch.channels_last if layout == 'channels_last' else torch.contiguous_format
    api.model.to(memory_format=memory_format)
    candidate = tensor.contiguous(memory_format=memory_format)
    with torch.no_grad():
        logits = api.model(candidate)
        if reference is None:
            reference = logits.clone()
        delta = float((reference - logits).abs().max())
        timings = []
        for _ in range(3):
            start = time.perf_counter()
            actual = api.model(candidate)
            timings.append(round((time.perf_counter() - start) * 1000, 2))
        probs = actual.softmax(dim=1)
        score, index = probs.max(dim=1)
    name = api.class_names[int(index.item())]
    rows.append({'layout': layout, 'threads': threads, 'samples_ms': timings,
                 'median_ms': round(statistics.median(timings), 2), 'max_logit_difference': delta,
                 'predicted_class': name, 'confidence': round(float(score.item()), 4),
                 'same_rounded_result_as_current_api': name == '其他' and round(float(score.item()), 4) == 0.8901,
                 'numerical_tolerance_pass': delta <= 0.00002})
print(json.dumps({'scope': 'Temporary isolated process, same weights/preprocessing/FP32; no production changes or cached inference.',
                  'image_sha256': image_hash, 'results': rows}, ensure_ascii=True))
