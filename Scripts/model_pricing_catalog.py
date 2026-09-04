#!/usr/bin/env python3
"""Build and validate BarPilot's versioned model-pricing catalogue.

The upstream file is intentionally parsed with a small, strict YAML subset
instead of a third-party package. The source is a flat list of scalar mappings;
any new YAML structure or field fails closed so a format change cannot silently
publish incorrect prices.
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
REQUIRED_PROVIDERS = {"openai", "anthropic", "google"}
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

FOOTNOTE_RE = re.compile(r"\[\^([^\]]+)\]")
KEY_VALUE_RE = re.compile(r"^([a-z_]+):(?:\s*(.*))?$")
MONEY_RE = re.compile(r"^\$(\d+(?:\.\d+)?)$")
THRESHOLD_RE = re.compile(r"^(≤|<=|>)\s*(\d+(?:\.\d+)?)\s*K$", re.IGNORECASE)
IDENTIFIER_RE = re.compile(r"^[a-z0-9_]+:[a-z0-9][a-z0-9.-]*$")
HEX_40_RE = re.compile(r"^[0-9a-f]{40}$")
HEX_64_RE = re.compile(r"^[0-9a-f]{64}$")


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
        "schemaVersion": 1,
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
    validate_catalog(catalog, minimum_model_count=1)
    return catalog


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


def validate_catalog(catalog: dict[str, Any], *, minimum_model_count: int) -> None:
    expect_exact_keys(
        catalog,
        {"schemaVersion", "generatedAt", "pricingUnit", "source", "modelCount", "models"},
        "catalog",
    )
    if catalog["schemaVersion"] != 1:
        raise CatalogError("catalog schemaVersion must be 1")
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

    models = catalog["models"]
    if not isinstance(models, list):
        raise CatalogError("catalog models must be an array")
    if len(models) < minimum_model_count:
        raise CatalogError(f"catalog has {len(models)} models; expected at least {minimum_model_count}")
    if catalog["modelCount"] != len(models):
        raise CatalogError("catalog modelCount does not match the models array")

    seen_ids: set[str] = set()
    providers: set[str] = set()
    for model_index, model in enumerate(models):
        context = f"model {model_index + 1}"
        if not isinstance(model, dict):
            raise CatalogError(f"{context} must be an object")
        required = {"id", "name", "provider", "releaseStatus", "category", "sourceAnnotations", "tiers"}
        allowed = required | {"notes"}
        if not required.issubset(model) or not set(model).issubset(allowed):
            expect_exact_keys(model, required if "notes" not in model else allowed, context)

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


def request_bytes(url: str, *, accept: str, attempts: int = 3) -> bytes:
    headers = {
        "Accept": accept,
        "User-Agent": "BarPilot-model-pricing-catalog/1",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

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
    raise CatalogError(f"unable to fetch the public pricing source after {attempts} attempts: {last_error}")


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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    fetch = subparsers.add_parser("fetch", help="fetch, normalize, validate, and write the live source")
    fetch.add_argument("--output", type=Path, required=True)
    fetch.add_argument("--minimum-model-count", type=int, default=PRODUCTION_MINIMUM_MODELS)

    generate = subparsers.add_parser("generate", help="generate a catalogue from a local source fixture")
    generate.add_argument("--input", type=Path, required=True)
    generate.add_argument("--output", type=Path, required=True)
    generate.add_argument("--source-revision", required=True)
    generate.add_argument("--generated-at", default=utc_now())
    generate.add_argument("--minimum-model-count", type=int, default=1)

    validate = subparsers.add_parser("validate", help="validate an already-generated catalogue")
    validate.add_argument("--input", type=Path, required=True)
    validate.add_argument("--minimum-model-count", type=int, default=PRODUCTION_MINIMUM_MODELS)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "fetch":
            source_text, revision = fetch_source()
            catalog = build_catalog(source_text, source_revision=revision, generated_at=utc_now())
            validate_catalog(catalog, minimum_model_count=args.minimum_model_count)
            write_catalog(args.output, catalog)
            print(f"wrote {catalog['modelCount']} models from source revision {revision[:12]}")
        elif args.command == "generate":
            source_text = args.input.read_text(encoding="utf-8")
            catalog = build_catalog(
                source_text,
                source_revision=args.source_revision,
                generated_at=args.generated_at,
            )
            validate_catalog(catalog, minimum_model_count=args.minimum_model_count)
            write_catalog(args.output, catalog)
            print(f"wrote {catalog['modelCount']} models")
        else:
            catalog = load_catalog(args.input)
            validate_catalog(catalog, minimum_model_count=args.minimum_model_count)
            print(f"validated {catalog['modelCount']} models")
    except (CatalogError, OSError) as error:
        print(f"catalogue error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
