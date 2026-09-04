import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "Scripts" / "model_pricing_catalog.py"
FIXTURE_PATH = Path(__file__).parent / "fixtures" / "models-and-pricing.yml"
SPEC = importlib.util.spec_from_file_location("model_pricing_catalog", SCRIPT_PATH)
assert SPEC and SPEC.loader
catalogue = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalogue)


class ModelPricingCatalogTests(unittest.TestCase):
    def setUp(self):
        self.source = FIXTURE_PATH.read_text(encoding="utf-8")
        self.catalog = catalogue.build_catalog(
            self.source,
            source_revision="a" * 40,
            generated_at="2026-09-04T00:00:00Z",
        )

    def test_normalizes_models_tiers_and_annotations(self):
        catalogue.validate_catalog(self.catalog, minimum_model_count=3)
        self.assertEqual(self.catalog["modelCount"], 3)

        sol = next(model for model in self.catalog["models"] if model["id"] == "openai:gpt-5.6-sol")
        self.assertEqual(sol["name"], "GPT-5.6 Sol")
        self.assertEqual(sol["sourceAnnotations"], ["gpt-56-sol-promo"])
        self.assertEqual([tier["id"] for tier in sol["tiers"]], ["standard", "long-context"])
        self.assertEqual(sol["tiers"][0]["label"], "Standard context")
        self.assertEqual(
            sol["tiers"][0]["inputTokenRange"],
            {"operator": "less-than-or-equal", "tokens": 272000},
        )
        self.assertEqual(sol["tiers"][1]["prices"]["cacheWrite"], 5)

    def test_rejects_unknown_source_fields(self):
        with self.assertRaisesRegex(catalogue.CatalogError, "unknown source field"):
            catalogue.parse_source_yaml(self.source + "\n  unexpected_field: value\n")

    def test_rejects_duplicate_tiers(self):
        duplicate = self.source + """

- model: Claude Sonnet 5
  provider: anthropic
  release_status: GA
  category: Versatile
  input: $2.00
  cached_input: $0.20
  output: $10.00
  cache_write: $2.50
"""
        with self.assertRaisesRegex(catalogue.CatalogError, "duplicate Standard context tier"):
            catalogue.build_catalog(
                duplicate,
                source_revision="b" * 40,
                generated_at="2026-09-04T00:00:00Z",
            )

    def test_rejects_tampered_model_count(self):
        invalid = copy.deepcopy(self.catalog)
        invalid["modelCount"] += 1
        with self.assertRaisesRegex(catalogue.CatalogError, "modelCount"):
            catalogue.validate_catalog(invalid, minimum_model_count=3)

    def test_generate_and_validate_cli_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "catalog.json"
            result = catalogue.main(
                [
                    "generate",
                    "--input",
                    str(FIXTURE_PATH),
                    "--output",
                    str(output),
                    "--source-revision",
                    "c" * 40,
                    "--generated-at",
                    "2026-09-04T00:00:00Z",
                    "--minimum-model-count",
                    "3",
                ]
            )
            self.assertEqual(result, 0)
            self.assertEqual(catalogue.main(["validate", "--input", str(output), "--minimum-model-count", "3"]), 0)
            decoded = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(decoded["schemaVersion"], 1)


if __name__ == "__main__":
    unittest.main()
