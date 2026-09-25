# Changelog

All notable changes to this addon are documented in this file.

## [Unreleased]

### Fixed

- **The favourites star is back.** It was looked up in the folder of the TBC
  addon, which a Forever install does not have, so it showed nowhere.

### Added

- **`/rr debug textures`** lists any game texture the addon uses that this
  client does not have -- a check worth running after a new beta build.

## [0.1.0] - 2026-09-25

The first release of Recipe Registry for WoW: Forever.

### Added

- **A recipe directory for the whole guild.** Search any recipe and see which of
  your guildmates can make it, without asking in chat. Everyone running the
  addon shares what their characters know, so the directory fills itself in and
  keeps up as people learn things.
- **Your professions are read and shared on their own.** Open a profession once
  and it is recorded. You never have to press a button to publish anything.
- **A recipe you learn appears by itself.** Learn a pattern in a dungeon and it
  is in the directory within seconds, wherever you are -- there is no need to go
  back to town and open the profession window for it to count.
- **All twelve professions, gathering ones included.** Alchemy, Blacksmithing,
  Cooking, Enchanting, Engineering, First Aid, Fishing, Herbalism,
  Leatherworking, Mining, Skinning and Tailoring. Fishing, Herbalism and
  Skinning have recipes of their own on this game, so they get a tab like
  everything else instead of being treated as professions with nothing in them.
- **A recipe database for this game's content.** 2519 recipes with their
  materials, what they produce, the skill level they are learned at and the
  point where they stop giving skill-ups. It is built from the game itself, so
  recipes added by a patch are in it rather than missing until someone updates
  the addon.
- **A Collection tab: your own professions' book.** Every recipe your
  professions can learn, with the ones you already know ticked off and the rest
  showing the skill they ask for against the skill you have. Each profession is
  a section you can fold away, headed with how far along you are.
- **Where to learn it.** The Collection tells you who teaches or sells each
  recipe, or where it drops -- with the zone, the map coordinates in a column of
  their own, and an Alliance or Horde mark on vendors only one side can reach.
  The Merchant's Favor quartermasters of both factions are in it.
- **Sort and filter the Collection by any column.** Left-click a header to sort
  by it, right-click to narrow the table: what you can learn today, what is
  still out of reach, only vendor recipes, only the ones needing a
  specialization.
- **Three ways to order the recipe list.** Alphabetical, by rarity, or by the
  skill level a recipe is learned at, lowest first.
- **Recipe details in one panel.** What it makes, what it takes, and every
  guildmate who can craft it, so you know who to whisper.
- **Crafters on item tooltips.** Hovering an item you cannot make says who in
  the guild can, in the tooltip, without opening the addon.
- **What a craft is worth.** With TradeSkillMaster or Auctionator installed, the
  details panel adds what the materials cost, what the result sells for and what
  is left over, and a switch keeps only the crafts that come out ahead.
- **Favourites.** Star the recipes you keep coming back to; they gather at the
  top of the profession list, above Alchemy.
- **A Guild members tab.** Who else is running the addon, and which version, so
  you can tell an out-of-date guildmate from one who simply has not installed it.
- **Stays out of the way when it matters.** The addon stops talking to other
  players while you are in an instance and picks up again when you leave.
- **A minimap button and `/rr`**, either of which opens the window.

### Known limitations

- **Where-to-learn data is partial.** Forever does not ship it in the game
  files, so it is being collected by hand, a vendor and a trainer at a time. Some
  recipes have no source yet, some have no coordinates, and a few entries may be
  wrong. The Collection says so at the top.
- **Some recipes have no skill level.** Where neither the recipe item nor the
  original game says what level a recipe is learned at, the column shows a dash
  instead of guessing.
