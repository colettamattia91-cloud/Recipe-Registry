"""When a TBC recipe becomes obtainable, as a content phase.

No bulk source carries this. It is not client data at all: a phase is a
release-schedule decision, and the client ships every phase's data from the
first day. What the client and AckisRecipeList do give us is the ZONE each
recipe is obtained in, and the raid and zone gating is exactly what a phase
is -- Serpentshrine Cavern opens in phase 2 whatever its data says on day one.
So the mapping below is the published Burning Crusade schedule, twelve rows,
applied to zone names we already extract.

Two rules keep it honest:

* A recipe is late only when EVERY place it comes from is late. One sold by a
  Shattrath vendor and also dropped in Black Temple is available on day one,
  so the phase is the minimum over its places, not the maximum.
* A place we cannot date is base content. Absence of evidence is not a later
  phase, and a world drop -- which has no place at all -- has always dropped.

The second rule has a blind spot this module cannot close: a vendor added in a
later patch who stands in a launch zone. Ontuvo sells jewelcrafting designs
from Shattrath City, which existed on day one, but he is a Shattered Sun
vendor and arrives with the Isle. Reading his zone says base content, and it
is wrong. That case is answered by atlasloot_phase_provider, which classifies
the item rather than the place and is consulted BEFORE this module -- see
normalize. What neither answers is a launch-zone recipe held back that appears
in no curated table at all; that is what the phaseBySpellId override is for.
"""

BASE_PHASE = 1

# Cross-checked against AtlasLoot Classic on 2026-09-06, which carries a
# `ContentPhaseBC` on its instance tables. Seven instances, and all seven agree
# with the values below: Serpentshrine Cavern 2, Tempest Keep 2, Hyjal Summit 3,
# Black Temple 3, Zul'Aman 4, Magisters' Terrace 5, Sunwell Plateau 5. Its
# item-level table -- ContentPhase:GetForItemID, which is where a per-item gate
# would live -- is EMPTY for Burning Crusade and for Classic; only Wrath was
# ever filled in, because AtlasLoot treats TBC as fully released
# (ACTIVE_PASE_LIST[BC] = 6). So it confirms this table and adds nothing to it.
#
# Zone -> the phase that opened it. Only zones that are NOT available at
# launch appear: everything else is base content by the rule above.
PHASE_BY_ZONE = {
    # 2.1 -- The Serpentshrine Cavern and Tempest Keep raids.
    "Serpentshrine Cavern": 2,
    "The Eye": 2,
    "Tempest Keep": 2,
    # 2.2 -- The Battle for Mount Hyjal and the Black Temple.
    "Hyjal Summit": 3,
    "The Battle for Mount Hyjal": 3,
    "Black Temple": 3,
    # 2.3 -- Zul'Aman.
    "Zul'Aman": 4,
    # 2.4 -- the Sunwell, its island and its five-man.
    "Sunwell Plateau": 5,
    "Isle of Quel'Danas": 5,
    "Magisters' Terrace": 5,
    "Magister's Terrace": 5,
    "Quel'Danas": 5,
}


def derive_phase(expansion, source_places, world_drop=False):
    """The phase a recipe can first be obtained in, or None when it is base.

    None rather than 1 is deliberate: the overwhelming majority of records are
    base content, and a field written on every one of them is bloat in a
    generated file the client parses at load. Absent means "from the start".
    """
    if expansion != "tbc":
        # A vanilla recipe predates the phases entirely.
        return None
    if world_drop or not source_places:
        return None

    phase = None
    for place in source_places:
        zone = getattr(place, "zone", None) or (place.get("zone") if hasattr(place, "get") else None)
        place_phase = PHASE_BY_ZONE.get(zone, BASE_PHASE) if zone else BASE_PHASE
        if place_phase == BASE_PHASE:
            # One place available at launch settles it for the whole recipe.
            return None
        phase = place_phase if phase is None else min(phase, place_phase)
    return phase
