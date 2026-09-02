"""Hand-verified acquisition records.

ARL places 2098 of the 2150 recipes, and for 164 more it knows the recipe
exists but never says where it comes from. What is left after that is a
residue no bulk source reaches: Wowhead refuses automated fetches, and the
emulator databases carry no zone at all, only a map id. The remaining way to
answer is for a person to open the page and read it.

This is the file those readings land in. It is its own snapshot for the same
reason the others are -- its own cadence, and safe from a refetch rewriting a
shared file -- and it wins over every automated source, because a person
looked.

Record shape is the one ARL emits, so the two are interchangeable downstream:

    {"faction": "alliance", "kind": "vendor",
     "names": ["Vendor Name"], "zones": ["Zone Name"], "worldDrop": false}
"""

import json
from pathlib import Path


SNAPSHOT_FILENAME = "acquisition_manual.json"
PARSER_VERSION = 1

# The vocabulary normalize.summarize_source understands. A world drop is
# spelled as its own kind here even though the flag decides it downstream,
# because the person filling the sheet writes a kind, not a flag.
KINDS = ("trainer", "vendor", "drop", "quest", "worldDrop")
FACTIONS = ("both", "alliance", "horde")


def build_entry(kind, faction="both", names=(), zones=()):
    """One record, in the shape ARL emits.

    A world drop has nowhere to point at, so it carries neither names nor
    zones -- normalize drops them anyway, and keeping them in the snapshot
    would only invite the reader to trust something the addon never shows.
    """
    world_drop = kind == "worldDrop"
    return {
        "faction": faction or "both",
        "kind": kind,
        "names": [] if world_drop else [name for name in names if name],
        "zones": [] if world_drop else [zone for zone in zones if zone],
        "worldDrop": world_drop,
    }


def validate_entry(spell_id, entry):
    """Return a list of complaints; empty means the record is usable."""
    problems = []
    kind = entry.get("kind")
    if kind not in KINDS:
        problems.append("{0}: kind {1!r} is not one of {2}".format(
            spell_id, kind, ", ".join(KINDS)))
    faction = entry.get("faction", "both")
    if faction not in FACTIONS:
        problems.append("{0}: faction {1!r} is not one of {2}".format(
            spell_id, faction, ", ".join(FACTIONS)))
    if kind in ("vendor", "drop") and not entry.get("names"):
        # Not fatal: a vendor whose name the page does not give is still
        # better recorded as a vendor than left unknown.
        problems.append("{0}: {1} with no name (kept, but the row will "
                        "only say the kind)".format(spell_id, kind))
    return problems


def build_snapshot(by_spell_id):
    kinds = {}
    for entry in by_spell_id.values():
        kind = entry.get("kind") or "unknown"
        kinds[kind] = kinds.get(kind, 0) + 1
    return {
        "acquisitionBySpellId": {
            str(spell_id): entry for spell_id, entry in sorted(by_spell_id.items())
        },
        "parserVersion": PARSER_VERSION,
        "source": "hand-verified",
        "sourceStats": {
            "records": len(by_spell_id),
            "byKind": kinds,
        },
    }


def write_snapshot(payload, snapshot_dir):
    path = Path(snapshot_dir) / SNAPSHOT_FILENAME
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def load_manual_acquisition(snapshot_dir):
    """Read the committed snapshot; an absent file means "nothing verified by
    hand yet", not an error."""
    path = Path(snapshot_dir) / SNAPSHOT_FILENAME
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    return {
        int(spell_id): entry
        for spell_id, entry in data.get("acquisitionBySpellId", {}).items()
    }


def merge_acquisition(base, manual):
    """Overlay hand-verified records on an automated source, per recipe.

    Whole records replace whole records rather than merging field by field: a
    reading of the page is one coherent answer, and splicing a hand-read zone
    onto an automated kind would produce a row neither source ever stated.
    """
    merged = dict(base)
    merged.update(manual)
    return merged
