# Recipe Registry

Turn your guild professions into a searchable crafting network for World of Warcraft: The Burning Crusade Classic Anniversary realms.

Recipe Registry answers the question every guild eventually asks: "Who can make this?"

Open your professions, let the addon scan what you know, and Recipe Registry quietly builds a shared in-game directory with your guildmates. Recipes, crafters, materials, profession ranks, specializations, favorites, online status, and optional price estimates all live in one clean window instead of scattered across guild chat.

It is designed for everyday guild life: fast to browse, calm in the background, and useful even when the best crafter is offline right now.

## Why Players Install It

- Find the right crafter without repeating the same question in guild chat
- See who is online now and who can help later when they log back in
- Search recipes by name or by materials, depending on how you think
- Keep favorites per character for the crafts you ask about most often
- Spot important TBC specializations such as Transmute Master, Armorsmith, Spellfire Tailor, Dragonscale Leatherworker, and more
- Estimate material costs when TradeSkillMaster or Auctionator data is available
- Give your guild a long-term crafting memory that updates quietly over time

## Feature Highlights

### Guild Crafting Directory

- Builds a shared recipe registry from real profession data
- Tracks recipes by character, profession, rank, and specialization
- Shows online crafters first while keeping offline crafters available for later
- Keeps guild data useful across reloads, relogs, and addon updates
- Works best when multiple guildmates install it, but remains useful as your own personal profession browser

### Fast Recipe Browser

- Profession tabs for quick browsing
- Favorites tab for your most-used crafts
- Search by recipe name or by required materials
- Sort recipes alphabetically or by item rarity
- AtlasLoot categories when AtlasLoot data is available
- Smooth scrolling and searching, even with large guild recipe lists

### Craft Requests And Sharing

- Use the Ask button to whisper a crafter directly from the recipe view
- Share the selected recipe to guild, party, raid, or say
- See known crafters directly on supported item, recipe, spell, and enchant tooltips
- Keep online and offline crafter lists readable instead of hunting through chat history

### Materials And Costs

- View crafted output, reagents, known crafters, and total materials in one place
- See reagent unit prices and total recipe cost when market data is available
- Uses TradeSkillMaster first, with Auctionator as a fallback
- Handles missing prices gracefully so the recipe view still stays useful

### Quiet Background Sync

- Shares guild recipe data automatically with compatible guildmates
- Paces larger updates so the addon stays responsive
- Waits for safer moments around login, reloads, combat, instances, and roster loading
- Keeps normal chat output quiet, with extra diagnostics available only when you need troubleshooting

## Built For TBC Guild Life

Recipe Registry is especially helpful when:

- Your guild has several crafters covering the same profession
- Specializations matter and the "right" crafter is not always obvious
- Players are online at different times
- Officers or raid leaders often need to find enchants, resist gear, consumables, or crafted upgrades quickly
- You want a practical answer to "who can make this?" without maintaining a spreadsheet

## Getting Started

1. Install Recipe Registry.
2. Join a guild.
3. Open each of your profession windows at least once so your recipes can be scanned.
4. Ask guildmates to install the addon too for automatic guild sharing.
5. Open Recipe Registry from the minimap button or with `/rr`.
6. Search, browse, favorite recipes, and contact crafters directly from the addon.

The first sync may take a little time, especially in a larger guild. After that, Recipe Registry keeps itself updated quietly while you play.

## Useful Commands

- `/rr` opens the main Recipe Registry window
- `/rr options` opens the settings panel
- `/rr rescan` queues a fresh profession scan
- `/rr share guild` shares the selected recipe in guild chat
- `/rr share party`, `/rr share raid`, and `/rr share say` share the selected recipe to other channels
- `/rr prices <item name or item link>` checks available market pricing data

Most players only need `/rr`. The rest is there when you want more control.

## Optional Integrations

### AtlasLoot

AtlasLoot improves recipe recognition, crafted outputs, reagent details, and profession category browsing. Recipe Registry works without it, but AtlasLoot makes the recipe browser richer.

### TradeSkillMaster And Auctionator

If TradeSkillMaster or Auctionator is installed, Recipe Registry can show material prices and estimated craft costs. Pricing depends on the freshness of your market data.

## Compatibility

- Built for WoW TBC Anniversary / The Burning Crusade Classic 2.5.x
- Core browsing and guild sync work without optional addons
- Optional addons improve recipe detail and market pricing
- For the smoothest guild sync, guildmates should keep Recipe Registry on the same major release line

## Installation

### CurseForge App

Install Recipe Registry through CurseForge, then launch the game.

### Manual Install

1. Download the release zip.
2. Extract it into `Interface/AddOns/`.
3. Make sure the folder name is `RecipeRegistry`.
4. Restart the game or reload the interface.

## Notes

- Item names and icons may appear gradually the first time WoW fills its local item cache.
- Cost estimates depend on TradeSkillMaster or Auctionator data and may not always be available.
- The addon is intentionally careful with incomplete profession and roster data so a temporary game API hiccup does not erase useful guild information.

## Support The Project

If Recipe Registry makes guild crafting smoother for you and your friends, and you want to help keep it maintained and improved, you can support development here:

[paypal.me/Kaedros](https://paypal.me/Kaedros)

Thank you. It genuinely helps keep the project alive.

## Feedback And Support

- Issues and feedback: [GitHub Issues](https://github.com/colettamattia91-cloud/Recipe-Registry/issues)
