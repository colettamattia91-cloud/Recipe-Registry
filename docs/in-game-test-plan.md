# In-game test plan — the unreleased round

Everything in `CHANGELOG.md` under `[Unreleased]`, with what has actually been
seen in the client and what has not. The last release was **2.2.2**; this round
is 36 commits on `develop` and nothing in it has shipped.

Written 2026-09-06, after the trainer-title work.

## How to read the status

| | meaning |
|---|---|
| **NEW** | never opened in the client. Built and unit-tested only. |
| **REFIX** | you saw it, it was wrong, it was fixed. The fix has not been seen. |
| **OK** | you exercised it and did not report a problem. |
| **?** | probably crossed during an earlier pass, never explicitly confirmed. |

A unit test proving a label is built is not the same as a person reading it at
1440p with a real character's professions. Everything below is the second kind.

## Running a pass

```powershell
.\local-tests\deploy-to-wow.ps1          # -Channel dev to isolate from the guild
```

`/reload` after every deploy — always, the files are read at load.

Live SavedVariables, useful when a row looks wrong and you want to know whether
the data or the drawing is at fault:
`WTF/Account/119811045#1/SavedVariables/RecipeRegistry.lua`

---

## 1. Never opened in the client

The whole of this section is new since your last pass. Highest value per minute.

### Guild members table — **NEW**

The table was rebuilt on the Collection's terms. None of it has been seen.

- [ ] Headers carry the **column name only** — no `[F]`, no `Version: Unknown`
      written into a 92px column.
- [ ] A column that is filtering shows its name **in gold**.
- [ ] Right-click **Addon**, **Presence**, **Version**: a menu opens with the
      choices written out and the one in force ticked.
- [ ] Left-click the same header three times: ascending, descending, then back
      to the built order (by name).
- [ ] **Last seen** opens on the most recent, not the oldest, and still gets
      back to the built order on the third click.
- [ ] Strip control top-right says **"Everyone"**, and **"Everyone (filtered)"**
      when a column — not the control — is narrowing the table.
- [ ] That control's menu holds Presence and **"Clear every filter"**, greyed
      out when nothing is set.
- [ ] The **"Guild members"** title does not run under the new control.

### Phase column — **NEW**

- [ ] Sixth column on the far right of the Collection, blank on almost
      everything, amber `P2`/`P3`/`P5` where it applies.
- [ ] Sort by it: base content first, then P2 → P5.
- [ ] Right-click it: **From the start**, **Any later phase**, and the
      individual phases.
- [x] Spot-check that the numbers are right — done 2026-09-06, and it found
      the boundary. Engineering has 13, **all P5**, and eleven of them are the
      Sunwell goggles, which are class-gated: your character sees its own pair
      and the two potion injectors, so the column looks empty from engineering
      alone. Filter by "Any later phase" across all professions to see the
      whole set of 129.

> **What the column can and cannot say.** The phase comes from two sources.
> AtlasLoot Classic marks eight of its TBC tables with `ContentPhaseBC`, and
> every item in one inherits it — that catches a vendor who arrives with a later
> phase even where he stands in a launch city, which reading the zone cannot.
> Where AtlasLoot is silent, the zone the recipe comes from answers instead.
> The two agree on all 76 recipes both have an opinion about.
>
> What neither reaches: a launch-zone recipe Blizzard held back that appears in
> no curated table — Adamantite Arrow Maker drops from Sunfury Archers in
> Netherstorm, and no client data or emulator database records a release
> schedule. **Closed as not worth chasing**; `phaseBySpellId` in the overrides
> is there if a case turns out to matter.

### Trainer titles — **NEW**

- [ ] Surestrike Goggles v2.0 reads **"Master Engineering Trainer (Outland)"**,
      not "From a trainer".
- [ ] A vanilla recipe several ranks teach still reads **"From a trainer"**.
- [ ] A specialization recipe still names its trainer:
      `Trainer: Tinkmaster Overspark (Ironforge), Oglethorpe Obnoticus (…)`.
- [ ] **144 recipes** carry a title. Worth sorting the Collection by
      "Learned from" to read them in a block and catch a wrong one.
- [ ] Nothing reads "Any trainer" anywhere.

> cmangos reconstructs 2.4.3 and we run 2.5.x, so this is the one item where a
> wrong answer is plausible rather than surprising. If a title looks wrong,
> that is data worth reporting, not a drawing bug.

### Class gate — **NEW**

- [ ] Your engineer sees the goggles for **your** class and not the others.
      22 recipes, all the TBC goggles line.
- [ ] Engineering does not lose anything else — it should stay in the hundreds.
- [ ] A goggle you already know stays in the book whatever your class.
- [ ] Hovering one says **"Taught only to Hunter, Shaman"** (or your pair).

