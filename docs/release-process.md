# Release Process — Recipe Registry & Craft Orders

How releases work for the Recipe Registry addon family. Two addons (`RecipeRegistry` and `RecipeRegistry_Orders`) ship together from one repo and one CurseForge project.

If you are reading this because you forgot how releases work: jump straight to [§3 Cutting a release](#3-cutting-a-release) for the day-of checklist.

---

## 1. Distribution model

- **Git repo:** one (this one).
- **CurseForge project:** one (Recipe Registry).
- **WoW addons produced:** two — `RecipeRegistry` and `RecipeRegistry_Orders`.
- **Release ZIP:** one file containing both addon folders side-by-side.
- **CurseForge trigger:** CurseForge's native GitHub integration, currently set to trigger on **tag push** (verify in the CF project's GitHub link settings if changed). Every tag fires one build.

Why one project: CurseForge's native integration cannot filter tags by pattern, so a two-projects-from-one-repo setup would require migrating to GitHub Actions. That migration is deferred per `docs/craft-orders-roadmap.md` §3.9 until Craft Orders is stable enough to want an independent release cadence.

---

## 2. Repository layout

```
repo-root/
  .pkgmeta                      ← packaging config CurseForge reads
  CHANGELOG.md                  ← release notes, per-addon sections
  README.md
  CLAUDE.md
  docs/                         ← dev docs (excluded from package)
  local-tests/                  ← backend test harness (excluded from package)
  scripts/                      ← dev tooling (excluded from package)

  RecipeRegistry.toc            ← addon 1 entry point (at root)
  Core/                         ← addon 1 sources (at root)
  Data/
  Sync/
  UI/
  Integrations/
  Libs/

  RecipeRegistry_Orders/        ← addon 2 (sibling subdirectory)
    RecipeRegistry_Orders.toc
    Core/, ...                  ← addon 2 sources
```

The packager treats the root as `RecipeRegistry`'s source. The `move-folders` directive in `.pkgmeta` hoists `RecipeRegistry_Orders/` out as a sibling folder in the release ZIP:

```yaml
move-folders:
  RecipeRegistry/RecipeRegistry_Orders: RecipeRegistry_Orders
```

Result in the ZIP:

```
RecipeRegistry-X.Y.Z.zip
  RecipeRegistry/
    RecipeRegistry.toc
    Core/, Data/, Sync/, UI/, Integrations/, Libs/
  RecipeRegistry_Orders/
    RecipeRegistry_Orders.toc
    Core/, ...
```

WoW sees two separate addons after install. Users can enable/disable each independently in the AddOns selector.

---

## 3. Cutting a release

### 3.1 Pre-release checklist

1. **All work merged to `develop`.** No outstanding feature branches that should be in this release.
2. **Backend tests green.** Run `.\local-tests\run-backend-tests.ps1` from repo root.
3. **In-game smoke test.** Launch WoW, confirm RR loads cleanly and (if Orders is past skeleton phase) the plugin loads cleanly. Check the chat for the load confirmation line and any errors. See §4 for the dev symlink setup if not already done.
4. **Decide which addons changed.** Even if only Orders changed, RR's version still bumps (single CurseForge project = shared release cadence — see §1).

### 3.2 Bump versions

Edit two TOC files:

