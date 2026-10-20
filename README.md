# Halo Mod Health Checker

Checks a Halo MCC mod (or a folder of mods) before you upload it to the Steam Workshop, and
tells you what's wrong: what will stop it working in MCC or on a
[Project Reclaimer](https://projectreclaimer.dev) server, why, and how to fix it. It only reads
your files; it never changes anything.

## Use it

1. Download the newest release and unzip it anywhere.
2. Double-click **checkmodhealth.cmd**.
3. Drag your mod's folder into the window (or paste its address) and press Enter.

You can also drag the folder straight onto checkmodhealth.cmd.

The report is shown in the window and saved in the **logs** folder next to checkmodhealth.cmd,
one file per run. Point it at a mod's own folder (the one with ModInfo.json), or at a folder
holding several mods (MCC's Workshop folder, a server's content\Mods): then it also checks
the mods against each other.

When a newer version is out, it says so as it opens and asks whether to update. Say no and it
carries on as it is.

Windows only. It needs nothing installed: it runs on the Windows PowerShell that comes with
Windows 10 and 11.

## What it says

Each mod gets a verdict: **READY**, **READY, BUT READ THE WARNINGS**, or **NOT READY**. Each
thing it finds is one of:

- **PROBLEM**: something will break. MCC or Project Reclaimer won't load the mod, or a map or
  part of it.
- **WARNING**: it isn't right. It causes trouble in some cases, or every player downloads
  something they don't need.
- **NOTE**: worth knowing; nothing has to change.

Each comes with **Why** (what goes wrong, and where) and **Fix** (what to do), and the code in
brackets that names it below.

## What it checks

**ModInfo.json** (what MCC, Excession and Project Reclaimer know the mod by)
- `modinfo-unreadable`: it isn't valid JSON, so the whole mod is skipped.
- `modinfo-field-case`, `description-field-case`: a field written with other capitals
  (`engine` for `Engine`); MCC reads names exactly.
- `no-modguid`, `bad-modguid`, `duplicate-modguid`: MCC tells mods apart by ModGuid and
  loads only one of two that share it (a copied mod folder keeps the old GUID).
- `bad-engine`, `no-engine`, `not-halo3`: the game it's for.
- `no-app-version`, `bad-app-version`, `app-version-backwards`, `app-version-old`,
  `app-version-new`, `app-version-behind`, `app-version-unset`: the MCC versions it says it
  works with, against the MCC and Excession on your PC. MCC hides a mod whose MaxAppVersion is
  older than the game; 0.0.0 sets no limit.
- `no-title`, `no-description`, `title-too-long`, `description-too-long` (the Workshop's 128
  and 8,000 bytes), `no-mod-version`, `bad-mod-version`, `not-uploaded`.
- `workshop-id-mismatch`: a downloaded copy whose ModInfo.json names another Workshop item.
- `bad-inherit`, `external-mod-missing`, `dependency-not-here`, `shared-flag-on`: where its
  shared files come from, and a mod it builds on.
- `contents-file-missing`, `contents-flag-off`, `no-contents`: what it says it has
  (HasCampaign, HasBackgroundVideos, HasNameplates, HasSpartanOps, HasController) against the
  files there.

**Map descriptions** (multiplayer\\, firefight\\ and campaign missions)
- `description-missing`, `description-unreadable`, `description-unlisted`: listed but missing
  or broken, or there but never listed.
- `no-scenariofile`, `description-no-map`: a description finds its .map by the last part of
  its ScenarioFile (`maps\<that>.map`).
- `no-mapguid`, `bad-mapguid`, `duplicate-mapguid`, `map-no-title`, `map-title-long`.
- `image-missing`, `image-not-png`, `image-in-root`, `image-too-big`, `image-size`,
  `image-pr-limit`, `image-none`: map images are PNGs; Excession recommends a subfolder, at most
  900 KB (3 MB for a loading screen), and its templates are 316 x 160 (thumbnail) and
  668 x 292 (large). A missing image says where a file of that name is, if it's elsewhere in
  the mod.
- `bad-map-flag`, `team-count-zero` (a known MCC issue: a black screen, then game over),
  `team-category-all`, `bad-team-category`, `bad-team-count`, `bad-weapon`.
- Campaigns: `campaign-unreadable`, `campaign-bad-guid`, `campaign-no-title`,
  `campaign-players`, `campaign-no-missions`, `bad-mission-kind`, `mission-times`.

**Maps** (.map files)
- `map-not-described`: no description names the map, so it is never listed or played
  ("Map needs matching .mapinfo metadata").
- `map-old-copy`: an old copy left beside the map, uploaded to every player for nothing.
- `map-damaged`: the map file can't be read: cut short, its tag index pointing outside the
  map's data, no scenario, or not an MCC Halo 3 map at all. These are the checks Project
  Reclaimer makes before it uses a map, so a map that fails here fails on a server.
- `map-renamed`: its file name, header name and scenario name differ (the tools make them the
  same; renaming a built map isn't supported).
- `map-not-in-maps`, `map-not-multiplayer`, `map-no-id`, `map-id-stock`, `duplicate-map-id`,
  `same-map-name`, `map-too-big`.

**Everything else in the folder**
- `soundbank-damaged`, `soundbank-no-info`, `soundbank-info-alone`, `soundbank-too-big`:
  FMOD sound banks and their .fsb.info.
- `videos-unreadable`, `video-missing`, `video-bad-guid`, `video-damaged`, `video-bink1`,
  `video-too-big`: menu videos and BackgroundVideosInfo.json.
- `blf-damaged`: .mapinfo files and map or game variants that aren't Halo BLF files;
  `mapinfo-leftover`: .mapinfo files a mod package doesn't need.
- `unneeded-files`: backups, copies, archives, programs, source art, tool data, logs, system
  files, Project Reclaimer's install receipts. Excession uploads *every* file in the mod
  folder, and it all counts against your Steam Cloud quota.
- `name-spaces`, `path-too-long`, `upload-path-too-long` (Steam Cloud's 260 characters),
  `empty-folders`.
- `customization-unreadable` (character mods), `layout-unreadable`, `layout-no-map`,
  `layout-other-version` (Project Reclaimer Forge layouts), `workshop-incomplete` (a copy a
  Project Reclaimer server installed), `pr-too-many-maps`, `pr-too-many-files`.

When one mod has several findings of one kind, the first is told in full and the rest are
listed under it.

## Where the rules come from

- MCC's mod loader and 343's uploader, Excession: their messages, rules and limits, read from
  the copies installed with MCC and the mod tools, and Microsoft's Excession documentation.
- Project Reclaimer 0.9.21, tested against hand-made mods: how it matches a map to its
  description, the checks it makes on a map file, its limits for sharing mods with players.
- 28 published Workshop mods, used to make sure working mods aren't flagged for things that
  don't matter.
- Real broken uploads: a map whose description named the wrong file, a leftover "-old" copy
  of a 2 GB map, a description listed but missing, a map whose tag index was damaged.

Found something it should catch, or a check that's wrong? Open an issue with the log file.

## For developers

`tests\run-tests.ps1` builds small mods with one fault each and checks the report names
them:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

A release is a zip named `HaloModHealthChecker-<version>.zip` holding checkmodhealth.cmd,
checkmodhealth.ps1, README.md and LICENSE (`tools\make-release.ps1` makes it), attached to a
GitHub release tagged `v<version>`. The version is `$Version` at the top of
checkmodhealth.ps1. The update check reads the latest release.

## License

GPL-3.0: see LICENSE.
