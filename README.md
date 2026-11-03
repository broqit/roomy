# Roomy

A macOS menu-bar app that shows how much space caches take and removes only what can be recreated. It does not clear RAM, and it does not claim to speed up your Mac.

The panel opens from the menu-bar icon or from the notch. The language follows the system: Ukrainian, English, Spanish, German, or Kazakh. You can override it.

Author: Roman Borkunov.

## Build

Requires macOS 14 or later and the Swift toolchain that ships with Xcode. The build script produces an Apple silicon app.

```bash
./scripts/build-app.sh --install   # ~/Applications/Roomy.app, then launch
./scripts/make-dmg.sh              # build/Roomy-1.0.dmg
swift test
```

`./scripts/make-icon.sh` redraws `Resources/AppIcon.icns` after the icon drawing changes.

The signature is local, with no Apple certificate. The first time you open the app, macOS may ask you to confirm it from the file’s context menu. Roomy is not in the App Store and is not sandboxed: otherwise it could not read other apps’ caches. It does not grant itself Full Disk Access. If a folder stays unreadable, Roomy can open the relevant System Settings pane.

Inside the bundle the executable is named `CleanMac`. That is the Swift package target. On screen the app is Roomy. The bundle identifier is `com.mortimer.CleanMac`.

## Use

A scan deletes nothing. Cleaning is always a separate step, and it asks first.

If a cache belongs to a running app, Roomy asks to quit it, tries a normal quit, and force-quits only after that. Roomy never quits itself. That category stays out of Recommended while the app is still running.

Files that can be restored go to the Trash through `FileManager.trashItem`. Tool commands run only after Roomy has checked that the directory belongs to the current user and sits inside that user’s home. A symlink that escapes the home directory is rejected. Other users’ homes are not scanned. There is no `sudo`.

The command line does not quit apps:

```bash
./build/Roomy.app/Contents/MacOS/CleanMac --scan
./build/Roomy.app/Contents/MacOS/CleanMac --clean npm --yes
```

Cleaning does not start without `--yes`. If the owning app is still running, the command refuses.

## What can be removed

A category appears only when it actually exists on this Mac.

- Tool caches: pnpm, npm, Yarn, Bun, node-gyp, pip, CocoaPods, Xcode DerivedData, and the personal Homebrew cache in `~/Library/Caches/Homebrew`.
- Docker build cache: `docker builder prune -f` only.
- Caches for Cursor, Claude, Codex and ChatGPT, Viber, Telegram, Chrome, Safari, Arc, Firefox, JetBrains, and Android Studio.
- Other folders in `~/Library/Caches` when the folder can be tied to an installed app.
- IDE crash logs that sit directly in the home folder: only files with the expected names, never the home folder itself.
- Separately, and not as part of a bulk clean: each Xcode simulator runtime (`xcrun simctl runtime delete` of one UUID, which cannot be undone) and each Android system image under `~/Library/Android/sdk/system-images` (moved to the Trash).

pnpm, npm, Yarn, pip, and the Docker build cache are cleaned with their own official commands. That does not go through the Trash, so it cannot be undone. The pnpm store on disk is larger than what `store prune` removes.

## What stays

- Chat history and sessions: Cursor (`state.vscdb`, History, agent-cli), Claude (`~/.claude/projects`, `history.jsonl`), Codex sessions, and local ChatGPT conversations.
- Telegram and Viber account data, including `ViberPC`. Browser profiles, bookmarks, and passwords.
- Docker images, volumes, containers, and the OrbStack disk image.
- Shared Homebrew outside the personal cache. That row stays view-only. `brew cleanup` is left for you to run; Roomy does not run it.
- The Trash. Finder empties it.
- Unrecognized folders in `~/Library/Caches`.
- Projects, SDKs, and IDE settings.

## Repository

The Swift package module is named `CleanMac`. Source is in `Sources/CleanMac`, tests in `Tests/CleanMacTests`, bundle resources in `Resources`, and build scripts in `scripts`.

`.build/` and `build/` are not part of the git tree. `build/Roomy-1.0.dmg` is produced locally.
