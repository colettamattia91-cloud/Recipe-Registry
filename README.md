# Recipe Registry

Recipe Registry is a guild-focused crafting directory for World of Warcraft TBC Anniversary.

Inspired by the original GuildCraft TBC workflow and adapted with a modern, lightweight sync model.

It scans your professions locally, syncs craft data with guildmates, and gives you a searchable list of who can craft what.

## Highlights
- Progressive guild sync with chunked background transfer and pause-safe behavior
- Searchable recipe directory with profession filters and rarity sorting
- Recipe detail panel with crafters, reagents, and estimated material cost
- Online crafter quick-request icon (one-click whisper template)
- Shift-click linking from recipe title and material rows
- Manual roster cleanup button, minimap button, and options panel

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


## Main Features
### Guild recipe registry
- Scans your profession windows and stores learned recipe keys
- Protects existing owner data from suspicious partial profession scans
- Syncs data progressively in logical `character + profession` blocks
- Uses replica peers to help converge offline-owner data over time
- Pauses automatic sync work in combat and instanced content
- Maintains online/offline crafter visibility

### Roster lifecycle
- `Roster Cleanup` runs local-only guild membership maintenance
- Missing guild members are marked `stale` first and disappear from normal results
- Long-stale records are pruned only after the retention window
- Cleanup aborts when the guild roster snapshot looks incomplete
- Cleanup work runs in small background chunks instead of blocking the UI

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
- `/rr debug` toggle debug chat lines
- `/rr rescan` queue a profession scan and scan any active TradeSkill/Craft API data
- `/rr sync` show sync/comms status
- `/rr offline` show offline-owner/replica sync telemetry
- `/rr manifest` print the local sync manifest summary
- `/rr manifest verbose` print replica-owner and stale-owner manifest details
- `/rr manifest <target>` request a fresh manifest from a guild peer
- `/rr pull` request catch-up from known data owners
- `/rr prices <item name or item link>` check provider status and test item pricing
- `/rr share [guild, party, raid, say]` share selected recipe and materials
- `/rr atlas` show AtlasLoot resolver status
- `/rr r <recipeItemID>` inspect AtlasLoot recipe item mapping
- `/rr s <spellID>` inspect spell/enchant mapping
- `/rr i <createdItemID>` inspect created item mapping
- `/rr dump` print DB summary and scan/validation diagnostics
- `/rr wipe` clear addon DB (keeps addon installed, resets data)

## Debug And Test Commands
### Performance
- `/rr perf toggle` show or hide the performance/debug panel
- `/rr perf dump` print scheduler, queue, sync, scan, and manifest diagnostics
- `/rr perf reset` clear performance, sync, scan, and manifest counters
- `/rr perf help` show the performance command help

### Mock Sync
- `/rr mock status` print current mock state and counters
- `/rr mock start light, medium, heavy, burst` run direct snapshot load tests
- `/rr mock start bootstrap` run a heavier bootstrap-style transfer test
- `/rr mock start traffic` run full `HELLO/MANI/REQ/SNAP` local traffic
- `/rr mock start offline` test offline-owner convergence through replica peers
- `/rr mock start offlinewipe` test offline-owner convergence after a local wipe
- `/rr mock start trafficburst` stress test the replica traffic path
- `/rr mock start roster` simulate roster cleanup with active, stale, and prunable members
- `/rr mock start rosterheavy` heavier roster cleanup simulation
- `/rr mock start rosterbad` verify incomplete roster cleanup snapshot protection
- `/rr mock start integrity` verify partial snapshot merge protection
- `/rr mock cleanup` remove local mock data and mock sync state
- `/rr mock reset` clear mock counters
- `/rr mock stop` stop the local mock worker
- `/rr mock help` show the mock command help

## Expected Command Output
- `/rr help` prints a multiline command list including `/rr rescan`, `/rr offline`, `/rr manifest [target or verbose]`, `/rr perf ...`, and every mock scenario including `offlinewipe`.
- `/rr rescan` prints `Profession rescan completed for active profession data.` when active profession API data was scanned immediately, or `Profession rescan queued. Open or refresh a profession to complete pending scans.` when no profession API data is ready yet.
- A changed profession scan prints `Scanned <Profession>: <N> recipe(s) found.`; an unchanged scan prints `Scanned <Profession>: unchanged (<N> recipe(s)).`
- `/rr dump` prints `Members=<N> Professions=<N> Recipes=<N> | Local rev=<N> updated=<time>`, followed by `Scan signals=<N> started=<N> changed=<N> unchanged=<N> skipped=<N> failed=<N> partial=<N> invalid=<N> pending=<true|false> last=<profession>/<reason>`.
- `/rr sync` prints `Role=<Coordinator or Client> coordinator=<name> onlineNodes=<N> registry=<N> queued=<N> inFlight=<name or none> outgoing=<N> outboundChunks=<N> manifestChunks=<N> inboundChunks=<N> manifestPending=<N> paused=<true or false> isolated=<true or false>`.
- `/rr offline` prints `Offline sync manifests owners=<N> blocks=<N> queued=<N> served=<N> applied=<N> newOwners=<N>`, then either `Offline sync recent: none` or recent replica events.
- `/rr manifest` prints `Manifest local=<player-realm> blocks=<N> recipes=<N> ownerBlocks=<N> replicaBlocks=<N> replicaOwners=<N> staleMembers=<N>`, then compact replica/stale counts.
- `/rr manifest verbose` prints the same summary plus capped replica-owner and stale-owner detail lines.
- `/rr manifest <target>` prints `Requested fresh manifest from <target>.`
- `/rr perf dump` prints four diagnostic lines: `Perf ...`, `Role ...`, `Scan ...`, and `Manifest cache ...`; the manifest line includes `maniQueued`, `maniSent`, and `maniQueue`.
- `/rr perf reset` prints `Performance, sync, scan, and manifest counters reset.`
- `/rr mock status` prints `Mock active=<true or false> scenario=<name> ...` and scenario-specific lines for roster or integrity runs.
- `/rr mock start integrity` prints `Mock sync completed: integrity (ok)`; `/rr mock cleanup` prints `Mock cleanup complete. members=<N> registry=<N> nodes=<N> pending=<N>`.

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
4. Wait briefly for progressive guild sync handshakes and block requests to populate remote crafters.
5. Use `Roster Cleanup` when you want to refresh stale ex-guild data locally.

## Performance Notes
- Search refresh is debounced to reduce UI recomputation.
- Sync, manifest handling, inbound apply, and roster cleanup all run in chunked background steps.
- Automatic sync pauses in combat and instanced content, not merely because you are in a raid group.
- Suspicious partial profession scans are skipped so complete owner data is not replaced by a smaller temporary view.
- Sync manifests are cached, updated by dirty profession block, rebuilt in the background, and sent as paced `MANI` chunks instead of inline bursts.
- UI refreshes are deferred to avoid bursty redraws while sync work is in progress.

## Known Notes
- If item info is uncached, names/icons may resolve after a short delay.
- Pricing quality depends on available market sources and cache state.

## Feedback
[Issue](https://github.com/colettamattia91-cloud/Recipe-Registry/issues)
