"""Recompute the live WinML controls without connecting to or changing a device."""
import argparse
import csv
from datetime import datetime, timedelta
import json
from pathlib import Path
import statistics as stat


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text(encoding='utf-8-sig').splitlines() if line.strip()]


def avg(values):
    values = [v for v in values if v is not None]
    return stat.mean(values) if values else None


def summarize(folder):
    run = json.loads((folder / 'run.json').read_text(encoding='utf-8-sig'))
    rows = [r for p in sorted(folder.glob('round-*.jsonl')) for r in read_jsonl(p) if r['measurement']]
    if not rows:
        return dict(run_id=run['run_id'], status=run['status'], samples=0)
    native = [r['app']['body']['nativeDetector'] for r in rows]
    latest = {n['cameraFrames']: n for n in native}
    ordered = list(latest.values())
    seconds = (datetime.fromisoformat(rows[-1]['at'])-datetime.fromisoformat(rows[0]['at'])).total_seconds()
    errors = []
    for r, n in zip(rows, native):
        if r['app']['status'] != 200 or r['systemperf']['status'] != 200:
            errors.append('required_endpoint_failed')
        if n['source'] != 'camera' or n['assetFrames'] != 0 or n['hr'] != 0 or n['phase'] != 'running':
            errors.append('not_continuous_camera')
        if n['modelSha256'] != run['expected_model_sha256'] or n['processId'] != run['process_id'] or r['app']['body']['runtimeSession'] != run['runtime_session']:
            errors.append('identity_changed')
    if any(b['cameraFrames'] < a['cameraFrames'] for a,b in zip(native,native[1:])):
        errors.append('counter_reset')
    preview = [r['app']['body'].get('cameraTelemetry') for r in rows]
    preview = [p for p in preview if p]
    result = dict(run_id=run['run_id'],status=run['status'],samples=len(rows),
                  first_at=rows[0]['at'],last_at=rows[-1]['at'],seconds=seconds,
                  runtime_session=run['runtime_session'],process_id=run['process_id'],
                  model_sha256=run['expected_model_sha256'],
                  camera_keys=sorted({p['key'] for p in preview}),
                  fresh_results=len(latest),frame_delta=native[-1]['cameraFrames']-native[0]['cameraFrames'],
                  detections_per_second=(native[-1]['cameraFrames']-native[0]['cameraFrames'])/seconds if seconds else None,
                  inference_mean_ms=avg([n['inferenceMs'] for n in ordered]),
                  inference_median_ms=stat.median(n['inferenceMs'] for n in ordered),
                  inference_min_ms=min(n['inferenceMs'] for n in ordered),inference_max_ms=max(n['inferenceMs'] for n in ordered),
                  preprocess_mean_ms=avg([n['preprocessMs'] for n in ordered]),
                  binding_mean_ms=avg([n.get('bindingMs') for n in ordered]),
                  output_mean_ms=avg([n.get('outputMs') for n in ordered]),
                  cpu_mean=avg([r['systemperf']['body']['CpuLoad'] for r in rows]),
                  gpu0_mean=avg([r['systemperf']['body']['GPUData']['AvailableAdapters'][0]['EnginesUtilization'][0] for r in rows]),
                  distinct_input_signatures=len({n['inputSignature'] for n in ordered}),
                  input_source_dimensions=sorted({(n['sourceWidth'],n['sourceHeight']) for n in native}),
                  thermal_stages=sorted({r['health']['thermal']['body']['CurrentStage'] for r in rows}),
                  low_power_states=sorted({r['health']['power']['body']['LowPowerState'] for r in rows}),
                  errors=sorted(set(errors)))
    if len(preview) > 1 and preview[0].get('decodedFrames') is not None:
        result['preview_presented_fps'] = ((preview[-1]['decodedFrames']-(preview[-1].get('droppedFrames') or 0))-(preview[0]['decodedFrames']-(preview[0].get('droppedFrames') or 0)))/seconds if seconds else None
    return result


def process_shares(root, summaries):
    directory = root/'hardware/gpu-contention-cycle'
    if not (directory/'samples.jsonl').exists():
        return []
    invocation = json.loads((directory/'invocation.json').read_text(encoding='utf-8-sig'))
    samples = read_jsonl(directory/'samples.jsonl')
    # The worker starts after invocation; retain a 5s margin at either boundary.
    # Ratios use identically scaled raw counters; no undocumented time unit is assumed.
    began = datetime.fromisoformat(invocation['At'])
    first_tick = samples[0]['tickMs']
    result=[]
    for summary in summaries:
        if not summary['run_id'].startswith('gpu-contention-'):
            continue
        first,last=[datetime.fromisoformat(summary[k]) for k in ('first_at','last_at')]
        selected=[s for s in samples if first+timedelta(seconds=5) <= began+timedelta(milliseconds=s['tickMs']-first_tick) <= last-timedelta(seconds=5)]
        if len(selected)<10:
            raise ValueError('Insufficient interior hardware samples')
        a,b=selected[0],selected[-1]
        def own(s):
            return next(p for p in s['processes'] if p['pid']==summary['process_id'] and p['status']==0)['runningTimeRaw']
        global_delta=b['adapters'][0]['globalRunningTimeRaw']-a['adapters'][0]['globalRunningTimeRaw']
        own_delta=own(b)-own(a)
        share=own_delta/global_delta
        result.append(dict(run_id=summary['run_id'],hardware_samples=len(selected),
                           app_share_of_gpu_busy=share,
                           approximate_app_busy_percent=summary['gpu0_mean']*share,
                           approximate_other_busy_percent=summary['gpu0_mean']*(1-share),
                           frequencies_hz=sorted({s['adapters'][0]['frequencyHz'] for s in selected}),
                           global_delta_raw=global_delta,app_delta_raw=own_delta,
                           caveat='Phase alignment uses launch time with 5s interior margins. Percentages combine phase-average systemperf with process counter share. DWM access denied; other GPU work is not assigned to a named process.'))
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);args=parser.parse_args()
    summaries=[summarize(p.parent) for p in sorted((args.root/'raw').glob('*/run.json'))]
    result=dict(schema=1, runs=summaries, process_gpu_comparison=process_shares(args.root,summaries),
                interpretation='Unique latest-result samples, not every-frame latency logs. Completed-frame rates use first/last counters and PC observation time. No historical causal attribution beyond the tested controls.')
    (args.root/'analysis.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    keys=['run_id','status','samples','seconds','frame_delta','detections_per_second','inference_mean_ms','inference_median_ms','binding_mean_ms','output_mean_ms','cpu_mean','gpu0_mean','preview_presented_fps','distinct_input_signatures']
    with (args.root/'comparison.csv').open('w',encoding='utf-8-sig',newline='') as output:
        writer=csv.DictWriter(output,fieldnames=keys,extrasaction='ignore');writer.writeheader();writer.writerows(summaries)
    print(json.dumps(dict(runs=len(summaries),process_gpu_comparison=result['process_gpu_comparison'],errors={r['run_id']:r.get('errors',[]) for r in summaries if r.get('errors')}),ensure_ascii=False))


if __name__=='__main__':
    main()
