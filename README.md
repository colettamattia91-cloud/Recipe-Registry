# Recipe Registry

Recipe Registry is a guild-focused crafting directory for World of Warcraft: The Burning Crusade Classic Anniversary realms.

It quietly builds a shared view of your guild's professions, recipes, and crafter availability so you can stop guessing who can make what and start finding answers fast.

## What It Does

Recipe Registry scans your own professions locally, keeps that data protected, and gradually syncs profession knowledge across guildmates who also use the addon. The result is a searchable in-game registry of recipes, crafters, materials, and profession details, including supported TBC profession specializations.

It is designed to feel lightweight during normal play while still giving larger guilds a dependable long-term crafting directory.

## Core Features

### Shared guild recipe directory
- Builds a guild-wide crafting database from real player profession data
- Tracks recipes per character and profession instead of flattening everything into one noisy list
- Preserves online and offline crafter visibility so you can still find the right person later
- Syncs progressively in the background instead of trying to move everything at once
- Uses replica peers to help fill in offline guildmate data over time

### Profession-aware details
- Stores profession skill ranks alongside recipe ownership
- Tracks supported TBC profession specializations such as Alchemy, Blacksmithing, Tailoring, Leatherworking, and Engineering specializations
- Shows crafter specialization in relevant recipe and crafter views when available
- Protects complete local profession data from suspicious partial scans

### Searchable browser UI
- Fast searchable recipe list with profession tabs
- Rarity-aware crafted item presentation
- Favorites per character
- Detailed recipe panel with crafters, materials, item links, and output information
- Online crafters are surfaced first to reduce friction when you need something crafted now

### Crafting cost support
- Material cost estimates directly in the recipe detail panel
- Unit and total reagent price display
- Overall recipe cost summary when price data is available
- Graceful fallback when price sources are missing or incomplete

### Tooltip integration
- Adds known crafters to supported item, recipe, and spell or enchant tooltips
- Prefers online guildmates when possible
- Helps you spot available crafters directly from links, bags, and normal gameplay UI

### Chat and sharing quality-of-life
- Quick sharing of selected recipe details and materials to common chat channels
- Easy linking from the recipe detail view
- One-click whisper shortcut for online crafters

### Roster maintenance
- Includes local cleanup tools for ex-guild or stale members
- Hides stale data from normal browsing before any permanent pruning happens
- Uses safety checks so an incomplete roster snapshot does not accidentally wipe good data

### Background sync and performance safeguards
- Background jobs are chunked to reduce stutter
- Automatic sync work pauses in combat and instanced content
- Manifest and snapshot traffic are paced to avoid bursty behavior in larger guilds
- Dirty profession blocks are updated incrementally rather than rebuilding everything blindly

## Optional Integrations

### AtlasLoot
AtlasLoot improves local recipe resolution, especially for spell-based or enchant-style recipes, crafted outputs, and reagent metadata. The addon still works without it, but some recipe detail will be less rich.

### TradeSkillMaster and Auctionator
If market addons are available, Recipe Registry can estimate reagent and craft costs. TradeSkillMaster is checked first, with Auctionator used as a fallback.

## Compatibility

- Built for WoW TBC Anniversary / The Burning Crusade Classic 2.5.x
- Works as a standalone guild recipe addon
- Optional addons enhance pricing and recipe detail, but are not required for core sync and browsing

## Installation

### CurseForge App
Install Recipe Registry through CurseForge, then launch the game.

### Manual install
1. Download the release zip.
2. Extract it into `Interface/AddOns/`.
3. Make sure the folder name is `RecipeRegistry`.
4. Restart the game or reload the interface.

## First-Time Setup

1. Join a guild.
2. Open each of your profession windows at least once so your local data can be scanned.
3. Open the addon window from the minimap button or the addon's normal in-game entry point.
4. Give the guild sync a little time to exchange profession blocks with other users.
5. Refresh old roster data when needed through the addon's cleanup flow.

## Notes

- Item names and icons may appear gradually the first time WoW populates its local cache.
- Cost estimates depend on the quality and freshness of your available market data.
- The addon is intentionally conservative around incomplete profession data so that temporary API weirdness does not destroy a good local database.

## Support The Project

If Recipe Registry saves your guild time and you want to help keep it maintained, improved, and battle-tested, you can support development here:

[paypal.me/Kaedros](https://paypal.me/Kaedros)

Thank you. It genuinely helps.

## Feedback And Support

- Issues and feedback: [GitHub Issues](https://github.com/colettamattia91-cloud/Recipe-Registry/issues)
