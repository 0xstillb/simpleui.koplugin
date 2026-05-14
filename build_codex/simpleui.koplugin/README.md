# SimpleUI (0xstillb Fork)

SimpleUI is a KOReader plugin that adds a clean home screen, configurable navigation, and quality-of-life library UI improvements.

Current release channel: `v1.4.5`

## What's New in v1.4.5

- Fixed `Cover Deck` crash on homescreen open.
- Fixed `Folder Covers` crash when enabling/disabling.
- Improved cover rendering stability (safe frame fallbacks to avoid widget nil-size crashes).
- Updated Collection/Folder Book card visuals to match the new cover style.
- Optimized `New Books` performance:
  - bounded newest-file scan (lower memory and CPU load)
  - short scan cache to reduce repeated filesystem scans
- Updater flow aligned to Grimmlink style:
  - silent auto-check on startup (throttled)
  - manual `Check for Updates` action in About
- Updater now points to this fork's release endpoint:
  - `https://github.com/0xstillb/simpleui.koplugin/releases/latest`

## Install

1. Download `simpleui.koplugin.zip` from Releases.
2. Extract it so the folder name is `simpleui.koplugin`.
3. Copy `simpleui.koplugin` into KOReader `plugins/`.
4. Restart KOReader.
5. Open `Menu -> Tools -> SimpleUI`.

## Update

- Manual: `Menu -> Tools -> SimpleUI -> About -> Check for Updates`.
- Automatic: silent background check at startup (interval-throttled).
- The updater downloads `simpleui.koplugin.zip` from this repository's latest release.

## Active Build Folder

Current working package used in this repo:

- `build_codex/simpleui.koplugin`

## License

MIT