- `RecipeRegistry.toc` → `## Version: X.Y.Z` (this is what CurseForge displays to users).
- `RecipeRegistry_Orders/RecipeRegistry_Orders.toc` → `## Version: A.B.C` (internal, visible only in WoW's addon list).

Versions are independent — bump each according to what actually changed in that addon. If Orders is the only thing that changed, RR can do a patch bump (e.g., `2.0.5` → `2.0.6`) just to satisfy the shared cadence.

### 3.3 Update CHANGELOG.md

Add a new section at the top of `CHANGELOG.md`:

```markdown
## X.Y.Z — YYYY-MM-DD

### RecipeRegistry X.Y.Z
- (changes, or "no functional changes" if version bumped only for cadence)

### RecipeRegistry_Orders A.B.C
- (changes, or "no functional changes")
```

The `manual-changelog` directive in `.pkgmeta` tells CurseForge to use this file as-is for release notes.

### 3.4 Commit and tag

```powershell
git add RecipeRegistry.toc RecipeRegistry_Orders/RecipeRegistry_Orders.toc CHANGELOG.md
git commit -m "Release X.Y.Z"
git tag vX.Y.Z
git push origin develop --follow-tags
```

The push of the tag triggers CurseForge's native integration. Within a few minutes the build appears on the project's CurseForge page.

> **Tag naming:** plain `vX.Y.Z` (matching the recent RR convention — see `git tag --list`). Do not use addon-prefixed tags like `rr/vX.Y.Z` — those become relevant only after migrating to GitHub Actions per `docs/craft-orders-roadmap.md` §3.9.

### 3.5 Post-release verification

1. Open the CurseForge project page → Files. Confirm the new version is listed.
2. Download the ZIP and inspect: both `RecipeRegistry/` and `RecipeRegistry_Orders/` must be at the top level of the archive, each containing its `.toc`.
3. Install into a clean WoW AddOns directory (or use a test profile) and verify both addons appear in the selector and load without errors.
4. Update `MEMORY.md`'s `project_context.md` if anything major shifted.

---

## 4. Dev workflow (one-time setup)

At dev time WoW does not see `RecipeRegistry_Orders` automatically because its `.toc` is nested inside the repo. Use [`scripts/dev-link.ps1`](../scripts/dev-link.ps1) to symlink both addons into your WoW AddOns directory.

### 4.1 Requirements
- Windows with PowerShell.
- Either Developer Mode enabled (Settings → For developers → Developer Mode) **or** PowerShell launched as Administrator. Symbolic link creation requires one of these.

### 4.2 First time

```powershell
# Option A: pass the WoW path explicitly each run
.\scripts\dev-link.ps1 -WoWPath "D:\Games\World of Warcraft\_classic_"

# Option B: set the env var once (e.g., in your $PROFILE) and just run the script
$env:RR_WOW_PATH = "D:\Games\World of Warcraft\_classic_"
.\scripts\dev-link.ps1
```

The `-WoWPath` should point at the WoW Classic install root — the folder containing `WoWClassic.exe`. The script appends `Interface\AddOns` and creates the links there:

```
WoW\Interface\AddOns\RecipeRegistry        → repo-root\
WoW\Interface\AddOns\RecipeRegistry_Orders → repo-root\RecipeRegistry_Orders\
```

### 4.3 Day-to-day

After editing source files in the repo, `/reload` in WoW (or restart the client) and both addons pick up the change.

### 4.4 Removing the links

```powershell
.\scripts\dev-link.ps1 -Remove
```

Real directories at those paths (i.e., not symlinks) are left alone — the script refuses to delete them so you cannot accidentally lose a manual install.

---

## 5. Common gotchas

| Problem | Cause | Fix |
|---|---|---|
| Only RR appears in WoW addon selector, not Orders | The dev symlink for Orders is missing or stale | Re-run `scripts\dev-link.ps1` |
| "RecipeRegistry not loaded — check TOC dependency" message at login | WoW loaded plugin before RR | Verify `## Dependencies: RecipeRegistry` is in `RecipeRegistry_Orders.toc` |
| CurseForge build produces only `RecipeRegistry/` folder, no `RecipeRegistry_Orders/` | `move-folders` directive missing or wrong path in `.pkgmeta` | Inspect `.pkgmeta` — the directive must be exactly `RecipeRegistry/RecipeRegistry_Orders: RecipeRegistry_Orders` |
| MockSync.lua leaks into release ZIP | `Sync/MockSync.lua` not in `.pkgmeta` ignore list | Restore the ignore entry; it's mandatory for release builds |
| Tag pushed but no CurseForge build | CF GitHub integration broken or in commit-mode instead of tag-mode | Check CF project page → Settings → GitHub integration. Re-link if needed. |
| Version mismatch user reports ("I have RR 2.0.7 but Orders shows 0.1.0") | Expected — versions are independent | Not a bug. The shared CurseForge version is RR's. Orders has its own internal version. |

---

## 6. Future migration to two CurseForge projects

When Craft Orders matures (see `docs/craft-orders-roadmap.md` §3.9 for the migration trigger), this process will change:

- Disconnect CurseForge's native GitHub integration.
- Add `.github/workflows/release.yml` driven by `BigWigsMods/packager`.
- Use tag prefixes (`rr/vX.Y.Z`, `orders/vA.B.C`) to dispatch jobs to the appropriate CurseForge project.
- Maintain two CurseForge projects, one per addon.

Until that trigger fires, keep using this single-project workflow. The added overhead of the future migration is one-time and only worth paying once the benefit (independent release cycles) actually exists.
