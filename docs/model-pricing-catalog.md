# Model pricing catalogue pipeline

BarPilot publishes a normalized snapshot of GitHub Copilot model pricing for a
future offline-first client. The catalogue is static data; there is no application
server, database, credential, or user data in this pipeline.

Tracked by GitHub issue #52.

## Published contract

- Catalogue: `<Pages deployment URL>/model-pricing/v1/catalog.json`
- JSON Schema: `<Pages deployment URL>/model-pricing/v1/schema.json`

The root `schemaVersion` is an integer. Breaking contract changes must publish a
new versioned path rather than modifying v1 incompatibly.

The catalogue preserves GitHub's provider, release status, category, prices,
source revision, and source-file SHA-256. Markdown footnote markers are removed
from display names and retained as `sourceAnnotations`. GitHub's `Default` tier
is presented as `Standard context` because it describes the price below a context
threshold; it does not mean that the model is a default selection.

The catalogue does not publish a shortlist. A shortlist is user-owned state and
must remain local to the app. It also does not infer model age: the source does
not provide a reliable release date.

## Automation

`.github/workflows/publish-model-pricing.yml` runs:

- after relevant changes land on `main`;
- for pull requests that modify the pipeline;
- daily at 04:17 UTC; and
- manually through **Actions → Publish model pricing catalogue → Run workflow**.

The workflow resolves the commit that last changed GitHub's public pricing source,
downloads that immutable revision, normalizes it, runs the tests and validation,
and only then uploads a GitHub Pages artifact. The deploy job depends on the build
job, so a failed fetch, unexpected source field, malformed price, incomplete
context tier, duplicate identifier, missing major provider, or unexpectedly small
catalogue leaves the previous Pages deployment untouched.

GitHub automatically disables scheduled workflows in an inactive public
repository after 60 days. A push or a manual re-enable restores the schedule.

## Local verification

The implementation uses only Python's standard library:

```sh
python3 -m unittest discover -s Tests/model_pricing_catalog -p 'test_*.py'

python3 Scripts/model_pricing_catalog.py generate \
  --input Tests/model_pricing_catalog/fixtures/models-and-pricing.yml \
  --output /tmp/model-pricing-v1.json \
  --source-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --generated-at 2026-09-04T00:00:00Z \
  --minimum-model-count 3

python3 Scripts/model_pricing_catalog.py validate \
  --input /tmp/model-pricing-v1.json \
  --minimum-model-count 3
```

To exercise the public source and production safety floor:

```sh
python3 Scripts/model_pricing_catalog.py fetch \
  --output /tmp/model-pricing-v1.json \
  --minimum-model-count 20
```

## GitHub Pages setup

The repository's Pages source must be **GitHub Actions**. The deploy job uses only
`pages: write` and `id-token: write`; the build job has read-only repository
access. No long-lived secret is required.
