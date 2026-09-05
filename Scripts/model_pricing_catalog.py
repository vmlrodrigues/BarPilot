#!/usr/bin/env python3
"""Build and validate BarPilot's versioned model-pricing catalogue.

The upstream file is intentionally parsed with a small, strict YAML subset
instead of a third-party package. The source is a flat list of scalar mappings;
any new YAML structure or field fails closed so a format change cannot silently
publish incorrect prices. Community-preference data is taken from the official
LM Arena leaderboard dataset and joined only through an explicit, reviewed map.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any


SOURCE_REPOSITORY = "github/docs"
SOURCE_PATH = "data/tables/copilot/models-and-pricing.yml"
SOURCE_API_URL = "https://api.github.com/repos/github/docs/commits"
PRODUCTION_MINIMUM_MODELS = 20
PRODUCTION_MINIMUM_PREFERENCE_MODELS = 5
REQUIRED_PROVIDERS = {"openai", "anthropic", "google"}
ARENA_DATASET = "lmarena-ai/leaderboard-dataset"
ARENA_CONFIGURATION = "text_style_control"
ARENA_SPLIT = "latest"
ARENA_CATEGORY = "overall"
ARENA_METADATA_URL = f"https://huggingface.co/api/datasets/{ARENA_DATASET}"
ARENA_ROWS_URL = "https://datasets-server.huggingface.co/rows"
ARENA_DATASET_URL = f"https://huggingface.co/datasets/{ARENA_DATASET}"
CC_BY_4_URL = "https://creativecommons.org/licenses/by/4.0/"
ARENA_PAGE_SIZE = 100
ARENA_MAX_PAGES = 10
ARENA_MINIMUM_OVERALL_ROWS = 100
ALLOWED_SOURCE_FIELDS = {
    "model",
    "provider",
    "release_status",
    "category",
    "input",
    "cached_input",
    "output",
    "threshold",
    "tier",
    "cache_write",
    "notes",
}
REQUIRED_SOURCE_FIELDS = {
    "model",
    "provider",
    "release_status",
    "category",
    "input",
    "cached_input",
    "output",
}
PROVIDER_ORDER = {
    "openai": 0,
    "anthropic": 1,
    "google": 2,
    "xai": 3,
    "microsoft": 4,
    "github": 5,
    "moonshot_ai": 6,
}

# Deliberately explicit: similar-looking names are not assumed to be the same
# model. A catalogue model may map to multiple published reasoning modes; the
# UI presents those modes independently and never averages their scores.
ARENA_MODEL_MAP: dict[str, tuple[tuple[str, str], ...]] = {
    "openai:gpt-5.4": (("gpt-5.4-high", "High"), ("gpt-5.4", "Default")),
    "openai:gpt-5.4-mini": (("gpt-5.4-mini-high", "High"),),
    "openai:gpt-5.5": (("gpt-5.5-high", "High"), ("gpt-5.5", "Default")),
    "openai:gpt-5.6-luna": (("gpt-5.6-luna-xhigh", "xHigh"),),
    "openai:gpt-5.6-sol": (("gpt-5.6-sol-xhigh", "xHigh"),),
    "openai:gpt-5.6-terra": (("gpt-5.6-terra-xhigh", "xHigh"),),
    "anthropic:claude-fable-5": (("claude-fable-5", "Default"),),
    "anthropic:claude-haiku-4.5": (("claude-haiku-4-5-20251001", "Default"),),
    "anthropic:claude-opus-4.5": (
        ("claude-opus-4-5-20251101-high-32k", "High"),
        ("claude-opus-4-5-20251101", "Default"),
    ),
    "anthropic:claude-opus-4.6": (
        ("claude-opus-4-6-high", "High"),
        ("claude-opus-4-6", "Default"),
    ),
    "anthropic:claude-opus-4.7": (
        ("claude-opus-4-7-high", "High"),
        ("claude-opus-4-7", "Default"),
    ),
    "anthropic:claude-opus-4.8": (
        ("claude-opus-4-8-high", "High"),
        ("claude-opus-4-8", "Default"),
    ),
    "anthropic:claude-opus-5": (
        ("claude-opus-5-high", "High"),
        ("claude-opus-5-max", "Max"),
    ),
    "anthropic:claude-sonnet-4.5": (
        ("claude-sonnet-4-5-20250929-high-32k", "High"),
        ("claude-sonnet-4-5-20250929", "Default"),
    ),
    "anthropic:claude-sonnet-4.6": (("claude-sonnet-4-6", "Default"),),
    "anthropic:claude-sonnet-5": (("claude-sonnet-5-high", "High"),),
    "google:gemini-3.1-pro": (("gemini-3.1-pro-preview", "Preview"),),
    "google:gemini-3.5-flash": (
        ("gemini-3.5-flash-high", "High"),
        ("gemini-3.5-flash-medium", "Medium"),
    ),
    "google:gemini-3.6-flash": (("gemini-3.6-flash-high", "High"),),
    "google:gemini-3.7-flash": (("gemini-3.7-flash-high", "High"),),
    "xai:grok-4.5": (("grok-4.5", "Default"),),
    "xai:grok-4.6": (("grok-4.6-high", "High"),),
    "moonshot_ai:kimi-k3": (("kimi-k3-max", "Max"),),
}

FOOTNOTE_RE = re.compile(r"\[\^([^\]]+)\]")
KEY_VALUE_RE = re.compile(r"^([a-z_]+):(?:\s*(.*))?$")
MONEY_RE = re.compile(r"^\$(\d+(?:\.\d+)?)$")
THRESHOLD_RE = re.compile(r"^(≤|<=|>)\s*(\d+(?:\.\d+)?)\s*K$", re.IGNORECASE)
IDENTIFIER_RE = re.compile(r"^[a-z0-9_]+:[a-z0-9][a-z0-9.-]*$")
HEX_40_RE = re.compile(r"^[0-9a-f]{40}$")
HEX_64_RE = re.compile(r"^[0-9a-f]{64}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class CatalogError(ValueError):
    """A source or catalogue violated the published contract."""


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_scalar(raw: str, line_number: int) -> str:
    value = raw.strip()
    if not value:
        return ""
    if value.startswith("'"):
        if len(value) < 2 or not value.endswith("'"):
            raise CatalogError(f"line {line_number}: unterminated single-quoted value")
        return value[1:-1].replace("''", "'")
    if value.startswith('"'):
        if len(value) < 2 or not value.endswith('"'):
            raise CatalogError(f"line {line_number}: unterminated double-quoted value")
        try:
            decoded = json.loads(value)
        except json.JSONDecodeError as error:
            raise CatalogError(f"line {line_number}: invalid double-quoted value") from error
        if not isinstance(decoded, str):
            raise CatalogError(f"line {line_number}: expected a string scalar")
        return decoded
    return value


def parse_source_yaml(text: str) -> list[dict[str, str]]:
    """Parse the flat list-of-mappings subset used by the upstream data file."""
    rows: list[dict[str, str]] = []
    current: dict[str, str] | None = None

    for line_number, original in enumerate(text.splitlines(), start=1):
        stripped = original.strip()
        if not stripped or stripped.startswith("#"):
            continue

        if original.startswith("- "):
            if current is not None:
                rows.append(current)
            current = {}
            content = original[2:].strip()
        elif original[:1].isspace():
            if current is None:
                raise CatalogError(f"line {line_number}: mapping field appears before the first list item")
            content = stripped
        else:
            raise CatalogError(f"line {line_number}: unsupported YAML structure")

        match = KEY_VALUE_RE.fullmatch(content)
        if not match:
            raise CatalogError(f"line {line_number}: expected a scalar key/value field")
        key, raw_value = match.group(1), match.group(2) or ""
        if key not in ALLOWED_SOURCE_FIELDS:
            raise CatalogError(f"line {line_number}: unknown source field {key!r}")
        if key in current:
            raise CatalogError(f"line {line_number}: duplicate source field {key!r}")
        current[key] = parse_scalar(raw_value, line_number)

    if current is not None:
        rows.append(current)
    if not rows:
        raise CatalogError("source catalogue is empty")
    return rows


def clean_model_name(raw: str) -> tuple[str, list[str]]:
    annotations = FOOTNOTE_RE.findall(raw)
    name = FOOTNOTE_RE.sub("", raw).strip()
    if not name:
        raise CatalogError("model name is empty after removing source annotations")
    return name, sorted(set(annotations))


def normalize_provider(raw: str) -> str:
    provider = re.sub(r"[^a-z0-9_]+", "_", raw.strip().lower()).strip("_")
    if not provider:
        raise CatalogError("provider is empty")
    return provider


def slugify(raw: str) -> str:
    ascii_value = unicodedata.normalize("NFKD", raw).encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-z0-9.]+", "-", ascii_value.lower()).strip("-.")
    slug = re.sub(r"-+", "-", slug)
    if not slug:
        raise CatalogError(f"cannot derive an identifier for model {raw!r}")
    return slug


def normalize_release_status(raw: str) -> str:
    statuses = {
        "ga": "generally-available",
        "public preview": "public-preview",
    }
    status = statuses.get(raw.strip().lower())
    if status is None:
        raise CatalogError(f"unknown release status {raw!r}")
    return status


def decimal_number(value: Decimal) -> int | float:
    integral = value.to_integral_value()
    return int(integral) if value == integral else float(value)


def parse_money(raw: str | None, field: str, *, optional: bool = False) -> int | float | None:
    if raw is None or raw.strip().lower() == "not applicable":
        if optional:
            return None
        raise CatalogError(f"{field} must contain a price")
    match = MONEY_RE.fullmatch(raw.strip())
    if not match:
        raise CatalogError(f"invalid {field} price {raw!r}")
    try:
        value = Decimal(match.group(1))
    except InvalidOperation as error:
        raise CatalogError(f"invalid {field} price {raw!r}") from error
    if not value.is_finite() or value < 0:
        raise CatalogError(f"{field} price must be finite and non-negative")
    return decimal_number(value)


def parse_threshold(raw: str | None) -> dict[str, Any] | None:
    if raw is None or raw.strip().lower() == "not applicable":
        return None
    match = THRESHOLD_RE.fullmatch(raw.strip())
    if not match:
        raise CatalogError(f"invalid input-token threshold {raw!r}")
    token_count = Decimal(match.group(2)) * 1000
    if token_count != token_count.to_integral_value() or token_count <= 0:
        raise CatalogError(f"threshold must resolve to a positive whole token count: {raw!r}")
    return {
        "operator": "less-than-or-equal" if match.group(1) in {"≤", "<="} else "greater-than",
        "tokens": int(token_count),
    }


def normalize_tier(raw: str | None) -> tuple[str, str]:
    value = (raw or "Default").strip().lower()
    if value == "default":
        return "standard", "Standard context"
    if value == "long context":
        return "long-context", "Long context"
    raise CatalogError(f"unknown pricing tier {raw!r}")


def natural_key(value: str) -> tuple[tuple[int, Any], ...]:
    parts: list[tuple[int, Any]] = []
    for part in re.split(r"(\d+(?:\.\d+)*)", value.lower()):
        if not part:
            continue
        if re.fullmatch(r"\d+(?:\.\d+)*", part):
            parts.append((1, tuple(int(component) for component in part.split("."))))
        else:
            parts.append((0, part))
    return tuple(parts)


def build_catalog(
    source_text: str,
    *,
    source_revision: str,
    generated_at: str,
) -> dict[str, Any]:
    if not HEX_40_RE.fullmatch(source_revision):
        raise CatalogError("source revision must be a 40-character lowercase commit SHA")

    source_rows = parse_source_yaml(source_text)
    grouped: dict[tuple[str, str], dict[str, Any]] = {}

    for index, row in enumerate(source_rows, start=1):
        missing = REQUIRED_SOURCE_FIELDS - row.keys()
        if missing:
            raise CatalogError(f"source row {index}: missing fields {', '.join(sorted(missing))}")

        name, annotations = clean_model_name(row["model"])
        provider = normalize_provider(row["provider"])
        key = (provider, name.casefold())
        release_status = normalize_release_status(row["release_status"])
        category = row["category"].strip()
        if not category:
            raise CatalogError(f"source row {index}: category is empty")

        model = grouped.get(key)
        if model is None:
            model = {
                "id": f"{provider}:{slugify(name)}",
                "name": name,
                "provider": provider,
                "releaseStatus": release_status,
                "category": category,
                "sourceAnnotations": annotations,
                "tiers": [],
            }
            if row.get("notes", "").strip():
                model["notes"] = row["notes"].strip()
            grouped[key] = model
        else:
            expected = (model["name"], model["releaseStatus"], model["category"], model.get("notes"))
            actual = (name, release_status, category, row.get("notes", "").strip() or None)
            if expected != actual:
                raise CatalogError(f"source row {index}: inconsistent metadata across tiers for {name}")
            model["sourceAnnotations"] = sorted(set(model["sourceAnnotations"]) | set(annotations))

        tier_id, tier_label = normalize_tier(row.get("tier"))
        if any(existing["id"] == tier_id for existing in model["tiers"]):
            raise CatalogError(f"source row {index}: duplicate {tier_label} tier for {name}")
        model["tiers"].append(
            {
                "id": tier_id,
                "label": tier_label,
                "inputTokenRange": parse_threshold(row.get("threshold")),
                "prices": {
                    "input": parse_money(row.get("input"), "input"),
                    "cachedInput": parse_money(row.get("cached_input"), "cached input"),
                    "cacheWrite": parse_money(row.get("cache_write"), "cache write", optional=True),
                    "output": parse_money(row.get("output"), "output"),
                },
            }
        )

    models = list(grouped.values())
    for model in models:
        model["tiers"].sort(key=lambda tier: 0 if tier["id"] == "standard" else 1)
    models.sort(
        key=lambda model: (
            PROVIDER_ORDER.get(model["provider"], 999),
            model["provider"],
            natural_key(model["name"]),
        )
    )

    digest = hashlib.sha256(source_text.encode("utf-8")).hexdigest()
    catalog = {
        "schemaVersion": 2,
        "generatedAt": generated_at,
        "pricingUnit": "USD per 1 million tokens",
        "source": {
            "repository": SOURCE_REPOSITORY,
            "path": SOURCE_PATH,
            "revision": source_revision,
            "sha256": digest,
            "url": f"https://github.com/{SOURCE_REPOSITORY}/blob/{source_revision}/{SOURCE_PATH}",
        },
        "modelCount": len(models),
        "models": models,
    }
    return catalog


def _arena_number(value: Any, field: str) -> int | float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CatalogError(f"LM Arena {field} must be numeric")
    if not math.isfinite(float(value)):
        raise CatalogError(f"LM Arena {field} must be finite")
    return value


def _arena_integer(value: Any, field: str, *, minimum: int) -> int:
    number = _arena_number(value, field)
    if float(number) != int(number) or number < minimum:
        raise CatalogError(f"LM Arena {field} must be a whole number of at least {minimum}")
    return int(number)


def _arena_date(value: Any, field: str) -> str:
    if not isinstance(value, str) or not DATE_RE.fullmatch(value):
        raise CatalogError(f"LM Arena {field} must be an ISO calendar date")
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError as error:
        raise CatalogError(f"LM Arena {field} must be a valid calendar date") from error
    return value


def normalize_arena_rows(payload_rows: list[Any]) -> list[dict[str, Any]]:
    """Validate and project the official dataset viewer's overall rows."""
    normalized: list[dict[str, Any]] = []
    seen_models: set[str] = set()

    for index, entry in enumerate(payload_rows, start=1):
        if not isinstance(entry, dict) or not isinstance(entry.get("row"), dict):
            raise CatalogError(f"LM Arena row {index} has an invalid envelope")
        if entry.get("truncated_cells") not in (None, []):
            raise CatalogError(f"LM Arena row {index} contains truncated data")
        row = entry["row"]
        if row.get("category") != ARENA_CATEGORY:
            raise CatalogError(f"LM Arena row {index} is not in the overall category")

        model_name = row.get("model_name")
        if not isinstance(model_name, str) or not model_name.strip():
            raise CatalogError(f"LM Arena row {index} has no model name")
        if model_name in seen_models:
            raise CatalogError(f"LM Arena model {model_name!r} is duplicated")
        rank = _arena_integer(row.get("rank"), f"rank for {model_name}", minimum=1)
        votes = _arena_integer(row.get("vote_count"), f"vote count for {model_name}", minimum=0)
        snapshot_date = _arena_date(
            row.get("leaderboard_publish_date"), f"snapshot date for {model_name}"
        )
        rating = _arena_number(row.get("rating"), f"rating for {model_name}")
        lower = _arena_number(row.get("rating_lower"), f"lower rating for {model_name}")
        upper = _arena_number(row.get("rating_upper"), f"upper rating for {model_name}")
        if lower > rating or rating > upper:
            raise CatalogError(f"LM Arena row {model_name!r} has an invalid rating interval")

        seen_models.add(model_name)
        normalized.append(
            {
                "arenaModel": model_name,
                "rank": rank,
                "rating": rating,
                "ratingLower": lower,
                "ratingUpper": upper,
                "voteCount": votes,
                "snapshotDate": snapshot_date,
            }
        )

    dates = {row["snapshotDate"] for row in normalized}
    if len(dates) > 1:
        raise CatalogError("LM Arena overall rows contain multiple snapshot dates")
    return normalized


