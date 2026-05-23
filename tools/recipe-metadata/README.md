# Recipe Metadata Generator

Build-time tool for the `RecipeRegistry_Metadata` addon. Runtime addon code must not fetch network data.

The Phase 4 generator reads committed offline snapshots from
`tools/recipe-metadata/snapshots/tbc-2.5.4/`, applies RR-owned taxonomy files
from `remediation/taxonomy/`, emits the generated Lua data addon payload, and
writes coverage reports to `artifacts/recipe-metadata/`.

The committed snapshot is a minimal normalized DB2-derived fixture. It models
the fields used from `SkillLineAbility`, `Spell`, `SpellEffect`, and
`ItemSparse`; `secondary_static.json` supplies semantic gaps such as
outputless self-only flags.

```powershell
python tools/recipe-metadata/generate_recipe_metadata.py generate --flavor tbc --offline
python tools/recipe-metadata/generate_recipe_metadata.py generate --flavor tbc --offline --check
python tools/recipe-metadata/generate_recipe_metadata.py validate --flavor tbc --strict
python tools/recipe-metadata/generate_recipe_metadata.py report --flavor tbc
python -m unittest discover -s tools/recipe-metadata/tests
```

Phase 4 release gates:

- `generate --offline --check` must report the generated Lua and reports as current.
- `validate --strict` must finish with zero release-blocking unresolved records.
- `artifacts/recipe-metadata/coverage.md` must show 100% expansion,
  profession, and category coverage for every supported v1 profession.
- `artifacts/recipe-metadata/reagent-coverage.md` must show 100% reagent
  coverage for every normal craft record.
