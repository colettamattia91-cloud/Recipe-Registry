# Recipe Metadata Generator

Build-time tool for the `RecipeRegistry_Metadata` addon. Runtime addon code must not fetch network data.

The Phase 4 generator reads committed offline snapshots from
`tools/recipe-metadata/snapshots/tbc-2.5.5/`, applies RR-owned taxonomy files
from `remediation/taxonomy/`, emits the generated Lua data addon payload, and
writes coverage reports to `artifacts/recipe-metadata/`.

The committed snapshot is currently a minimal normalized DB2-derived fixture. It models
the fields used from `SkillLineAbility`, `Spell`, `SpellEffect`, and
`ItemSparse`; `secondary_static.json` supplies semantic gaps such as
outputless self-only flags. The release-candidate snapshot for TBC `2.5.5`
must contain every supported Vanilla and TBC recipe, not only recipes newly
introduced in TBC.

```powershell
python tools/recipe-metadata/generate_recipe_metadata.py generate --flavor tbc --offline
python tools/recipe-metadata/generate_recipe_metadata.py generate --flavor tbc --offline --check
python tools/recipe-metadata/generate_recipe_metadata.py validate --flavor tbc --strict
python tools/recipe-metadata/generate_recipe_metadata.py report --flavor tbc
python tools/recipe-metadata/generate_recipe_metadata.py fetch --snapshot tbc-2.5.5 --source-dir C:\path\to\normalized-snapshot
python -m unittest discover -s tools/recipe-metadata/tests
```

Phase 4 release gates:

- `generate --offline --check` must report the generated Lua and reports as current.
- `validate --strict` must finish with zero release-blocking unresolved records. It is expected to fail while the committed snapshot is marked `datasetKind: fixture`.
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