def validate_arena_metadata(metadata: Any) -> str:
    if not isinstance(metadata, dict):
        raise CatalogError("LM Arena dataset metadata is not an object")
    revision = metadata.get("sha")
    card_data = metadata.get("cardData")
    if not isinstance(revision, str) or not HEX_40_RE.fullmatch(revision):
        raise CatalogError("LM Arena returned an invalid dataset revision")
    if metadata.get("private") is not False or metadata.get("gated") not in (False, None):
        raise CatalogError("LM Arena dataset is no longer public and ungated")
    if metadata.get("disabled") is True:
        raise CatalogError("LM Arena dataset is disabled")
    if not isinstance(card_data, dict) or card_data.get("license") != "cc-by-4.0":
        raise CatalogError("LM Arena dataset is not published under CC BY 4.0")

    configurations = card_data.get("configs")
    if not isinstance(configurations, list) or not any(
        isinstance(item, dict) and item.get("config_name") == ARENA_CONFIGURATION
        for item in configurations
    ):
        raise CatalogError(f"LM Arena dataset has no {ARENA_CONFIGURATION!r} configuration")
    return revision


def arena_source(revision: str, rows: list[dict[str, Any]]) -> dict[str, Any]:
    if not HEX_40_RE.fullmatch(revision):
        raise CatalogError("LM Arena source revision is invalid")
    if not rows:
        raise CatalogError("LM Arena overall leaderboard is empty")
    snapshot_dates = {row["snapshotDate"] for row in rows}
    if len(snapshot_dates) != 1:
        raise CatalogError("LM Arena overall rows contain multiple snapshot dates")
    return {
        "publisher": "LM Arena",
        "dataset": ARENA_DATASET,
        "configuration": ARENA_CONFIGURATION,
        "split": ARENA_SPLIT,
        "category": ARENA_CATEGORY,
        "revision": revision,
        "snapshotDate": next(iter(snapshot_dates)),
        "license": "CC BY 4.0",
        "licenseURL": CC_BY_4_URL,
        "url": ARENA_DATASET_URL,
    }


