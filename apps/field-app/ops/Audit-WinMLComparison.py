"""Audit the four saved alternating trials without connecting to the device.

Latency means use one observation per completed frame counter, not repeated
one-second reads of the same result. GPU engine load does not establish an
unchanged per-process allocation or isolate model GPU execution time.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess

from importlib.util import module_from_spec, spec_from_file_location

SPEC = spec_from_file_location('winml_analysis', Path(__file__).with_name('Analyze-WinMLCause.py'))
ANALYSIS = module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYSIS)

TRIALS = (
    ('ab60-original-1', 'original', '20261106-163135-1.0.0.60'),
    ('ab61-improved-1', 'improved', '20261106-163105-1.0.0.61'),
    ('ab62-original-2', 'original', '20261106-163146-1.0.0.62'),
    ('ab63-improved-2', 'improved', '20261106-163211-1.0.0.63'),
)


def verify_runtime_row(row, evidence):
    state = row['app']['body']
    native = state['nativeDetector']
    if (state.get('version') != evidence['Version'] or
            native.get('modelSha256', '').lower() != evidence['ModelSha256'].lower() or
            native.get('onDevice') is not True or native.get('modelLoaded') is not True or
            native.get('inputSize') != 320 or state.get('cameraPreviewReady') is not True):
        raise ValueError('Observed runtime does not match the stored package and live camera')


def compare(summaries):
    if len(summaries) != 4 or tuple(s['run_id'] for s in summaries) != tuple(t[0] for t in TRIALS):
        raise ValueError('The four alternating trials are required in their actual order')
    for summary in summaries:
        if summary['status'] != 'recorded' or summary['errors'] or summary['samples'] != 120:
            raise ValueError('Incomplete or invalid trial: ' + summary['run_id'])
        if summary['fresh_results'] < 2 or summary['frame_delta'] <= 0 or summary['seconds'] < 118:
            raise ValueError('Insufficient fresh results or time: ' + summary['run_id'])
        if summary['input_source_dimensions'] != [(896, 504)]:
            raise ValueError('Camera input dimensions changed')
    arms = {}
    for arm in ('original', 'improved'):
        selected = [s for s, trial in zip(summaries, TRIALS) if trial[1] == arm]
        arms[arm] = dict(
            observed_latency_mean_ms=statistics.mean(s['inference_mean_ms'] for s in selected),
            observed_unique_results=sum(s['fresh_results'] for s in selected),
            completed_frame_delta=sum(s['frame_delta'] for s in selected),
            observation_seconds=sum(s['seconds'] for s in selected),
        )
        arms[arm]['completed_per_second'] = arms[arm]['completed_frame_delta'] / arms[arm]['observation_seconds']
    return dict(
        arms=arms,
        observed_latency_reduction_percent=100*(1-arms['improved']['observed_latency_mean_ms']/arms['original']['observed_latency_mean_ms']),
        completed_rate_increase_percent=100*(arms['improved']['completed_per_second']/arms['original']['completed_per_second']-1),
        latency_scope='Equal-weight round means of unique observed completed results; not an every-frame latency trace.',
        allocation_scope='Per-process GPU allocation was not measured in these four trials. Equal engine utilization cannot establish equal allocation.',
    )


def main():
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);args=parser.parse_args()
    workspace=Path(__file__).resolve().parents[3]
    summaries=[ANALYSIS.summarize(args.root/'raw'/name) for name,arm,package in TRIALS]
    result=compare(summaries)
    files=[];provenance=[]
    original_commit=subprocess.check_output(['git','rev-parse','58cbb90'],cwd=workspace,text=True).strip()
    for name,arm,package_id in TRIALS:
        directory=workspace/'apps/field-app/.state/packages'/package_id
        evidence=json.loads((directory/'package-evidence.json').read_text(encoding='utf-8-sig'))
        layout=Path(evidence['Layout'])
        package_sha=hashlib.sha256(Path(evidence['Package']).read_bytes()).hexdigest()
        if package_sha.lower()!=evidence['Sha256'].lower():raise ValueError('APPX hash mismatch: '+name)
        files.append(dict(trial=name,file=Path(evidence['Package']).name,sha256=package_sha))
        for script in evidence['ScriptFiles']:
            actual=hashlib.sha256((layout/script['Deployed']).read_bytes()).hexdigest()
            if actual.lower()!=script['Sha256'].lower():raise ValueError('Packaged script mismatch: '+name)
            files.append(dict(trial=name,file=script['Deployed'],sha256=actual))
        for filename,expected in [('model.onnx',evidence['ModelSha256']),('Rice.HoloLens.Yolo.dll',evidence['NativeDllSha256'])]:
            actual=hashlib.sha256((layout/filename).read_bytes()).hexdigest()
            if actual.lower()!=expected.lower():raise ValueError('Package file mismatch: '+name+'/'+filename)
            files.append(dict(trial=name,file=filename,sha256=actual))
        if arm=='original':
            for filename in ('app.js','native.js'):
                reference=subprocess.check_output(['git','show',original_commit+':apps/field-app/src/'+filename],cwd=workspace)
                actual=(layout/filename).read_bytes()
                same=actual.replace(b'\r\n',b'\n')==reference.replace(b'\r\n',b'\n')
                provenance.append(dict(trial=name,file=filename,source_commit=original_commit,newlines_normalized_match=same))
                if not same:raise ValueError('Original JS source does not match pinned baseline commit')
        raw=args.root/'raw'/name/'round-01.jsonl'
        for row in ANALYSIS.read_jsonl(raw):
            if row['measurement']:verify_runtime_row(row,evidence)
        files.append(dict(trial=name,file='round-01.jsonl',sha256=hashlib.sha256(raw.read_bytes()).hexdigest()))
    result.update(schema=1,trials=summaries,package_files=files,original_source_provenance=provenance,
                  original_source_commit=original_commit,passed=True)
    (args.root/'comparison-audit.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('passed','observed_latency_reduction_percent','completed_rate_increase_percent','arms')},ensure_ascii=False))


if __name__=='__main__':main()
