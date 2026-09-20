# Source Gap Audit

Provider: wago.tools-db2
Expansion rule: spell present in Vanilla SkillLineAbility build 1.15.7.61582 => vanilla; otherwise tbc
Recipe item policy: primary recipeItemId comes from DB2 ItemEffect ParentItemID; alternate teaching sources are intentionally not modeled
Created item policy: createdItemId comes from DB2 SpellEffect Effect=24 EffectItemType

| Check | Value |
|---|---:|
| Late-Vanilla recipes from baseline diff | 64 |
| Duplicate SkillLineAbility recipe rows skipped | 1 |

## Late-Vanilla Spell IDs

25659, 25704, 25954, 26011, 26085, 26086, 26087, 26277, 26279, 26403, 26407, 26416, 26417, 26418, 26420, 26421, 26422, 26423, 26424, 26425, 26426, 26427, 26428, 26442, 26443, 27585, 27586, 27587, 27588, 27589, 27590, 27658, 27659, 27660, 27724, 27725, 27829, 27830, 27832, 27837, 28205, 28207, 28208, 28209, 28210, 28219, 28220, 28221, 28222, 28223, 28224, 28242, 28243, 28244, 28327, 28461, 28462, 28463, 28472, 28473, 28474, 28480, 28481, 28482