def enrich_catalog_with_arena(
    catalog: dict[str, Any],
    *,
    source: dict[str, Any],
    rows: list[dict[str, Any]],
) -> dict[str, Any]:
    """Attach exact LM Arena matches without inferring aliases or model families."""
    validate_arena_model_map()
    by_name = {row["arenaModel"]: row for row in rows}
    catalog["communityPreferenceSource"] = source

    for model in catalog["models"]:
        variants = []
        for arena_model, label in ARENA_MODEL_MAP.get(model["id"], ()):
            row = by_name.get(arena_model)
            if row is None:
                continue
            variants.append(
                {
                    "arenaModel": arena_model,
                    "label": label,
                    "rank": row["rank"],
                    "rating": row["rating"],
                    "ratingLower": row["ratingLower"],
                    "ratingUpper": row["ratingUpper"],
                    "voteCount": row["voteCount"],
                }
            )
        if variants:
            variants.sort(key=lambda item: (item["rank"], item["arenaModel"]))
            model["communityPreference"] = {
                "bestRank": min(item["rank"] for item in variants),
                "worstRank": max(item["rank"] for item in variants),
                "variants": variants,
            }

    return catalog


def strip_community_preferences(catalog: dict[str, Any]) -> None:
    """Return a price-only catalogue after a failed or stale enrichment attempt."""
    catalog.pop("communityPreferenceSource", None)
    for model in catalog.get("models", []):
        if isinstance(model, dict):
            model.pop("communityPreference", None)


