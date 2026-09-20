from recipe_pipeline.records import ReagentRecord


def derive_reagents(spell_id, primary, secondary=None):
    rows = primary.get("reagentsBySpellId", {}).get(int(spell_id), ())
    return tuple(
        ReagentRecord(int(row["itemId"]), int(row["count"]))
        for row in sorted(rows, key=lambda item: (int(item["itemId"]), int(item["count"])))
    )
