from pathlib import Path


def _parse_key_values(text):
    values = {}
    for part in text.split(","):
        if ":" not in part:
            continue
        key, value = part.split(":", 1)
        values[key.strip()] = value.strip()
    return values


def _parse_entry(line):
    text = line.strip()
    if not text.startswith("- "):
        return None
    return _parse_key_values(text[2:])


def load_taxonomy_file(path):
    taxonomy = {
        "categories": [],
        "subcategories": {},
        "rules": {},
        "spells": {},
    }
    section = None
    current_category = None

    with Path(path).open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.rstrip()
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if not line.startswith(" ") and stripped.endswith(":"):
                section = stripped[:-1]
                current_category = None
                continue

            if section == "categories":
                entry = _parse_entry(line)
                if entry:
                    taxonomy["categories"].append({
                        "key": entry["key"],
                        "label": entry["label"],
                        "order": int(entry["order"]),
                    })
            elif section == "subcategories":
                if line.startswith("  ") and not line.startswith("    ") and stripped.endswith(":"):
                    current_category = stripped[:-1]
                    taxonomy["subcategories"].setdefault(current_category, [])
                else:
                    entry = _parse_entry(line)
                    if entry and current_category:
                        taxonomy["subcategories"].setdefault(current_category, []).append({
                            "key": entry["key"],
                            "label": entry["label"],
                            "order": int(entry["order"]),
                        })
            elif section == "rules":
                if line.startswith("  ") and not line.startswith("    ") and ":" in stripped:
                    hint, value = stripped.split(":", 1)
                    taxonomy["rules"][hint.strip()] = _parse_key_values(value)
            elif section == "spells":
                if line.startswith("  ") and not line.startswith("    ") and ":" in stripped:
                    spell_text, value = stripped.split(":", 1)
                    try:
                        spell_id = int(spell_text.strip())
                    except ValueError:
                        continue
                    taxonomy["spells"][spell_id] = _parse_key_values(value)

    return taxonomy


def load_taxonomies(root):
    root = Path(root)
    out = {}
    for path in sorted(root.glob("*.yaml")):
        out[path.stem] = load_taxonomy_file(path)
    return out


def derive_category(recipe, profession_key, taxonomies, diagnostics):
    taxonomy = taxonomies.get(profession_key, {})
    spell_id = int(recipe["spellId"])

    spell_rule = taxonomy.get("spells", {}).get(spell_id)
    if spell_rule:
        return (
            spell_rule.get("category"),
            spell_rule.get("subcategory") or None,
            int(spell_rule.get("sortOrder", 999)),
        )

    hint = recipe.get("categoryHint")
    rule = taxonomy.get("rules", {}).get(hint)
    if rule:
        return rule.get("category"), rule.get("subcategory") or None, int(rule.get("sortOrder", 999))

    diagnostics.setdefault("categoryFallbacks", []).append({
        "spellId": spell_id,
        "profession": profession_key,
        "hint": hint,
    })
    return "misc", None, 999


def categories_by_profession(taxonomies):
    return {
        profession: tuple(taxonomy.get("categories", ()))
        for profession, taxonomy in sorted(taxonomies.items())
    }


def subcategories_by_profession(taxonomies):
    return {
        profession: taxonomy.get("subcategories", {})
        for profession, taxonomy in sorted(taxonomies.items())
    }