def reuse_community_preferences(
    catalog: dict[str, Any], previous_catalog: dict[str, Any]
) -> int:
    """Copy a previously validated Arena snapshot onto newly fetched prices.

    Pricing fields always come from ``catalog``. Only the independent Arena
    source description and exact per-model matches are reused, by stable model
    identifier, so an Arena outage cannot freeze GitHub's prices.
    """
    strip_community_preferences(catalog)
    source = previous_catalog.get("communityPreferenceSource")
    if not isinstance(source, dict):
        raise CatalogError("previous catalogue has no community-preference source")
    previous_models = previous_catalog.get("models")
    if not isinstance(previous_models, list):
        raise CatalogError("previous catalogue has no models array")

    by_id = {
        model.get("id"): model.get("communityPreference")
        for model in previous_models
        if isinstance(model, dict) and isinstance(model.get("id"), str)
    }
    catalog["communityPreferenceSource"] = source
    copied = 0
    for model in catalog["models"]:
        preference = by_id.get(model["id"])
        if isinstance(preference, dict):
            model["communityPreference"] = preference
            copied += 1
    return copied


def validate_arena_model_map() -> None:
    seen_arena_models: set[str] = set()
    for catalog_model, mappings in ARENA_MODEL_MAP.items():
        if not IDENTIFIER_RE.fullmatch(catalog_model) or not mappings:
            raise CatalogError(f"invalid LM Arena catalogue mapping for {catalog_model!r}")
        for arena_model, label in mappings:
            if not arena_model or not label or arena_model in seen_arena_models:
                raise CatalogError(f"invalid or duplicate LM Arena mapping for {arena_model!r}")
            seen_arena_models.add(arena_model)


