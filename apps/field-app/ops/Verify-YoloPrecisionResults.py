"""Check the device's four existing diagnostic cases against the FP16 reference."""
import argparse
import json
from pathlib import Path


def verify(manifest, observations, reference_device=None):
    expected={row['case']: row for row in manifest['parity'] if row['case'].endswith('.jpg')}
    if not manifest['passed'] or len(expected)!=4 or len(observations)!=4 or {r['name'] for r in observations}!=set(expected):
        raise ValueError('Missing or invalid precision observations')
    results=[]
    baseline={r['name']:r['native'] for r in reference_device} if reference_device is not None else None
    if baseline is not None and set(baseline)!=set(expected):
        raise ValueError('Missing same-device FP32 baselines')
    for observation in observations:
        native=observation['native'];case=expected[observation['name']]
        if native['modelSha256']!=manifest['sha256'] or not native['onDevice'] or native['hr']!=0 or native['source']!='diagnostic_asset' or not native['tensorReuse']:
            raise ValueError('Device identity, tensor reuse or result source differs')
        boxes=native['detections'];reference=[d['candidate'] for d in case['detections']]
        if baseline is not None:
            previous=baseline[observation['name']]
            if previous['modelSha256']!=manifest['source_sha256'] or previous['inputSignature']!=native['inputSignature'] or previous['hr']!=0 or previous['source']!='diagnostic_asset':
                raise ValueError('FP32 baseline identity or exact diagnostic input signature differs')
            reference=[dict(class_id=b['classId'],score=b['confidence'],xyxy=b['box']) for b in previous['detections']]
        if len(boxes)!=len(reference):
            raise ValueError('Detection count differs: '+observation['name'])
        errors=[]
        for box,expected_box in zip(boxes,reference):
            score_error=abs(box['confidence']-expected_box['score'])
            position_error=max(abs(a-b) for a,b in zip(box['box'],expected_box['xyxy']))
            if box['classId']!=expected_box['class_id'] or score_error>.01 or position_error>2:
                raise ValueError('Device precision drift exceeds predefined tolerance: '+observation['name'])
            errors.append(dict(confidence_abs_error=score_error,box_max_abs_error=position_error))
        results.append(dict(sample=observation['name'],detections=len(boxes),errors=errors,passed=True))
    if len({r['native']['inputSignature'] for r in observations})!=4 or len({r['runtime_session'] for r in observations})!=1:
        raise ValueError('Input diversity or runtime continuity is missing')
    return dict(passed=True,model_sha256=manifest['sha256'],cases=results,reference='same ARM64 WinML FP32 and identical decoded inputs' if baseline is not None else 'desktop FP16 reference',
                scope='Four built-in diagnostic cases through the real ARM64 WinML component, including changing inputs with reused tensors. Not a real-leaf accuracy test.')


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--manifest',type=Path,required=True);parser.add_argument('--observations',type=Path,required=True);parser.add_argument('--reference-device',type=Path);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    baseline=json.loads(args.reference_device.read_text(encoding='utf-8-sig')) if args.reference_device else None
    try:result=verify(json.loads(args.manifest.read_text(encoding='utf-8-sig')),json.loads(args.observations.read_text(encoding='utf-8-sig')),baseline)
    except ValueError as error:result=dict(passed=False,error=str(error))
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(json.dumps(result,ensure_ascii=False))
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()
