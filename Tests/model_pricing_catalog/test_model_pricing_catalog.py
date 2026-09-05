import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "Scripts" / "model_pricing_catalog.py"
FIXTURE_PATH = Path(__file__).parent / "fixtures" / "models-and-pricing.yml"
ARENA_FIXTURE_PATH = Path(__file__).parent / "fixtures" / "arena-rows.json"
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
        arena_payload = json.loads(ARENA_FIXTURE_PATH.read_text(encoding="utf-8"))
        self.arena_rows = catalogue.normalize_arena_rows(arena_payload["rows"])
        catalogue.enrich_catalog_with_arena(
            self.catalog,
            source=catalogue.arena_source("d" * 40, self.arena_rows),
            rows=self.arena_rows,
        )

    def test_normalizes_models_tiers_and_annotations(self):
        catalogue.validate_catalog(
            self.catalog, minimum_model_count=3, minimum_preference_model_count=2
        )
        self.assertEqual(self.catalog["modelCount"], 4)

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
        self.assertEqual(sol["communityPreference"]["bestRank"], 16)
        self.assertEqual(sol["communityPreference"]["variants"][0]["label"], "xHigh")

        sonnet = next(
            model for model in self.catalog["models"] if model["id"] == "anthropic:claude-sonnet-5"
        )
        self.assertEqual(sonnet["communityPreference"]["bestRank"], 46)
        haiku = next(
            model for model in self.catalog["models"] if model["id"] == "anthropic:claude-haiku-4.5"
        )
        self.assertEqual(haiku["communityPreference"]["bestRank"], 129)
        self.assertEqual(haiku["communityPreference"]["variants"][0]["voteCount"], 124979)
        gemini = next(
            model for model in self.catalog["models"] if model["id"] == "google:gemini-3.8-flash"
        )
        self.assertNotIn("communityPreference", gemini)

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

    def test_rejects_inconsistent_arena_rank_range(self):
        invalid = copy.deepcopy(self.catalog)
        sol = next(model for model in invalid["models"] if model["id"] == "openai:gpt-5.6-sol")
        sol["communityPreference"]["bestRank"] = 1
        with self.assertRaisesRegex(catalogue.CatalogError, "rank range"):
            catalogue.validate_catalog(invalid, minimum_model_count=3)

    def test_rejects_arena_rating_outside_interval(self):
        invalid = copy.deepcopy(self.catalog)
        sol = next(model for model in invalid["models"] if model["id"] == "openai:gpt-5.6-sol")
        sol["communityPreference"]["variants"][0]["ratingLower"] = 2000
        with self.assertRaisesRegex(catalogue.CatalogError, "rating interval"):
            catalogue.validate_catalog(invalid, minimum_model_count=3)

    def test_rejects_unreviewed_arena_alias(self):
        invalid = copy.deepcopy(self.catalog)
        sol = next(model for model in invalid["models"] if model["id"] == "openai:gpt-5.6-sol")
        sol["communityPreference"]["variants"][0]["arenaModel"] = "gpt-5.6-sol"
        with self.assertRaisesRegex(catalogue.CatalogError, "reviewed exact-name map"):
            catalogue.validate_catalog(invalid, minimum_model_count=3)

    def test_rejects_non_cc_by_arena_metadata(self):
        metadata = {
            "sha": "e" * 40,
            "private": False,
            "gated": False,
            "disabled": False,
            "cardData": {
                "license": "other",
                "configs": [{"config_name": "text_style_control"}],
            },
        }
        with self.assertRaisesRegex(catalogue.CatalogError, "CC BY 4.0"):
            catalogue.validate_arena_metadata(metadata)

    def test_accepts_integral_decimal_vote_counts(self):
        payload = json.loads(ARENA_FIXTURE_PATH.read_text(encoding="utf-8"))
        payload["rows"][0]["row"]["vote_count"] = 23153.0
        rows = catalogue.normalize_arena_rows(payload["rows"])
        self.assertEqual(rows[0]["voteCount"], 23153)
        self.assertIsInstance(rows[0]["voteCount"], int)

    def test_github_token_is_never_sent_to_hugging_face(self):
        with patch.dict(catalogue.os.environ, {"GITHUB_TOKEN": "test-secret"}):
            github_headers = catalogue.request_headers(
                "https://api.github.com/repos/github/docs/commits",
                accept="application/json",
            )
            arena_headers = catalogue.request_headers(
                "https://datasets-server.huggingface.co/rows",
                accept="application/json",
            )
        self.assertEqual(github_headers["Authorization"], "Bearer test-secret")
        self.assertNotIn("Authorization", arena_headers)

    def test_requires_community_preference_source_in_v2(self):
        invalid = copy.deepcopy(self.catalog)
        invalid.pop("communityPreferenceSource")
        with self.assertRaisesRegex(catalogue.CatalogError, "missing communityPreferenceSource"):
            catalogue.validate_catalog(invalid, minimum_model_count=3)

    def test_generate_and_validate_cli_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "catalog.json"
            result = catalogue.main(
                [
                    "generate",
                    "--input",
                    str(FIXTURE_PATH),
                    "--arena-input",
                    str(ARENA_FIXTURE_PATH),
                    "--arena-revision",
                    "d" * 40,
                    "--output",
                    str(output),
                    "--source-revision",
                    "c" * 40,
                    "--generated-at",
                    "2026-09-04T00:00:00Z",
                    "--minimum-model-count",
                    "3",
                    "--minimum-preference-model-count",
                    "2",
                ]
            )
            self.assertEqual(result, 0)
            self.assertEqual(
                catalogue.main(
                    [
                        "validate",
                        "--input",
                        str(output),
                        "--minimum-model-count",
                        "3",
                        "--minimum-preference-model-count",
                        "2",
                    ]
                ),
                0,
            )
            decoded = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(decoded["schemaVersion"], 2)


if __name__ == "__main__":
    unittest.main()