def expect_exact_keys(value: dict[str, Any], expected: set[str], context: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        details = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if extra:
            details.append(f"unexpected {', '.join(extra)}")
        raise CatalogError(f"{context}: {'; '.join(details)}")


def validate_price(value: Any, context: str, *, optional: bool = False) -> None:
    if value is None and optional:
        return
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CatalogError(f"{context} must be numeric")
    if not math.isfinite(float(value)) or value < 0:
        raise CatalogError(f"{context} must be finite and non-negative")


def validate_catalog(
    catalog: dict[str, Any],
    *,
    minimum_model_count: int,
    minimum_preference_model_count: int = 0,
    allow_missing_preferences: bool = False,
) -> None:
    validate_arena_model_map()
    required_catalog_keys = {
        "schemaVersion", "generatedAt", "pricingUnit", "source", "modelCount", "models",
    }
    allowed_catalog_keys = required_catalog_keys | {"communityPreferenceSource"}
    if not required_catalog_keys.issubset(catalog) or not set(catalog).issubset(allowed_catalog_keys):
        expected = required_catalog_keys | (
            {"communityPreferenceSource"} if "communityPreferenceSource" in catalog else set()
        )
        expect_exact_keys(catalog, expected, "catalog")
    if catalog["schemaVersion"] != 2:
        raise CatalogError("catalog schemaVersion must be 2")
    if catalog["pricingUnit"] != "USD per 1 million tokens":
        raise CatalogError("catalog pricingUnit is unsupported")
    try:
        parsed_time = datetime.fromisoformat(str(catalog["generatedAt"]).replace("Z", "+00:00"))
    except ValueError as error:
        raise CatalogError("catalog generatedAt must be an ISO-8601 timestamp") from error
    if parsed_time.tzinfo is None:
        raise CatalogError("catalog generatedAt must include a timezone")

    source = catalog["source"]
    if not isinstance(source, dict):
        raise CatalogError("catalog source must be an object")
    expect_exact_keys(source, {"repository", "path", "revision", "sha256", "url"}, "catalog source")
    if source["repository"] != SOURCE_REPOSITORY or source["path"] != SOURCE_PATH:
        raise CatalogError("catalog source does not identify the expected upstream file")
    if not HEX_40_RE.fullmatch(str(source["revision"])):
        raise CatalogError("catalog source revision is invalid")
    if not HEX_64_RE.fullmatch(str(source["sha256"])):
        raise CatalogError("catalog source digest is invalid")

    preference_source = catalog.get("communityPreferenceSource")
    if preference_source is None:
        if not allow_missing_preferences:
            raise CatalogError("catalog is missing communityPreferenceSource")
    else:
        if not isinstance(preference_source, dict):
            raise CatalogError("catalog communityPreferenceSource must be an object")
        expect_exact_keys(
            preference_source,
            {
                "publisher", "dataset", "configuration", "split", "category", "revision",
                "snapshotDate", "license", "licenseURL", "url",
            },
            "catalog communityPreferenceSource",
        )
        if (
            preference_source["publisher"] != "LM Arena"
            or preference_source["dataset"] != ARENA_DATASET
            or preference_source["configuration"] != ARENA_CONFIGURATION
            or preference_source["split"] != ARENA_SPLIT
            or preference_source["category"] != ARENA_CATEGORY
            or preference_source["license"] != "CC BY 4.0"
            or preference_source["licenseURL"] != CC_BY_4_URL
            or preference_source["url"] != ARENA_DATASET_URL
        ):
            raise CatalogError("catalog community-preference source is unsupported")
        if not HEX_40_RE.fullmatch(str(preference_source["revision"])):
            raise CatalogError("catalog community-preference revision is invalid")
        _arena_date(preference_source["snapshotDate"], "catalogue snapshot date")

    models = catalog["models"]
    if not isinstance(models, list):
        raise CatalogError("catalog models must be an array")
    if len(models) < minimum_model_count:
        raise CatalogError(f"catalog has {len(models)} models; expected at least {minimum_model_count}")
    if catalog["modelCount"] != len(models):
        raise CatalogError("catalog modelCount does not match the models array")

    seen_ids: set[str] = set()
    providers: set[str] = set()
    preference_model_count = 0
    for model_index, model in enumerate(models):
        context = f"model {model_index + 1}"
        if not isinstance(model, dict):
            raise CatalogError(f"{context} must be an object")
        required = {"id", "name", "provider", "releaseStatus", "category", "sourceAnnotations", "tiers"}
        allowed = required | {"notes", "communityPreference"}
        if not required.issubset(model) or not set(model).issubset(allowed):
            expected = required | ({"notes"} if "notes" in model else set())
            expected |= ({"communityPreference"} if "communityPreference" in model else set())
            expect_exact_keys(model, expected, context)

        model_id = model["id"]
        provider = model["provider"]
        if not isinstance(model_id, str) or not IDENTIFIER_RE.fullmatch(model_id):
            raise CatalogError(f"{context} has an invalid identifier")
        if model_id in seen_ids:
            raise CatalogError(f"duplicate model identifier {model_id}")
        seen_ids.add(model_id)
        if not isinstance(provider, str) or not model_id.startswith(f"{provider}:"):
            raise CatalogError(f"{context} identifier is not namespaced by its provider")
        providers.add(provider)
        if not isinstance(model["name"], str) or not model["name"].strip():
            raise CatalogError(f"{context} name is empty")
        if model["releaseStatus"] not in {"generally-available", "public-preview"}:
            raise CatalogError(f"{context} releaseStatus is unsupported")
        if not isinstance(model["category"], str) or not model["category"].strip():
            raise CatalogError(f"{context} category is empty")
        annotations = model["sourceAnnotations"]
        if not isinstance(annotations, list) or any(not isinstance(item, str) or not item for item in annotations):
            raise CatalogError(f"{context} sourceAnnotations must contain non-empty strings")
        if len(annotations) != len(set(annotations)):
            raise CatalogError(f"{context} sourceAnnotations contains duplicates")
        if "notes" in model and (not isinstance(model["notes"], str) or not model["notes"].strip()):
            raise CatalogError(f"{context} notes must be a non-empty string")

        preference = model.get("communityPreference")
        if preference is not None:
            if preference_source is None:
                raise CatalogError(f"{context} has communityPreference without source metadata")
            if not isinstance(preference, dict):
                raise CatalogError(f"{context} communityPreference must be an object")
            expect_exact_keys(
                preference, {"bestRank", "worstRank", "variants"}, f"{context} communityPreference"
            )
            variants = preference["variants"]
            if not isinstance(variants, list) or not variants:
                raise CatalogError(f"{context} communityPreference must have variants")
            seen_arena_models: set[str] = set()
            ranks: list[int] = []
            expected_mappings = dict(ARENA_MODEL_MAP.get(model_id, ()))
            for variant_index, variant in enumerate(variants, start=1):
                variant_context = f"{context} communityPreference variant {variant_index}"
                if not isinstance(variant, dict):
                    raise CatalogError(f"{variant_context} must be an object")
                expect_exact_keys(
                    variant,
                    {
                        "arenaModel", "label", "rank", "rating", "ratingLower", "ratingUpper",
                        "voteCount",
                    },
                    variant_context,
                )
                arena_model = variant["arenaModel"]
                if (
                    not isinstance(arena_model, str)
                    or not arena_model
                    or arena_model in seen_arena_models
                ):
                    raise CatalogError(f"{variant_context} has an invalid or duplicate model name")
                seen_arena_models.add(arena_model)
                if not isinstance(variant["label"], str) or not variant["label"].strip():
                    raise CatalogError(f"{variant_context} has an invalid label")
                if expected_mappings.get(arena_model) != variant["label"]:
                    raise CatalogError(f"{variant_context} is not in the reviewed exact-name map")
                rank = variant["rank"]
                votes = variant["voteCount"]
                if isinstance(rank, bool) or not isinstance(rank, int) or rank <= 0:
                    raise CatalogError(f"{variant_context} has an invalid rank")
                if isinstance(votes, bool) or not isinstance(votes, int) or votes < 0:
                    raise CatalogError(f"{variant_context} has an invalid vote count")
                rating = variant["rating"]
                lower = variant["ratingLower"]
                upper = variant["ratingUpper"]
                validate_price(rating, f"{variant_context} rating")
                validate_price(lower, f"{variant_context} ratingLower")
                validate_price(upper, f"{variant_context} ratingUpper")
                if lower > rating or rating > upper:
                    raise CatalogError(f"{variant_context} has an invalid rating interval")
                ranks.append(rank)
            if preference["bestRank"] != min(ranks) or preference["worstRank"] != max(ranks):
                raise CatalogError(f"{context} communityPreference rank range is inconsistent")
            if variants != sorted(variants, key=lambda item: (item["rank"], item["arenaModel"])):
                raise CatalogError(f"{context} communityPreference variants are not rank-sorted")
            preference_model_count += 1

        tiers = model["tiers"]
        if not isinstance(tiers, list) or not tiers:
            raise CatalogError(f"{context} must have at least one pricing tier")
        tier_ids: set[str] = set()
        by_id: dict[str, dict[str, Any]] = {}
        for tier in tiers:
            if not isinstance(tier, dict):
                raise CatalogError(f"{context} tier must be an object")
            expect_exact_keys(tier, {"id", "label", "inputTokenRange", "prices"}, f"{context} tier")
            tier_id = tier["id"]
            if tier_id not in {"standard", "long-context"} or tier_id in tier_ids:
                raise CatalogError(f"{context} has an invalid or duplicate tier {tier_id!r}")
            tier_ids.add(tier_id)
            by_id[tier_id] = tier
            expected_label = "Standard context" if tier_id == "standard" else "Long context"
            if tier["label"] != expected_label:
                raise CatalogError(f"{context} tier {tier_id} has an invalid label")

            token_range = tier["inputTokenRange"]
            if token_range is not None:
                if not isinstance(token_range, dict):
                    raise CatalogError(f"{context} tier {tier_id} inputTokenRange must be an object or null")
                expect_exact_keys(token_range, {"operator", "tokens"}, f"{context} tier {tier_id} range")
                if token_range["operator"] not in {"less-than-or-equal", "greater-than"}:
                    raise CatalogError(f"{context} tier {tier_id} has an invalid range operator")
                if isinstance(token_range["tokens"], bool) or not isinstance(token_range["tokens"], int) or token_range["tokens"] <= 0:
                    raise CatalogError(f"{context} tier {tier_id} has an invalid token threshold")

            prices = tier["prices"]
            if not isinstance(prices, dict):
                raise CatalogError(f"{context} tier {tier_id} prices must be an object")
            expect_exact_keys(prices, {"input", "cachedInput", "cacheWrite", "output"}, f"{context} tier {tier_id} prices")
            validate_price(prices["input"], f"{context} tier {tier_id} input")
            validate_price(prices["cachedInput"], f"{context} tier {tier_id} cachedInput")
            validate_price(prices["cacheWrite"], f"{context} tier {tier_id} cacheWrite", optional=True)
            validate_price(prices["output"], f"{context} tier {tier_id} output")

        if "standard" not in by_id:
            raise CatalogError(f"{context} is missing its standard tier")
        standard_range = by_id["standard"]["inputTokenRange"]
        long_range = by_id.get("long-context", {}).get("inputTokenRange")
        if standard_range is None and "long-context" in by_id:
            raise CatalogError(f"{context} has long-context pricing without a standard threshold")
        if standard_range is not None:
            if standard_range["operator"] != "less-than-or-equal" or long_range is None:
                raise CatalogError(f"{context} context tiers are incomplete")
            if long_range["operator"] != "greater-than" or long_range["tokens"] != standard_range["tokens"]:
                raise CatalogError(f"{context} context-tier thresholds do not meet at the same boundary")

    missing_providers = REQUIRED_PROVIDERS - providers
    if missing_providers:
        raise CatalogError(f"catalog is missing required providers: {', '.join(sorted(missing_providers))}")
    if preference_source is not None and preference_model_count < minimum_preference_model_count:
        raise CatalogError(
            f"catalog has community-preference data for {preference_model_count} models; "
            f"expected at least {minimum_preference_model_count}"
        )


def request_headers(url: str, *, accept: str) -> dict[str, str]:
    headers = {
        "Accept": accept,
        "User-Agent": "BarPilot-model-pricing-catalog/2",
    }
    host = urllib.parse.urlparse(url).hostname
    token = os.environ.get("GITHUB_TOKEN")
    if token and host in {"api.github.com", "raw.githubusercontent.com"}:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def request_bytes(url: str, *, accept: str, attempts: int = 3) -> bytes:
    headers = request_headers(url, accept=accept)

    last_error: Exception | None = None
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=20) as response:
                if response.status != 200:
                    raise CatalogError(f"request returned HTTP {response.status}")
                return response.read()
        except (urllib.error.URLError, TimeoutError, CatalogError) as error:
            last_error = error
            if attempt + 1 < attempts:
                time.sleep(2**attempt)
    raise CatalogError(f"unable to fetch public catalogue data after {attempts} attempts: {last_error}")


