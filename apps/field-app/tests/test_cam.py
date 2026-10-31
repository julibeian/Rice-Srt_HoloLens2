import importlib.util
import sys
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('field_cam',ROOT/'server/cam.py')
cam=importlib.util.module_from_spec(spec);sys.modules['field_cam']=cam;spec.loader.exec_module(cam)


class CamTests(unittest.TestCase):
    def test_normalizes_and_returns_peak_cell_box(self):
        value=cam.payload([[0,0,0],[0,8,0],[0,0,2]])
        self.assertIsNotNone(value)
        self.assertEqual(value['grid']['width'],3);self.assertEqual(value['grid']['height'],3)
        self.assertEqual(value['grid']['values'][1][1],1.0);self.assertEqual(value['grid']['values'][2][2],0.25)
        self.assertEqual(value['box'],[0.3333,0.3333,0.3333,0.3333]);self.assertEqual(value['peak'],[0.5,0.5])
    def test_threshold_cluster_expands_to_bounding_cells(self):
        value=cam.payload([[1,1,0,0],[1,0,0,0],[0,0,0,0],[0,0,0,0]],threshold=0.9)
        self.assertEqual(value['box'],[0.0,0.0,0.5,0.5])
    def test_below_threshold_falls_back_to_brightest_cell(self):
        value=cam.payload([[0.2,0.3],[0.1,0.4]],threshold=0.9)
        self.assertEqual(value['box'],[0.5,0.5,0.5,0.5]);self.assertEqual(value['peak'],[0.75,0.75])
    def test_invalid_or_empty_values_are_rejected(self):
        for value in (None,[],[[]],[[1,2],[3]],[[0,0],[0,0]],'x'):
            self.assertIsNone(cam.payload(value),repr(value))
        value=cam.payload([[float('nan'),1]])
        self.assertEqual(value['grid']['values'],[[0.0,1.0]])
        self.assertEqual(value['box'],[0.5,0.0,0.5,1.0])
    def test_negative_values_are_clamped(self):
        value=cam.payload([[-3,2],[-1,0]])
        self.assertEqual(value['grid']['values'],[[0.0,1.0],[0.0,0.0]])
        self.assertEqual(value['box'],[0.5,0.0,0.5,0.5])


if __name__=='__main__':unittest.main()
