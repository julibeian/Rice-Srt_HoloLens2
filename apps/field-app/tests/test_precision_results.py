import copy
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('precision_results',Path(__file__).parents[1]/'ops/Verify-YoloPrecisionResults.py')
verify_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify_module)


def fixture():
    manifest=dict(passed=True,sha256='half',source_sha256='single',parity=[])
    candidate=[];baseline=[]
    for index in range(4):
        name=f'case{index}.jpg';manifest['parity'].append(dict(case=name,detections=[]))
        native=dict(modelSha256='half',onDevice=True,hr=0,source='diagnostic_asset',tensorReuse=True,
                    inputSignature=str(index),detections=[dict(classId=1,confidence=.8,box=[10,20,30,40])])
        candidate.append(dict(name=name,native=native,runtime_session='one-session'))
        previous=copy.deepcopy(native);previous['modelSha256']='single';previous['detections'][0]['confidence']=.806
        baseline.append(dict(name=name,native=previous))
    return manifest,candidate,baseline


class PrecisionResultTests(unittest.TestCase):
    def test_same_device_rounding_passes_the_declared_gate(self):
        self.assertTrue(verify_module.verify(*fixture())['passed'])

    def test_large_numeric_drift_does_not_pass(self):
        manifest,candidate,baseline=fixture();candidate[0]['native']['detections'][0]['confidence']=.7
        with self.assertRaisesRegex(ValueError,'tolerance'):
            verify_module.verify(manifest,candidate,baseline)

    def test_other_inputs_and_missing_cases_cannot_pass(self):
        manifest,candidate,baseline=fixture();baseline[0]['native']['inputSignature']='different'
        with self.assertRaisesRegex(ValueError,'signature'):
            verify_module.verify(manifest,candidate,baseline)
        with self.assertRaisesRegex(ValueError,'Missing'):
            verify_module.verify(manifest,candidate[:-1],baseline)


if __name__=='__main__':unittest.main()
