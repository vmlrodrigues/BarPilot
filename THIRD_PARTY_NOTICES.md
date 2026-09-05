# Third-party notices

## GitHub Docs model-pricing data

BarPilot's model-pricing catalogue and built-in offline snapshot are derived from
the GitHub Docs model-pricing table:

- Source: [github/docs — models and pricing](https://github.com/github/docs/blob/main/data/tables/copilot/models-and-pricing.yml)
- Licence: [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)

BarPilot converts the source table to a versioned JSON contract, groups rows into
context tiers, normalises provider identifiers, removes Markdown footnote markers
from display names while retaining their identifiers, and relabels source
categories in the app for clarity.

Modified by BarPilot. BarPilot is independent and is not affiliated with or
endorsed by GitHub.

## LM Arena leaderboard data

BarPilot's community-preference ranks and built-in offline snapshot are derived
from the official LM Arena leaderboard dataset:

- Creator: [LM Arena](https://lmarena.ai/)
- Source: [lmarena-ai/leaderboard-dataset](https://huggingface.co/datasets/lmarena-ai/leaderboard-dataset)
- Licence: [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)

BarPilot selects the latest `overall` rows from the `text_style_control`
configuration, joins them to GitHub Copilot models through a manually reviewed
exact-name map, groups explicitly named reasoning modes, and presents the source
rank, rating interval, and vote count. BarPilot does not average or modify the
published scores. Models without an exact current match are left unranked.

Modified by BarPilot. BarPilot is independent and is not affiliated with or
endorsed by LM Arena.