def fetch_source() -> tuple[str, str]:
    query = urllib.parse.urlencode({"path": SOURCE_PATH, "sha": "main", "per_page": 1})
    revision_payload = request_bytes(f"{SOURCE_API_URL}?{query}", accept="application/vnd.github+json")
    try:
        commits = json.loads(revision_payload)
        revision = commits[0]["sha"]
    except (json.JSONDecodeError, IndexError, KeyError, TypeError) as error:
        raise CatalogError("GitHub returned no usable source revision") from error
    if not isinstance(revision, str) or not HEX_40_RE.fullmatch(revision):
        raise CatalogError("GitHub returned an invalid source revision")

    raw_url = f"https://raw.githubusercontent.com/{SOURCE_REPOSITORY}/{revision}/{SOURCE_PATH}"
    source_bytes = request_bytes(raw_url, accept="text/plain")
    try:
        return source_bytes.decode("utf-8"), revision
    except UnicodeDecodeError as error:
        raise CatalogError("pricing source is not valid UTF-8") from error


def fetch_arena() -> tuple[dict[str, Any], list[dict[str, Any]]]:
    metadata_payload = request_bytes(ARENA_METADATA_URL, accept="application/json")
    try:
        metadata = json.loads(metadata_payload)
    except json.JSONDecodeError as error:
        raise CatalogError("LM Arena returned invalid dataset metadata") from error
    revision = validate_arena_metadata(metadata)

    overall_entries: list[Any] = []
    reached_next_category = False
    for page in range(ARENA_MAX_PAGES):
        query = urllib.parse.urlencode(
            {
                "dataset": ARENA_DATASET,
                "config": ARENA_CONFIGURATION,
                "split": ARENA_SPLIT,
                "revision": revision,
                "offset": page * ARENA_PAGE_SIZE,
                "length": ARENA_PAGE_SIZE,
            }
        )
        payload = request_bytes(f"{ARENA_ROWS_URL}?{query}", accept="application/json")
        try:
            page_data = json.loads(payload)
            entries = page_data["rows"]
        except (json.JSONDecodeError, KeyError, TypeError) as error:
            raise CatalogError("LM Arena returned invalid leaderboard rows") from error
        if not isinstance(entries, list) or not entries:
            raise CatalogError("LM Arena returned an empty leaderboard page")

        for entry in entries:
            row = entry.get("row") if isinstance(entry, dict) else None
            category = row.get("category") if isinstance(row, dict) else None
            if category == ARENA_CATEGORY:
                if reached_next_category:
                    raise CatalogError("LM Arena overall rows are no longer contiguous")
                overall_entries.append(entry)
            elif overall_entries:
                reached_next_category = True
                break
            else:
                raise CatalogError("LM Arena no longer publishes overall rows first")
        if reached_next_category:
            break

    if not reached_next_category:
        raise CatalogError("LM Arena overall leaderboard exceeded the safe page limit")
    if len(overall_entries) < ARENA_MINIMUM_OVERALL_ROWS:
        raise CatalogError(
            f"LM Arena returned {len(overall_entries)} overall rows; "
            f"expected at least {ARENA_MINIMUM_OVERALL_ROWS}"
        )
    rows = normalize_arena_rows(overall_entries)

    # Detect a repository update while the paginated viewer response is being
    # read. The rows carry their own snapshot date; this second check ensures the
    # observed dataset revision and licence remained stable for the whole fetch.
    final_metadata_payload = request_bytes(ARENA_METADATA_URL, accept="application/json")
    try:
        final_metadata = json.loads(final_metadata_payload)
    except json.JSONDecodeError as error:
        raise CatalogError("LM Arena returned invalid final dataset metadata") from error
    if validate_arena_metadata(final_metadata) != revision:
        raise CatalogError("LM Arena dataset changed during the paginated fetch; retry later")
    return arena_source(revision, rows), rows


