# Recipe Metadata Generator

Build-time tool for the `RecipeRegistry` metadata library (folded into the RR addon under `Data/Metadata/`). Runtime addon code must not fetch network data.

The Phase 4 generator reads committed offline snapshots from
`tools/recipe-metadata/snapshots/tbc-2.5.5/`, applies RR-owned taxonomy files
from `remediation/taxonomy/`, emits the generated Lua payload to
`Data/Metadata/RecipeMetadata_Generated.lua`, and writes coverage reports to
`artifacts/recipe-metadata/`.

The committed snapshot is a normalized Wago Tools DB2 release-candidate dataset
for Classic Anniversary TBC `2.5.5`. It contains every supported Vanilla and TBC
recipe currently emitted by the source importer, not only recipes newly
introduced in TBC; `secondary_static.json` supplies semantic gaps such as
outputless self-only flags.

```powershell
python tools/recipe-metadata/generate_recipe_metadata.py generate --flavor tbc --offline
python tools/recipe-metadata/generate_recipe_metadata.py generate --flavor tbc --offline --check
python tools/recipe-metadata/generate_recipe_metadata.py validate --flavor tbc --strict
python tools/recipe-metadata/generate_recipe_metadata.py report --flavor tbc
python tools/recipe-metadata/generate_recipe_metadata.py fetch --snapshot tbc-2.5.5 --source-dir C:\path\to\normalized-snapshot
python tools/recipe-metadata/generate_recipe_metadata.py fetch --snapshot tbc-2.5.5 --source wago-anniversary
python -m unittest discover -s tools/recipe-metadata/tests
```

`fetch` supports two maintainer-only modes. `--source-dir` imports an
already-normalized snapshot bundle and validates it before copying it into
`snapshots/`. `--source wago-anniversary` refreshes the normalized bundle from
Wago Tools DB2 using `product=wow_anniversary`; it reads `SkillLineAbility`,
`SpellEffect`, `SpellReagents`, `ItemEffect`, `ItemSparse`, and `SpellName`.
It also reads Vanilla `SkillLineAbility` from `--vanilla-build` and classifies
recipes as `vanilla` when their spell exists in that baseline; all remaining
supported recipes are `tbc`. Recipe candidates are supported-profession rows
with a create-item effect, plus enchanting outputless enchant rows with reagent
data.

Phase 4 release gates:

- `generate --offline --check` must report the generated Lua and reports as current.
- `validate --strict` must finish with zero release-blocking unresolved records.
- `artifacts/recipe-metadata/coverage.md` must show 100% expansion,
  profession, category, and expected-record coverage for every supported v1
  profession. Expected counts must be declared by profession, by expansion
  (`vanilla`, `tbc`), and by profession/expansion pair.
- `artifacts/recipe-metadata/reagent-coverage.md` must show 100% reagent
  coverage for every normal craft record.

Release-candidate manifests must declare expected recipe denominators in this
shape:

```json
{
  "datasetKind": "release-candidate",
  "expectedRecipeCounts": {
    "total": 0,
    "byProfession": {
      "alchemy": 0
    },
    "byExpansion": {
      "vanilla": 0,
      "tbc": 0
    },
    "byProfessionExpansion": {
      "alchemy": {
        "vanilla": 0,
        "tbc": 0
      }
    }
  }
}
```
