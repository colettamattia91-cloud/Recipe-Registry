# Changelog

All notable changes to this addon are documented in this file.

This is the World of Warcraft: Forever addon. It shares content with the TBC
Classic one and no code: Forever is vanilla content behind a retail-shaped API,
so the two are separate addons with separate folders, separate packages and
separate histories.

## [Unreleased]

Nothing has shipped yet. The entries below are what the first release will say
once the adaptation has been run on a live client; the heading gets a version
and a date at that point, not before.

### Added

- **A recipe database built from the client itself.** Twelve professions, 2519
  recipes with their reagents, created items and categories, collected from a
  live session and cross-checked against datamining profession by profession.
  Where the two disagree the client wins, because it knows what a patch added
  yesterday; datamining fills the fields the client does not expose per recipe,
  which are the skill a recipe takes, its difficulty thresholds, the classes it
  is taught to, and whether it comes from vanilla or is an addition of Forever.
- **Fishing, Herbalism and Skinning are tracked professions.** On Forever the
  gathering professions have recipes of their own -- the camping system gives
  some to all three -- so they are in the directory like any other.
- **A recipe you learn registers itself.** Learning a recipe fires an event
  carrying its id, and on this client that is enough: the profession, what it
  creates and whether you really know it can all be answered for any recipe id,
  including one belonging to a profession the character does not have. So a
  recipe learned in a dungeon reaches the database and the sync from there,
  without opening anything.

### Removed

- **Jewelcrafting.** It is a TBC profession and does not exist on this client.
- **The expansion filter.** It divided a collection that on this client is one
  body of content, so it is gone from the options, from the browser and from the
  shape of the recipe database.

### Known limits

- The tooltip that names a recipe's crafters has not been confirmed to attach on
  this client; see `docs/forever/api-adaptation.md` for the one-line probe that
  settles it.
- The sync has never run between two Forever clients. Its API surface has been
  checked and needs no adaptation, but that is not the same as having seen it
  work.
