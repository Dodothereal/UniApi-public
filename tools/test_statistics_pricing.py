#!/usr/bin/env python3
"""Price-ledger admission and generated-data refusal regressions."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from generate_statistics_pricing import CATALOG, ROOT, validate


class PriceCatalogTests(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads(CATALOG.read_text())

    def test_current_catalog_is_admitted_and_native_data_matches(self):
        validate(self.catalog)
        subprocess.run([sys.executable, str(ROOT / 'tools/generate_statistics_pricing.py'), '--check'], check=True, capture_output=True)

    def test_negative_nonfinite_or_missing_component_prices_are_rejected(self):
        for value in (-1, float('inf'), float('nan'), True, '1'):
            with self.subTest(value=value), self.assertRaises(AssertionError):
                c = copy.deepcopy(self.catalog); c['models'][0]['rates']['input'] = value; validate(c)
        with self.assertRaises(AssertionError):
            c = copy.deepcopy(self.catalog); del c['models'][0]['rates']['cacheRead']; validate(c)
        with self.assertRaises(AssertionError):
            c = copy.deepcopy(self.catalog); c['models'][0]['rates'] = dict.fromkeys(c['models'][0]['rates']); validate(c)
        c = copy.deepcopy(self.catalog); c['models'][0]['rates']['input'] = 0; c['models'][0]['rates']['cacheRead'] = None
        validate(c)  # Published zero and unknown are distinct admitted values.

    def test_alias_collision_unpriced_collision_and_missing_evidence_are_rejected(self):
        for change in (
            lambda c: c['models'][1]['aliases'].append(c['models'][0]['id']),
            lambda c: c['unpriced'].append({'id': c['models'][0]['id'], 'reason': 'Collision'}),
            lambda c: c['models'][0].update(sourceURL='http://example.org/prices'),
            lambda c: c['models'][0].update(assumption=''),
            lambda c: c['models'][0].update(aliases='xyz'),
            lambda c: c['models'][0].update(aliases=[{}]),
            lambda c: c['unpriced'][0].update(reason={}),
            lambda c: c.update(basis={}),
            lambda c: c.pop('basis'),
            lambda c: c['models'][0].update(checkedAt='2025-01-01'),
        ):
            c = copy.deepcopy(self.catalog); change(c)
            with self.assertRaises((AssertionError, KeyError)): validate(c)

    def test_stale_generated_data_is_rejected_without_overwriting_either_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / 'tools/generate_statistics_pricing.py'; script.parent.mkdir()
            script.write_bytes((ROOT / 'tools/generate_statistics_pricing.py').read_bytes())
            catalog = root / CATALOG.relative_to(ROOT); catalog.parent.mkdir(parents=True)
            catalog.write_bytes(CATALOG.read_bytes())
            output = root / 'native/swift/Sources/UniApiCore/StatisticsPriceCatalog.swift'; output.parent.mkdir(parents=True)
            output.write_text('// stale fixture\n'); before = (catalog.read_bytes(), output.read_bytes())
            result = subprocess.run([sys.executable, str(script), '--check'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0); self.assertIn('stale', result.stderr)
            self.assertEqual((catalog.read_bytes(), output.read_bytes()), before)


if __name__ == '__main__':
    unittest.main()
