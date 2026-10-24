"""Verify fixed inputs, product metadata and the published experimental scope."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, help='Optionally verify a downloaded AppX.')
    args = parser.parse_args()
    inputs = ROOT / 'field-app/upstream-miniprogram'
    source = read(inputs / 'SOURCE.json')
    for item in source['files']:
        path = (inputs / item['path']).resolve()
        require(path.is_relative_to(inputs), 'Input path leaves the shared snapshot.')
        data = path.read_bytes()
        require(hashlib.sha256(data).hexdigest() == item['sha256'], 'Input differs: ' + item['path'])
        require(len(data) == item['bytes'], 'Input byte count differs: ' + item['path'])
    experiment = read(ROOT / 'experiments/results/pipeline-v1.0.0.22.json')
    require(experiment['sample_kind'] == 'non_leaf_control' and experiment['sample_count'] == 1,
            'The saved experiment has only one non-leaf control sample.')
    crop = experiment['images']['crop']
    binding = experiment['binding']
    require(crop['sha256'] == binding['upload_image_sha256'] == binding['prediction_image_sha256'],
            'Capture/upload/prediction hashes differ.')
    require(crop['bytes'] == binding['uploaded_bytes'], 'Upload bytes differ.')
    require(binding['ordered_steps'] == ['capture_requested', 'raw_photo_captured', 'photo_captured',
                                       'upload_started', 'prediction_received', 'history_saved'],
            'Saved pipeline sequence differs.')
    require(experiment['model_result']['is_valid'] is False, 'The control was rejected as non-leaf.')
    require(all(value is False for value in experiment['unverified'].values()),
            'Uncompleted acceptance must remain unverified.')
    release = read(ROOT / 'releases/v1.0.0.22/manifest.json')
    require(release['version'] == experiment['app_version'], 'Release/experiment version differs.')
    require(release['channel'] == 'experimental-preview', 'This is an experimental preview.')
    package_verified = False
    if args.package:
        data = args.package.read_bytes()
        require(hashlib.sha256(data).hexdigest() == release['package']['sha256'], 'AppX hash differs.')
        require(len(data) == release['package']['bytes'], 'AppX byte count differs.')
        package_verified = True
    print(json.dumps({'ok': True, 'fixedInputsVerified': len(source['files']),
                      'experimentSummaryConsistent': True, 'releaseMetadataConsistent': True,
                      'packageContentVerified': package_verified, 'deviceContacted': False,
                      'rawImagesRechecked': False, 'leafPerformanceVerified': False}))


if __name__ == '__main__':
    main()