def write_catalog(path: Path, catalog: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def load_catalog(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CatalogError(f"cannot read catalogue JSON: {error}") from error
    if not isinstance(value, dict):
        raise CatalogError("catalogue JSON root must be an object")
    return value


def fetch_catalog(url: str) -> dict[str, Any]:
    try:
        value = json.loads(request_bytes(url, accept="application/json"))
    except json.JSONDecodeError as error:
        raise CatalogError("previous catalogue is not valid JSON") from error
    if not isinstance(value, dict):
        raise CatalogError("previous catalogue root must be an object")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    fetch = subparsers.add_parser("fetch", help="fetch, normalize, validate, and write the live source")
    fetch.add_argument("--output", type=Path, required=True)
    fetch.add_argument("--minimum-model-count", type=int, default=PRODUCTION_MINIMUM_MODELS)
    fetch.add_argument(
        "--minimum-preference-model-count",
        type=int,
        default=PRODUCTION_MINIMUM_PREFERENCE_MODELS,
    )
    fetch.add_argument(
        "--preference-fallback-url",
        help="last published catalogue whose validated LM Arena snapshot may be reused",
    )
    fetch.add_argument(
        "--allow-missing-preferences",
        action="store_true",
        help="publish current prices even if neither fresh nor previous Arena data is usable",
    )

    generate = subparsers.add_parser(
        "generate", help="generate a catalogue from local pricing and LM Arena fixtures"
    )
    generate.add_argument("--input", type=Path, required=True)
    generate.add_argument("--arena-input", type=Path, required=True)
    generate.add_argument("--arena-revision", required=True)
    generate.add_argument("--output", type=Path, required=True)
    generate.add_argument("--source-revision", required=True)
    generate.add_argument("--generated-at", default=utc_now())
    generate.add_argument("--minimum-model-count", type=int, default=1)
    generate.add_argument("--minimum-preference-model-count", type=int, default=1)

    validate = subparsers.add_parser("validate", help="validate an already-generated catalogue")
    validate.add_argument("--input", type=Path, required=True)
    validate.add_argument("--minimum-model-count", type=int, default=PRODUCTION_MINIMUM_MODELS)
    validate.add_argument(
        "--minimum-preference-model-count",
        type=int,
        default=PRODUCTION_MINIMUM_PREFERENCE_MODELS,
    )
    validate.add_argument("--allow-missing-preferences", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "fetch":
            source_text, revision = fetch_source()
            catalog = build_catalog(source_text, source_revision=revision, generated_at=utc_now())
            preference_status = "fresh"
            fresh_error: CatalogError | None = None
            try:
                preference_source, arena_rows = fetch_arena()
                enrich_catalog_with_arena(catalog, source=preference_source, rows=arena_rows)
                validate_catalog(
                    catalog,
                    minimum_model_count=args.minimum_model_count,
                    minimum_preference_model_count=args.minimum_preference_model_count,
                )
            except CatalogError as error:
                fresh_error = error
                strip_community_preferences(catalog)
                preference_status = "unavailable"
                if args.preference_fallback_url:
                    try:
                        previous = fetch_catalog(args.preference_fallback_url)
                        validate_catalog(
                            previous,
                            minimum_model_count=1,
                            minimum_preference_model_count=1,
                        )
                        reuse_community_preferences(catalog, previous)
                        validate_catalog(
                            catalog,
                            minimum_model_count=args.minimum_model_count,
                            minimum_preference_model_count=args.minimum_preference_model_count,
                        )
                        preference_status = "last-known-good"
                    except CatalogError as fallback_error:
                        strip_community_preferences(catalog)
                        print(
                            f"warning: fresh LM Arena data failed ({fresh_error}); "
                            f"previous snapshot failed ({fallback_error})",
                            file=sys.stderr,
                        )
                if preference_status == "unavailable" and not args.allow_missing_preferences:
                    raise fresh_error
            validate_catalog(
                catalog,
                minimum_model_count=args.minimum_model_count,
                minimum_preference_model_count=args.minimum_preference_model_count,
                allow_missing_preferences=args.allow_missing_preferences,
            )
            write_catalog(args.output, catalog)
            preference_count = sum("communityPreference" in model for model in catalog["models"])
            print(
                f"wrote {catalog['modelCount']} models with {preference_count} LM Arena matches "
                f"from pricing revision {revision[:12]} (Arena: {preference_status})"
            )
        elif args.command == "generate":
            source_text = args.input.read_text(encoding="utf-8")
            catalog = build_catalog(
                source_text,
                source_revision=args.source_revision,
                generated_at=args.generated_at,
            )
            arena_payload = json.loads(args.arena_input.read_text(encoding="utf-8"))
            if not isinstance(arena_payload, dict) or not isinstance(arena_payload.get("rows"), list):
                raise CatalogError("local LM Arena fixture must contain a rows array")
            arena_rows = normalize_arena_rows(arena_payload["rows"])
            enrich_catalog_with_arena(
                catalog,
                source=arena_source(args.arena_revision, arena_rows),
                rows=arena_rows,
            )
            validate_catalog(
                catalog,
                minimum_model_count=args.minimum_model_count,
                minimum_preference_model_count=args.minimum_preference_model_count,
            )
            write_catalog(args.output, catalog)
            print(f"wrote {catalog['modelCount']} models")
        else:
            catalog = load_catalog(args.input)
            validate_catalog(
                catalog,
                minimum_model_count=args.minimum_model_count,
                minimum_preference_model_count=args.minimum_preference_model_count,
                allow_missing_preferences=args.allow_missing_preferences,
            )
            print(f"validated {catalog['modelCount']} models")
    except (CatalogError, OSError, json.JSONDecodeError) as error:
        print(f"catalogue error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
