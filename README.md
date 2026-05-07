# Recipe Registry

Recipe Registry turns your guild into a proper crafting network for World of Warcraft: The Burning Crusade Classic Anniversary realms.

Instead of asking in chat who can craft an item, who has the right specialization, or who is online right now, you get a clean in-game directory that keeps up with your guild over time.

Recipe Registry scans your own professions locally, syncs profession knowledge with guildmates who use the addon, and builds a searchable registry of recipes, crafters, materials, skill ranks, and supported TBC profession specializations.

It is built to be useful every day, not just impressive on paper: fast to browse, easy to understand, and gentle enough to run quietly in the background.

## Why Players Install It

- Find the right crafter in seconds instead of asking in guild chat over and over
- See who is online now and who can help later when they log back in
- Keep profession data organized by character and profession, not buried in chat history
- Surface supported profession specializations where they actually matter
- Give your guild a shared long-term memory for crafting without turning gameplay into menu work

## What You Get

### A real guild crafting directory
- Builds a shared guild database from real profession data
- Keeps recipes grouped by character and profession for cleaner browsing
- Preserves visibility for both online and offline crafters
- Uses progressive background sync instead of trying to flood everyone at once
- Lets replica peers help fill in offline guildmate data over time

### Better recipe discovery
- Fast searchable recipe browser with profession tabs
- Favorites per character
- Rarity-aware crafted item presentation
- Detailed recipe view with output info, crafter list, and materials
- Online crafters shown first when you need a craft right away

### Crafter context that actually helps
- Tracks profession skill ranks alongside recipe ownership
- Tracks supported TBC profession specializations including Alchemy, Blacksmithing, Tailoring, Leatherworking, and Engineering specializations
- Shows specialization in relevant crafter and recipe views when available
- Helps you identify not just who can craft something, but who has the right version of that profession

### Cost and material visibility
- Material cost estimates in the recipe detail panel
- Unit and total reagent price display
- Overall recipe cost summary when price data is available
- Clean fallback behavior when pricing sources are missing

### Tooltip and chat quality-of-life
- Adds known crafters to supported item, recipe, and spell or enchant tooltips
- Makes guild crafting knowledge visible directly from normal gameplay
- Supports easy recipe sharing and quick crafter contact flows

### Safe long-term guild data
- Protects complete local data from suspicious partial profession scans
- Hides stale ex-guild data from normal browsing before pruning it later
- Uses safety checks to avoid destructive cleanup when roster data looks incomplete
- Keeps sync work paced and chunked to reduce noise and avoid bursty behavior in larger guilds

## Built For TBC Guild Life

Recipe Registry is especially nice in guilds where:

- multiple players cover the same profession with different specializations
- crafting requests happen often enough that chat becomes repetitive
- people play on different schedules and many useful crafters are offline when needed
- you want a practical replacement for "does anyone know who can make this?"

## Optional Integrations

### AtlasLoot
AtlasLoot improves local recipe resolution, especially for spell-based or enchant-style recipes, crafted outputs, and reagent metadata. Recipe Registry works without it, but some recipe detail will be less rich.

### TradeSkillMaster and Auctionator
If market addons are available, Recipe Registry can estimate reagent and craft costs. TradeSkillMaster is checked first, with Auctionator used as a fallback.

## Compatibility

- Built for WoW TBC Anniversary / The Burning Crusade Classic 2.5.x
- Works perfectly well as a standalone guild recipe addon
- Optional addons enhance pricing and recipe detail, but are not required for core sync and browsing

## Installation

### CurseForge App
Install Recipe Registry through CurseForge, then launch the game.

### Manual install
1. Download the release zip.
2. Extract it into `Interface/AddOns/`.
3. Make sure the folder name is `RecipeRegistry`.
4. Restart the game or reload the interface.

## Getting Started

1. Join a guild.
2. Open each of your profession windows at least once so your local data can be scanned.
3. Open the addon window from the minimap button or the addon's normal in-game entry point.
4. Give the guild sync a little time to exchange profession blocks with other users.
5. Browse recipes, mark favorites, and refresh old roster data whenever needed through the addon's cleanup flow.

## Notes

- Item names and icons may appear gradually the first time WoW populates its local cache.
- Cost estimates depend on the quality and freshness of your available market data.
- The addon is intentionally conservative around incomplete profession data so that temporary API weirdness does not destroy a good local database.

## Support The Project

If Recipe Registry makes guild crafting smoother for you and your friends, and you want to help keep it maintained and improved, you can support development here:

[paypal.me/Kaedros](https://paypal.me/Kaedros)

Thank you. It genuinely helps keep the project alive.

## Feedback And Support

- Issues and feedback: [GitHub Issues](https://github.com/colettamattia91-cloud/Recipe-Registry/issues)
