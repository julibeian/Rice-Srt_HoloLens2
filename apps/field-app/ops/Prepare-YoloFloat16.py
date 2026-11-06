"""Create an isolated FP16 candidate; retain FP32 IO and audit numerical drift.

No training; never overwrite the original model. This tests a precision change,
not accuracy on real leaves. Requires the explicitly installed experiment deps.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'apps/field-app/.state/winml-experiment-deps'))
import numpy as np
import onnx
import onnxruntime as ort
from onnxconverter_common import float16
from PIL import Image
sys.path.insert(0, str(ROOT / 'reports/20261101-dynamic-model-analysis'))
from inspect_model import letterbox, postprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    original = ROOT / 'apps/field-app/.state/yolo-320/model.onnx'
    original_sha = hashlib.sha256(original.read_bytes()).hexdigest()
    if original_sha != 'e6b6d2f6baaae3b7970f1a4e425f2c2347a90fe6aab34c3da0aed738fcf1b048':
        raise ValueError('Unexpected source model')
    if args.output.resolve() == original.resolve() or args.output.exists():
        raise ValueError('Use a new candidate path')
    model = onnx.load(original)
    converted = float16.convert_float_to_float16(model, keep_io_types=True)
    converted.ir_version = 7
    onnx.checker.check_model(converted, full_check=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(converted, args.output)
    options = ort.SessionOptions(); options.intra_op_num_threads = 1
    sessions = [ort.InferenceSession(str(p), options, providers=['CPUExecutionProvider']) for p in (original, args.output)]
    labels = ast.literal_eval(sessions[0].get_modelmeta().custom_metadata_map['names'])
    rng = np.random.default_rng(20261106)
    cases = [('zeros', np.zeros((1, 3, 320, 320), np.float32), None),
             ('random', rng.random((1, 3, 320, 320), dtype=np.float32), None)]
    for path in sorted(Path('E:/微信小程序开发软件/srt-rice/手机端可跑版/samples').glob('*.jpg')):
        value, geometry = letterbox(np.asarray(Image.open(path).convert('RGB')), size=320)
        cases.append((path.name, value, geometry))
    if len(cases) != 6:
        raise ValueError('Expected four diagnostic sample images plus two tensor cases')
    parity = []
    for name, value, geometry in cases:
        a, b = [s.run(None, {'images': value})[0] for s in sessions]
        difference = np.abs(a-b)
        confidence_error = float(difference[:, 4:].max())
        relevant = np.max(a[:, 4:], axis=1)[0] >= .1
        coordinate_error = float(difference[:, :4, relevant].max()) if relevant.any() else 0.
        passed = bool(np.isfinite(b).all() and confidence_error <= .01 and coordinate_error <= 2.)
        detection_comparison = []
        if geometry:
            original_boxes, candidate_boxes = [postprocess(raw, geometry, labels) for raw in (a, b)]
            passed = passed and len(original_boxes) == len(candidate_boxes)
            for old, new in zip(original_boxes, candidate_boxes):
                box_error = max(abs(x-y) for x,y in zip(old['xyxy'],new['xyxy']))
                match = old['class_id'] == new['class_id'] and abs(old['score']-new['score']) <= .01 and box_error <= 2.
                passed = passed and match
                detection_comparison.append(dict(original=old,candidate=new,box_error=box_error,passed=match))
        parity.append(dict(case=name, confidence_max_abs_error=confidence_error,
                           relevant_coordinate_max_abs_error=coordinate_error,
                           full_output_max_abs_error=float(difference.max()), detections=detection_comparison, allclose=bool(passed)))
    record = dict(path=str(args.output.resolve()),sha256=hashlib.sha256(args.output.read_bytes()).hexdigest(),
                  source_sha256=original_sha, input_size=320,opset=12,ir_version=7,
                  precision='FP16 internal; FP32 IO',trained=False,weights_changed=True,quantized=False,
                  validation='Confidence error <=0.01; coordinates for original score>=0.1 <=2px; same diagnostic detection classes/counts, confidence <=0.01 and boxes <=2px. Not real-leaf accuracy.',
                  parity=parity, passed=all(row['allclose'] for row in parity),
                  versions=dict(onnx=onnx.__version__,onnxruntime=ort.__version__))
    args.output.with_name('model-manifest.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(record,ensure_ascii=False))
    if not record['passed']:
        raise ValueError('Candidate numerical gate failed; do not deploy')


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()
