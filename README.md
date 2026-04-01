# Recipe Registry

Recipe Registry is a guild-focused crafting directory for World of Warcraft TBC Anniversary.

Inspired by the original GuildCraft TBC workflow and adapted with a modern, lightweight sync model.

It scans your professions locally, syncs craft data with guildmates, and gives you a searchable list of who can craft what.

## Highlights
- Lightweight guild sync with owner-driven data transfer
- Searchable recipe directory with profession filters and rarity sorting
- Recipe detail panel with crafters, reagents, and estimated material cost
- Online crafter quick-request icon (one-click whisper template)
- Shift-click linking from recipe title and material rows
- Minimap button and options panel

## Compatibility
- Target game version: The Burning Crusade Classic (Anniversary / 2.5.x)
- Works without external pricing/data addons
- Optional integrations enhance detail and pricing (see below)

## Optional Integrations
### AtlasLoot (optional)
Used for richer local recipe resolution:
- spell mapping
- output item mapping
- reagent metadata

If AtlasLoot is missing, core sync and recipe ownership still work, but local recipe detail is reduced.

### TradeSkillMaster + Auctionator (optional)
Material pricing provider order:
1. TSM custom price sources (`dbmarket`, then `dbminbuyout`)
2. Auctionator fallback

If neither source has data, the material is marked as missing price.

## CurseForge Relations (Recommended)
When publishing on CurseForge, configure these project relations:

- AtlasLootClassic: Optional dependency
- TradeSkillMaster: Optional dependency
- Auctionator: Optional dependency

Fallback compatibility notes:
- AtlasLoot resolver supports AtlasLootClassic (primary) and AtlasLoot legacy global shape when present.
- Pricing resolution order is TSM (`dbmarket`, `dbminbuyout`) then Auctionator fallback.

## Main Features
### Guild recipe registry
- Scans your profession windows and stores learned recipe keys
- Syncs member snapshots directly from owners
- Maintains online/offline crafter visibility

### Modern directory UI
- Fast recipe list with search and profession tabs
- Rarity-aware item coloring
- Detailed recipe panel with:
	- crafter list
	- material list
	- unit and total material cost
	- overall cost estimate summary

### Chat and quality-of-life
- Shift-click recipe/material rows to insert links in chat
- Share selected recipe + materials to guild/party/raid/say
- Click online crafter request icon to send an English craft request whisper

## Commands
- `/rr` open or close the main window
- `/rr options` open Recipe Registry options panel
- `/rr mini` show or hide minimap button
- `/rr rescan` refresh local profession detection (then open profession windows)
- `/rr sync` show sync/comms status
- `/rr pull` request catch-up from known data owners
- `/rr prices <item name|item link>` check provider status and test item pricing
- `/rr share [guild|party|raid|say]` share selected recipe and materials
- `/rr atlas` show AtlasLoot resolver status
- `/rr r <recipeItemID>` inspect AtlasLoot recipe item mapping
- `/rr s <spellID>` inspect spell/enchant mapping
- `/rr i <createdItemID>` inspect created item mapping
- `/rr dump` print DB summary
- `/rr wipe` clear addon DB (keeps addon installed, resets data)

## Installation
### CurseForge App
Install Recipe Registry from CurseForge and launch the game.

### Manual
1. Download the release zip.
2. Extract into your `Interface/AddOns/` folder.
3. Ensure folder name is `RecipeRegistry`.
4. Restart WoW or `/reload`.

## First Use
1. Join a guild.
2. Open each profession window at least once to populate your local scans.
3. Use `/rr` to open the directory.
4. Wait briefly for guild sync handshakes to populate remote crafters.

## Performance Notes
- CPU and memory live polling is intentionally removed to avoid frame spikes.
- Search refresh is debounced to reduce UI recomputation.
- Sync/coordinator recompute is throttled to avoid unnecessary churn.

## Known Notes
- Data is independent from old GuildCrafts databases.
- If item info is uncached, names/icons may resolve after a short delay.
- Pricing quality depends on available market sources and cache state.

## Feedback
If you publish on CurseForge, add your Issue Tracker link here so users can report bugs and request features.

## CurseForge Metadata Template
Use this block when creating or updating your CurseForge project page.

- Project name: Recipe Registry
- Game version: The Burning Crusade Classic (2.5.x)
- Primary category: Professions
- Secondary categories: Guild, Auction & Economy
- Summary (short): Guild crafting directory with synced profession data, material pricing, and crafter contact tools.
- Project URL: <your-curseforge-project-url>
- Source URL: <your-repository-url>
- Issue tracker URL: <your-issue-tracker-url>
- License: <your-license>
- Relations:
	- AtlasLootClassic (optional dependency)
	- TradeSkillMaster (optional dependency)
	- Auctionator (optional dependency)

### Suggested CurseForge Description Snippet
Recipe Registry is a guild-focused crafting directory for TBC Anniversary. It scans profession data locally, syncs crafts between guild members, shows who can craft each recipe, estimates material costs with optional TSM/Auctionator integration, and lets you quickly contact online crafters.

## Release Checklist
- Update `RecipeRegistry.toc` version
- Update changelog in `CHANGELOG.md`
- Verify slash commands and options panel
- Test recipe scan and guild sync on at least two characters
- Test optional integrations: AtlasLoot, TSM, Auctionator
- Package zip with top-level folder `RecipeRegistry`
