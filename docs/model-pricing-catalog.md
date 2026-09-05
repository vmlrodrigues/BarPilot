# Model pricing and community-preference pipeline

BarPilot publishes one normalized snapshot containing GitHub Copilot model prices
and LM Arena community-preference data. GitHub Actions performs the fetching,
validation, and exact model matching. The app only downloads the resulting static
JSON file; it never contacts LM Arena directly and contains no service credential.

Tracked by GitHub issue #52.

## Published contract

- Catalogue: `<Pages deployment URL>/model-pricing/v2/catalog.json`
- JSON Schema: `<Pages deployment URL>/model-pricing/v2/schema.json`

Schema v2 is intentionally a breaking replacement for the unreleased v1 model-
pricing prototype. GitHub pricing and its source description are mandatory.
LM Arena data is an optional enrichment: when fresh Arena data is unavailable the
pipeline first reuses the last validated Arena snapshot; if that is unavailable too,
it publishes current prices without ranks. An individual model may also omit
`communityPreference` when there is no exact current LM Arena match.

The pricing portion preserves GitHub's provider, release status, category, prices,
source revision, and source-file SHA-256. Markdown footnote markers are removed
from display names and retained as `sourceAnnotations`. GitHub's `Default` tier
is presented as `Standard context` because it describes the price below a context
threshold; it does not mean that the model is a default selection.

The community-preference portion uses the official `lmarena-ai/leaderboard-dataset`:

- configuration: `text_style_control`;
- split: `latest`;
- category: `overall`;
- values preserved: rank, rating, published rating interval, vote count, snapshot
  date, and source model name; and
- matching: an explicit, reviewed map in `Scripts/model_pricing_catalog.py`.

Similar names are not treated as aliases. For example, GPT-5.3 Chat is not matched
to GPT-5.3 Codex. Where LM Arena publishes more than one reasoning mode for a model,
v2 retains every matched mode and reports the best-to-worst rank range instead of
averaging scores or selecting an unexplained winner.

The catalogue does not publish favourites. Favourites remain user-owned app state.
It also does not infer model age because neither upstream source supplies a reliable
release date for every model.

## App consumption

The dashboard's **Model prices…** button opens the dialogue implemented in
`Sources/BarPilot/ModelPricing.swift`. The app validates schema v2 before use,
caches the last valid response in Application Support for 12 hours, refuses to
replace a newer cached snapshot with an older deployment, and ships a compact
built-in snapshot for a first offline launch. A manual refresh bypasses the
12-hour check.

The **Arena** column shows community-preference rank; `#1` is the most preferred
entry and lower is better. Arena derives its score and rank from blind, pairwise
human votes using a Bradley-Terry statistical model. The Arena score is a relative
preference rating, not a percentage; vote count is the number of battles involving
that model. The detail panel also shows Arena's published score interval.

A range such as `#7–12` is BarPilot shorthand for multiple explicitly matched
reasoning modes at those ranks; it is not Arena's statistical rank spread. An em
dash means no defensible exact match, not a score of zero. BarPilot's chosen
style-controlled leaderboard adjusts for response-style effects. These numbers
represent community preference, not intelligence, factual accuracy, coding skill,
task suitability, or value for money.

## Automation

`.github/workflows/publish-model-pricing.yml` runs:

- after relevant changes land on `main`;
- for pull requests that modify the pipeline;
- daily at 04:17 UTC; and
- manually through **Actions → Publish model pricing catalogue → Run workflow**.

The build job:

1. runs the fixture-based unit tests;
2. resolves and downloads an immutable GitHub Docs pricing revision;
3. attempts to read the public, ungated LM Arena dataset through Hugging Face's documented
   Dataset Viewer API;
4. verifies LM Arena still declares CC BY 4.0, fetches the contiguous overall
   leaderboard pages, and confirms the observed dataset revision did not change
   during pagination;
5. joins only exact names from the reviewed mapping;
6. validates model counts, required providers, price tiers, ratings, intervals,
   vote counts, ranks, source metadata, and a minimum number of matched models;
7. if Arena is unavailable, reuses only ranking fields from the last validated
   published catalogue, or explicitly omits rankings when no safe fallback exists; and
8. publishes the catalogue and schema to GitHub Pages.

The deploy job depends on the complete build. A GitHub pricing failure, source
format change, malformed price, missing major provider, or unexpectedly small
catalogue leaves the previous Pages deployment intact. An Arena outage cannot hold
back a valid GitHub price change; it produces last-known-good or explicitly absent
rankings, both of which the app presents honestly.
`GITHUB_TOKEN` is sent only to GitHub hosts and is never sent to Hugging Face.
No LM Arena or Hugging Face key is required.

GitHub automatically disables scheduled workflows in an inactive public
repository after 60 days. A push or manual re-enable restores the schedule.

## Local verification

The pipeline uses only Python's standard library:

```sh
python3 -m unittest discover -s Tests/model_pricing_catalog -p 'test_*.py'

python3 Scripts/model_pricing_catalog.py generate \
  --input Tests/model_pricing_catalog/fixtures/models-and-pricing.yml \
  --arena-input Tests/model_pricing_catalog/fixtures/arena-rows.json \
  --arena-revision dddddddddddddddddddddddddddddddddddddddd \
  --output /tmp/model-pricing-v2.json \
  --source-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --generated-at 2026-09-04T00:00:00Z \
  --minimum-model-count 3 \
  --minimum-preference-model-count 2

python3 Scripts/model_pricing_catalog.py validate \
  --input /tmp/model-pricing-v2.json \
  --minimum-model-count 3 \
  --minimum-preference-model-count 2
```

To exercise both public sources and the production safety floors:

```sh
python3 Scripts/model_pricing_catalog.py fetch \
  --output /tmp/model-pricing-v2.json \
  --minimum-model-count 20 \
  --minimum-preference-model-count 5 \
  --preference-fallback-url https://vmlrodrigues.github.io/BarPilot/model-pricing/v2/catalog.json \
  --allow-missing-preferences
```

## Licensing and attribution

Both transformed datasets are published under Creative Commons Attribution 4.0.
The source links, licence link, source revisions/snapshot, and a description of
BarPilot's transformations are included in the repository notices, public JSON,
and the app's expandable attribution panel. See `THIRD_PARTY_NOTICES.md`.

## GitHub Pages setup

The repository's Pages source must be **GitHub Actions**. The deploy job uses only
`pages: write` and `id-token: write`; the build job has read-only repository
access. No long-lived secret is required.