### Specialization is not a hole — **NEW**

- [ ] With **Not learned**, the Gnomish schematics drop out for a Goblin
      engineer (and vice versa).
- [ ] They are still there under **All**.
- [ ] The profession header still counts the whole book — `Engineering (x/y)`
      is deliberately unchanged. **Say if you wanted that to move too.**

---

## 2. You saw it, it was fixed, the fix has not been seen

### The crash — **REFIX**

- [ ] Clicking the Collection filter control does not throw
      `attempt to index global 'COLLECTION_FILTER_LABELS'`.

### Menus — **REFIX**

- [ ] Open the Collection filter menu, switch tab without closing it: it goes
      away instead of floating over the new tab.
- [ ] Same with the sidebar profession buttons.
- [ ] With a profession set to its own expansion, the menu's note
      *"Some professions are set on their own, in the options."* wraps **inside**
      the frame.

### Expansion filter moved — **REFIX**

- [ ] The Recipes sidebar has **one** control, reading "Every craft" /
      "Profitable crafts only". No expansion control there.
- [ ] Expansions are chosen from the **Collection** strip control.
- [ ] The banner over the recipe list still appears when an expansion is
      holding recipes back from the profession you are on.
- [ ] The Collection control's tooltip lists professions set on their own.

### Search and window — **REFIX**

- [ ] The **X** on the Collection search clears the Collection's search.
- [ ] Click bags, then the addon window, then bags: whichever you clicked last
      is in front. **If the bags are always in front, say so — it is one line
      back to the previous layer.**

---

## 3. Exercised in an earlier pass

Two in-game passes on 2026-09-03/04 produced 19 findings; 18 were closed. These
were seen, but everything they touch has been edited since.

- [ ] Collection columns, row heights, the stacked source lines. — **OK**
- [ ] Difficulty colours against the recipe's own four thresholds. — **OK**
- [ ] The Skill column (10 recipes out of 2151 still have no number). — **OK**
- [ ] Options panel in five pages — the heights are **estimates**, they may
      still need a nudge. — **?**
- [ ] The collapse arrows use Blizzard's plus/minus art. Confirm you are happy
      with them; you had asked for "una freccetta". — **?**
- [ ] Cogspinner Goggles: two vendors in the detail, one in the Collection.
      Almost certainly the wrap bug, should be gone. — **REFIX**

## 4. Never confirmed, from the round before

Built 2026-08-31, never explicitly reported on. They may have been crossed
during the Collection passes without being looked at.

- [ ] Central recipe list scrollbar is back (it went missing in 2.2.2). — **?**
- [ ] Craft value / profit block on the details panel, three figures in a
      money column. — **?**
- [ ] Profit is green or red and says "upper bound" when a reagent has no
      price. — **?**
- [ ] "Profitable crafts only" actually narrows the browser, and unpriceable
      recipes stay visible marked "no price data". — **?**
- [ ] Vendor prices: open a merchant, then check that a vial-heavy alchemy
      craft prices sensibly. — **?**
- [ ] The auction-house-cut option changes the profit figure. — **?**
- [ ] Tabs can be switched off in the options; Recipes cannot. — **?**
- [ ] "Where to learn" block on the details panel for browser recipes. — **?**
- [ ] Map positions in the Collection row tooltip. — **?**
- [ ] Materials list is one line per reagent, not two. — **?**

---

## 5. Open questions

**#16, from the first pass, still unanswered.** You said "il tooltip degli item
nel mondo". `Tooltip.lua` has never had a "where to learn" block — it adds the
Recipe Registry header, the crafter count and the crafters. Did you mean
*adding* "where to learn" to the game tooltip, or were you talking about the
Collection's row tooltip? Nothing has been removed pending your answer.

**Item-level restrictions, offered and declined.** `AllowableClass` on 14
crafted items (Wolfshead Helm is druid-only to wear) and `RequiredSkill` to
equip on 195 (the goggles need Engineering 350 to wear). Both sit in a table
the pipeline already downloads. You said not to bother while the recipe itself
is learnable by everyone — noted, not built.

**The profession header count — settled 2026-09-06, leaving it as it is.**
`Engineering (185/385)` counts the whole book. Dropping the out-of-reach
recipes from the denominator would make the target move: `185/220` today
growing to `185/385` as the profession levels, and a progress bar whose goal
recedes while you advance is worse than one that is simply far off. Those are
holes that close on their own.

What can genuinely never be yours is already out of the count: class-gated
recipes are not built as rows at all, nor are the ones removed from the game,
nor anything under a hidden expansion. The denominator is already "how much of
this book could be mine", not "how many recipes exist".

The one arguable case is the specialization, which levelling does not close --
but a specialization can be changed, so it is not unreachable the way a class
is. Hence out of "Not learned" and still in the total. One line to revisit.
