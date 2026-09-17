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
python tools/recipe-metadata/generate_recipe_metadata.py fetch --snapshot tbc-2.5.5 --source wowhead-specializations
python -m unittest discover -s tools/recipe-metadata/tests
```

`--source wowhead-specializations` writes `specializations.json` into the
snapshot: the specialization a recipe requires is enforced by the trainer
server-side, so it is absent from DB2 and cannot come from the Wago snapshot.
It reads one Wowhead profession listing per profession (nine requests, not one
per recipe), keeps only rows whose specialization belongs to that profession,
and refuses to overwrite the committed file if it parses nothing. The file is
deliberately separate from `secondary_static.json`, which a Wago refetch
rewrites wholesale.

`fetch` supports three maintainer-only modes. `--source-dir` imports an
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

## Where a recipe comes from

Every recipe in the dataset says where it is obtained. Four sources, in
precedence order:

| source | fetch | gives |
|---|---|---|
| Ackis Recipe List | `fetch --source arl-acquisition` | kind, faction, NPC names, zones |
| CraftLib removed list | `fetch --source removed-recipes` | recipes that are not in the game |
| hand-verified | `acquisition_worksheet.py apply` | one whole record, wins over ARL |
| `manual_overrides.yaml` | — | `removedBySpellId`, either direction |

ARL is the bulk source and the only one that resolves an NPC to a zone; the
emulator databases store spawn coordinates against a map, and turning those
into a zone name needs the client's terrain files. Read its five lookup files
carefully: they come in five different call shapes, and reading only the
first leaves three of them resolving nothing at all.

Kinds are `trainer`, `vendor`, `drop`, `quest`, `worldDrop`, `discovery` and
`worldEvent`. The last four point nowhere on purpose: a world drop has no
place to name, a discovery happens at your own workbench, and a world event
recipe is only there while the event runs. A recipe every trainer in the game
teaches names none of them, because naming the one whose id happened to
resolve, out of thirty-two, is worse than naming none.

## Filling the remaining gaps by hand

The bulk sources leave a residue: recipes with no source at all, and vendor or
creature drops where the kind is known but the place is not. `"Sold by
somebody somewhere"` is not an answer a player can act on, so both count as
gaps.

```powershell
python acquisition_worksheet.py emit          # what still needs an answer
python acquisition_worksheet.py open --band 1 # open the pages to read
python acquisition_worksheet.py fill          # or let the browser read them
python acquisition_worksheet.py apply
python generate_recipe_metadata.py generate
```

`emit` writes the sheet at `remediation/acquisition_worksheet.csv`, one row
per gap with the page to open in the last column, plus the same links as a
plain list under `artifacts/`. Fill `kind`, and where the page says so
`faction`, `names` and `zones`; names and zones hold several values separated
by a pipe. Everything else is context and is regenerated.

Rows are banded by how much the answer is worth, band 1 first: a TBC recipe
with a real skill requirement is what the Missing recipes tab exists to show,
while a vanilla recipe with no skill requirement is usually a discovery or a
quest reward. The sheet can be filled top-down and abandoned anywhere.

`emit` is safe to re-run: a filled row is never overwritten, and rows a later
refetch answers simply drop off the sheet. An empty sheet means there is
nothing left to answer.

`fill` opens the pages in a real browser -- see `recipe_sources/browser_bridge.py`
-- and reads the same listviews the item-page parser already knows, writing
what it finds into the sheet rather than straight into the data, so the
answers can be looked over first. A page with no source section leaves its row
empty: Wowhead not knowing is a real outcome, and often means the recipe was
never released.

`apply` writes `snapshots/tbc-2.5.5/acquisition_manual.json`, which the
secondary provider overlays on ARL -- whole record at a time, since a reading
of a page is one coherent answer and splicing half of it onto an automated
record would produce a row neither source ever stated. An unknown `kind` or
`faction` refuses the whole write rather than silently dropping the row.

## Recipes that are not in the game

Some recipes exist in the client data but were never implemented, or were
removed and never came back. No source will ever place them, and offering one
in the Missing recipes tab sends a player looking for a trainer who does not
exist.

They are flagged, never deleted. `fetch --source removed-recipes` writes
`snapshots/tbc-2.5.5/removed.json`, the record keeps a `removed = true` field,
and putting one back is one line in `manual_overrides.yaml`:

```yaml
removedBySpellId:
  12345: false   # actually obtainable
```

The list identifies a removed recipe by the absence of difficulty data on
Wowhead, which is a good signal but not a complete one -- a recipe cut in beta
can still carry that data. The override flags those in the other direction.
