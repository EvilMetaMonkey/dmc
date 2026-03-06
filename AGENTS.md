# AGENTS.md

## Project Summary
dmc (DeLorean Motor Company) is a Dart CLI for local shadow-history version control. It watches project files, debounces rapid changes, stores snapshot metadata plus hashed backups in a hidden `.dmc/` SQLite vault, restores prior file states quickly, and can diff a working file against its latest snapshot.

## Current Phase Status
- Phase 1: Init flow complete.
- Phase 2: Watcher flow complete.
- Phase 3: Restore/log flow complete.
- Phase 4: Global Windows compilation and installation complete.
- Phase 5: Polish complete (`.dmcignore` support and 48-hour snapshot pruning added).
- Phase 6: Diff complete (`dmc diff <file>` added with ANSI-colored output).

## Tech Stack
- Language: Dart
- Storage: SQLite via `sqlite3`
- Path handling: `path`
- Hashing: `crypto` (SHA-256)
- CLI parsing: `args`
- Text diffing: `diff_match_patch`

## Architecture Rules (Must Follow)
- All internal logic MUST remain in `lib/src/`.
- `bin/dmc.dart` is only the CLI entry point and should only call into library code.
- Public API exports are managed via `lib/dmc.dart`.

## Runtime/Data Notes
- DMC working directory: `.dmc/`
- Snapshots folder: `.dmc/snapshots/`
- Database file: `.dmc/dmc.db`
- History schema fields: `file_path`, `snapshot_path`, `timestamp`, `hash`
- Default watcher ignore rules: `.git`, `.dmc`, `.dart_tool`, `build`, `node_modules`
- Optional user ignore file: `.dmcignore`
- `.dmcignore` is loaded once when `dmc watch` starts
- Empty lines and `#` comments in `.dmcignore` are ignored
- Debounce delay: `500ms`
- Retention policy: snapshots older than `48` hours are pruned once at watcher startup
- `dmc diff <file>` compares the working file to its latest snapshot and prints ANSI-colored additions/deletions

## Common Commands
- `dart run bin/dmc.dart init`
- `dart run bin/dmc.dart watch`
- `dart run bin/dmc.dart log`
- `dart run bin/dmc.dart undo <file>`
- `dart run bin/dmc.dart diff <file>`
- `dart test`
- `dart analyze`
- `dart compile exe bin/dmc.dart -o dmc.exe`

## Windows Global Install
- Compile: `dart compile exe bin/dmc.dart -o dmc.exe`
- Install: `.\install.ps1`
- Installer behavior:
  - Ensures `C:\bin` exists
  - Moves `dmc.exe` to `C:\bin\dmc.exe`
  - Adds `C:\bin` to persistent user `PATH` if missing
  - Instructs user to restart terminal
