"""Compare the compiled production C preprocessing/NMS to a Python reference."""
import argparse
import ctypes as C
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'reports/20261101-dynamic-model-analysis'))
import inspect_model as ref


class Box(C.Structure):
    _fields_ = [('x1', C.c_float), ('y1', C.c_float), ('x2', C.c_float), ('y2', C.c_float), ('score', C.c_float), ('class_id', C.c_int)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--size', type=int, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    dll = C.CDLL(str(args.dll.resolve()))
    floats = C.POINTER(C.c_float)
    dll.YoloLetterbox.argtypes = [C.POINTER(C.c_ubyte), C.c_int, C.c_int, floats]
    dll.YoloDecode.argtypes = [floats, C.c_int, C.c_int, C.POINTER(Box)]
    dll.YoloDecode.restype = C.c_int
    options = ref.ort.SessionOptions(); options.intra_op_num_threads = 1
    session = ref.ort.InferenceSession(str(args.model), sess_options=options, providers=['CPUExecutionProvider'])
    labels = ref.ast.literal_eval(session.get_modelmeta().custom_metadata_map['names'])
    results = []
    for image in sorted(Path('E:/微信小程序开发软件/srt-rice/手机端可跑版/samples').glob('*.jpg')):
        rgb = ref.np.asarray(ref.Image.open(image).convert('RGB'))
        expected, geom = ref.letterbox(rgb, pad_value=114, size=args.size)
        rgba = ref.np.concatenate([rgb, ref.np.full((*rgb.shape[:2], 1), 255, dtype=ref.np.uint8)], axis=2)
        actual = ref.np.empty_like(expected)
        dll.YoloLetterbox(rgba.ctypes.data_as(C.POINTER(C.c_ubyte)), geom['width'], geom['height'], actual.ctypes.data_as(floats))
        error = float(ref.np.abs(actual - expected).max())
        if error > 1e-7:
            raise ValueError('Native preprocessing mismatch: ' + str(error))
        raw = session.run(None, {'images': actual})[0]
        target = ref.postprocess(raw, geom, labels)
        boxes = (Box * 100)()
        count = dll.YoloDecode(raw.ctypes.data_as(floats), geom['width'], geom['height'], boxes)
        if count != len(target):
            raise ValueError('Native detection count mismatch')
        for i, record in enumerate(target):
            box = boxes[i]
            if box.class_id != record['class_id'] or abs(box.score - record['score']) > 1e-6:
                raise ValueError('Native class or confidence mismatch')
            if max(abs(a - b) for a, b in zip([box.x1, box.y1, box.x2, box.y2], record['xyxy'])) > .011:
                raise ValueError('Native box geometry mismatch')
        results.append({'sample': image.name, 'input_max_abs_error': error, 'native_nms_matches': True, 'detections': count})
    value = {'input_size': args.size, 'compiled_production_header': 'apps/field-app/yolo-native/YoloCore.h', 'cases': results, 'passed': True}
    args.out.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(value, ensure_ascii=False))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()
