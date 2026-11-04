"""Adapt the released YOLO ONNX to the legacy HoloLens WinML operator contract.

Preserves learned weights and fixed 640 input; no training or quantization.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'apps/field-app/.state/model-analysis-20261101/deps'))
import numpy as np
import onnx
import onnxruntime as ort
from onnx import helper, numpy_helper

SOURCE_SHA = 'bc1312d93eccd295b3e1a10070e9e7673d5715c3e3789b33b06a48f8b22dde98'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=ROOT / 'apps/field-app/.state/onnx-probe/layout/model.onnx')
    parser.add_argument('--output', type=Path, default=ROOT / 'apps/field-app/.state/yolo/model.onnx')
    parser.add_argument('--size', type=int, choices=[320, 416, 640], default=640)
    args = parser.parse_args()
    args.source = args.source.resolve()
    args.output = args.output.resolve()
    if hashlib.sha256(args.source.read_bytes()).hexdigest() != SOURCE_SHA:
        raise ValueError('Unexpected source model hash')
    model = onnx.load(str(args.source))
    source_weights = {v.name: v.SerializeToString() for v in model.graph.initializer if v.data_type == onnx.TensorProto.FLOAT}
    original_metadata = {v.key: v.value for v in model.metadata_props}
    if model.graph.input[0].name != 'images' or model.graph.output[0].name != 'output0':
        raise ValueError('Unexpected model contract')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    modern_reference = args.source
    spatial_changes = []
    if args.size != 640:
        anchors = sum((args.size // s) ** 2 for s in [8, 16, 32])
        grid, strides = [], []
        for stride in [8, 16, 32]:
            side = args.size // stride
            yy, xx = np.meshgrid(np.arange(side, dtype=np.float32) + .5, np.arange(side, dtype=np.float32) + .5, indexing='ij')
            grid.append(np.stack([xx, yy], axis=0).reshape(2, -1))
            strides.append(np.full((1, side * side), stride, dtype=np.float32))
        grid = np.concatenate(grid, axis=1)[None]
        stride_grid = np.concatenate(strides, axis=1)
        for node in model.graph.node:
            if node.op_type != 'Constant':
                continue
            for attribute in node.attribute:
                if attribute.name != 'value':
                    continue
                value = numpy_helper.to_array(attribute.t)
                replacement = None
                if value.shape == (1, 2, 8400):
                    replacement = grid
                elif value.shape == (1, 8400):
                    replacement = stride_grid
                elif value.dtype == np.int64 and (value == 8400).any():
                    replacement = np.where(value == 8400, anchors, value)
                if replacement is not None:
                    attribute.t.CopyFrom(numpy_helper.from_array(replacement))
                    spatial_changes.append(node.name)
        if len(spatial_changes) != 5:
            raise ValueError('Unrecognized YOLO spatial constants: ' + repr(spatial_changes))
        model.graph.input[0].type.tensor_type.shape.dim[2].dim_value = args.size
        model.graph.input[0].type.tensor_type.shape.dim[3].dim_value = args.size
        model.graph.output[0].type.tensor_type.shape.dim[2].dim_value = anchors
        del model.graph.value_info[:]
        onnx.checker.check_model(model, full_check=True)
        modern_reference = args.output.with_name('reference-opset19.onnx')
        onnx.save(model, str(modern_reference))
    inferred = onnx.shape_inference.infer_shapes(model)
    shapes = {v.name: [d.dim_value for d in v.type.tensor_type.shape.dim] for v in
              list(inferred.graph.value_info) + list(inferred.graph.input) + list(inferred.graph.output)}
    constants = {i.name: numpy_helper.to_array(i) for i in model.graph.initializer}
    for node in model.graph.node:
        if node.op_type == 'Constant':
            values = [helper.get_attribute_value(a) for a in node.attribute if a.name == 'value']
            if values:
                constants[node.output[0]] = numpy_helper.to_array(values[0])
    nodes, rewrites = [], []
    for node in model.graph.node:
        if node.op_type == 'Reshape':
            for attribute in list(node.attribute):
                if attribute.name == 'allowzero':
                    if helper.get_attribute_value(attribute) != 0:
                        raise ValueError('Cannot preserve allowzero=1 with legacy Reshape')
                    node.attribute.remove(attribute)
                    rewrites.append({'node': node.name, 'change': 'Remove allowzero=0, identical to legacy Reshape semantics'})
        if node.op_type == 'Resize' and len(node.input) > 1 and not node.input[1]:
            roi = node.name + '/legacy12_empty_roi'
            model.graph.initializer.append(numpy_helper.from_array(np.asarray([], dtype=np.float32), roi))
            node.input[1] = roi
            rewrites.append({'node': node.name, 'change': 'Provide required empty ROI tensor for opset12 Resize'})
        if node.op_type == 'Split' and len(node.input) == 2:
            split = constants[node.input[1]].astype(int).tolist()
            del node.input[1:]
            node.attribute.append(helper.make_attribute('split', split))
            rewrites.append({'node': node.name, 'change': 'Split constant input to opset12 split attribute', 'split': split})
        if node.op_type == 'Softmax':
            axis = next((int(helper.get_attribute_value(a)) for a in node.attribute if a.name == 'axis'), -1)
            shape = shapes[node.input[0]]
            if not shape or not all(shape):
                raise ValueError('Softmax rewrite requires verified static shape')
            axis %= len(shape)
            perm = [i for i in range(len(shape)) if i != axis] + [axis]
            inv = [perm.index(i) for i in range(len(shape))]
            transposed = [shape[i] for i in perm]
            prefix = node.name + '/legacy12'
            matrix_shape = prefix + '/matrix_shape'
            restored_shape = prefix + '/restored_shape'
            model.graph.initializer.extend([
                numpy_helper.from_array(np.asarray([-1, shape[axis]], dtype=np.int64), matrix_shape),
                numpy_helper.from_array(np.asarray(transposed, dtype=np.int64), restored_shape)])
            nodes.extend([
                helper.make_node('Transpose', [node.input[0]], [prefix + '/t'], perm=perm, name=prefix + '/transpose'),
                helper.make_node('Reshape', [prefix + '/t', matrix_shape], [prefix + '/m'], name=prefix + '/flatten'),
                helper.make_node('Softmax', [prefix + '/m'], [prefix + '/s'], axis=1, name=prefix + '/softmax'),
                helper.make_node('Reshape', [prefix + '/s', restored_shape], [prefix + '/r'], name=prefix + '/restore'),
                helper.make_node('Transpose', [prefix + '/r'], list(node.output), perm=inv, name=prefix + '/inverse')])
            rewrites.append({'node': node.name, 'change': 'Preserve axis-only Softmax with rank2 legacy semantics', 'shape': shape, 'axis': axis})
            continue
        nodes.append(node)
    del model.graph.node[:]
    model.graph.node.extend(nodes)
    model.opset_import[0].version = 12
    model.ir_version = 7
    for item in model.metadata_props:
        if item.key == 'args':
            item.value = "{'batch':1,'half':False,'dynamic':False,'opset':12,'nms':False}"
        if item.key == 'imgsz':
            item.value = str([args.size, args.size])
    model.metadata_props.extend([helper.make_string_string_pair('source_sha256', SOURCE_SHA)] if hasattr(helper, 'make_string_string_pair') else [])
    entry = model.metadata_props.add(); entry.key = 'adaptation'; entry.value = 'HoloLens legacy WinML opset12; unchanged learned weights'
    onnx.checker.check_model(model, full_check=True)
    final_weights = {v.name: v.SerializeToString() for v in model.graph.initializer if v.name in source_weights}
    if source_weights != final_weights:
        raise ValueError('Learned weight tensor bytes changed')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, str(args.output))
    options = ort.SessionOptions(); options.intra_op_num_threads = 1; options.log_severity_level = 3
    sessions = [ort.InferenceSession(str(p), sess_options=options, providers=['CPUExecutionProvider']) for p in [modern_reference, args.output]]
    rng = np.random.default_rng(20261101)
    cases = [('zeros', np.zeros((1, 3, args.size, args.size), dtype=np.float32)),
             ('random', rng.random((1, 3, args.size, args.size), dtype=np.float32))]
    sys.path.insert(0, str(ROOT / 'reports/20261101-dynamic-model-analysis'))
    from inspect_model import letterbox
    from PIL import Image
    for p in sorted(Path('E:/微信小程序开发软件/srt-rice/手机端可跑版/samples').glob('*.jpg')):
        cases.append((p.name, letterbox(np.asarray(Image.open(p).convert('RGB')), size=args.size)[0]))
    parity = []
    for name, value in cases:
        a, b = [s.run(None, {'images': value})[0] for s in sessions]
        record = {'case': name, 'shape': list(b.shape), 'max_abs_error': float(np.abs(a - b).max()),
                  'mean_abs_error': float(np.abs(a - b).mean()), 'allclose': bool(np.allclose(a, b, rtol=1e-5, atol=1e-4))}
        parity.append(record)
        if not record['allclose']:
            raise ValueError('Model output changed: ' + json.dumps(record))
    proof = {'source_sha256': SOURCE_SHA, 'sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(),
             'path': str(args.output), 'bytes': args.output.stat().st_size, 'opset': 12, 'ir_version': 7, 'input_size': args.size,
             'spatial_changes': spatial_changes, 'parity_reference': str(modern_reference),
             'source_float_weight_tensors_sha256': hashlib.sha256(b''.join(source_weights[k] for k in sorted(source_weights))).hexdigest(),
             'rewrites': rewrites, 'parity': parity, 'names': original_metadata['names'],
             'trained': False, 'weights_changed': False, 'quantized': False}
    args.output.with_name('model-manifest.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(proof, ensure_ascii=False))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()
