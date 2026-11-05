"""A partial failed run must never be overwritten by reusing its label."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import run_output


class PreserveReadings(unittest.TestCase):
    def test_each_partial_result_reserves_its_label(self):
        for suffix in ('-output.json', '-idle.json', '-info.json', '-filled.json', '-soak.json'):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                readings = root / 'benchmarks/results'
                readings.mkdir(parents=True)
                existing = readings / ('prior' + suffix)
                existing.write_text('retained evidence')
                with patch.object(run_output, 'ROOT', root), patch.object(sys, 'argv', ['run_output.py', 'cg', '--label', 'prior']):
                    with self.assertRaises(FileExistsError):
                        run_output.main()
                self.assertEqual(existing.read_text(), 'retained evidence')
                self.assertEqual(list(readings.iterdir()), [existing])


if __name__ == '__main__':
    unittest.main()
