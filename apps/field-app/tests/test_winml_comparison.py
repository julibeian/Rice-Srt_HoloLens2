import copy
import importlib.util
from pathlib import Path
import unittest

SPEC=importlib.util.spec_from_file_location('comparison_audit',Path(__file__).parents[1]/'ops/Audit-WinMLComparison.py')
AUDIT=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(AUDIT)


def summaries():
    return [dict(run_id=t[0],status='recorded',errors=[],samples=120,fresh_results=12,
                 frame_delta=50 if t[1]=='original' else 60,seconds=119,
                 input_source_dimensions=[(896,504)],inference_mean_ms=2000 if t[1]=='original' else 1600)
            for t in AUDIT.TRIALS]


class ComparisonAuditTests(unittest.TestCase):
    def test_separates_latency_change_and_actual_completed_rate(self):
        records=summaries();records[1]['frame_delta']=55
        result=AUDIT.compare(records)
        self.assertAlmostEqual(result['observed_latency_reduction_percent'],20)
        self.assertAlmostEqual(result['completed_rate_increase_percent'],15)
        self.assertEqual(result['arms']['original']['observed_unique_results'],24)

    def test_incomplete_and_stalled_trials_do_not_pass(self):
        for key,value in [('status','sampling'),('frame_delta',0),('errors',['identity_changed']),('samples',119)]:
            records=summaries();records[2][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):AUDIT.compare(records)

    def test_camera_change_or_reordered_trials_do_not_pass(self):
        records=summaries();records[0]['input_source_dimensions']=[(1280,720)]
        with self.assertRaises(ValueError):AUDIT.compare(records)
        records=summaries();records[0],records[1]=records[1],records[0]
        with self.assertRaises(ValueError):AUDIT.compare(records)

    def test_observed_runtime_must_match_package_and_live_camera(self):
        evidence=dict(Version='1.0.0.60',ModelSha256='a'*64)
        state=dict(version=evidence['Version'],cameraPreviewReady=True,nativeDetector=dict(
            modelSha256=evidence['ModelSha256'],onDevice=True,modelLoaded=True,inputSize=320))
        AUDIT.verify_runtime_row({'app':{'body':state}},evidence)
        for target,key,value in [('state','version','1.0.0.61'),('state','cameraPreviewReady',False),
                                 ('native','modelSha256','b'*64),('native','onDevice',False),
                                 ('native','modelLoaded',False),('native','inputSize',640)]:
            changed=copy.deepcopy(state)
            (changed if target=='state' else changed['nativeDetector'])[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):
                AUDIT.verify_runtime_row({'app':{'body':changed}},evidence)


if __name__=='__main__':unittest.main()
