# dmc

A repo-local recovery layer for AI-assisted coding.

I built this because coding with AI agents (Claude, Cursor, Aider) is fast, but they often break code across multiple files simultaneously. Standard Git commits are too slow for micro-iterations, and standard undo (`Ctrl+Z`) doesn't work reliably when an external process modifies your files.

`dmc` runs beside your editor and agents, watches file changes, and maintains a local SQLite history of saves in `.dmc/`. If an agent hallucinates or breaks a build across multiple files, you can inspect the burst of changes and restore the damaged files without polluting your Git history.

## Features

* **Tool-Agnostic Recovery:** Works below editors and agents, so Cursor, Claude Code, Aider, terminals, and manual edits share one local recovery layer.
* **Background Watcher:** Monitors file system events and snapshots changes automatically.
* **Debouncing:** Waits 500ms after a file save to prevent spamming snapshots during rapid writes.
* **Burst Recovery:** Groups rapid multi-file edits so AI sessions can be previewed and restored as a set.
* **Safe Restore:** Supports preview/dry-run restores, restore audit records, and redo.
* **Deduplication:** Uses SHA-256 hashing to ensure only actual content changes are stored.
* **Local Vault:** All data is stored in a hidden `.dmc/` directory (SQLite + raw file snapshots).
* **Garbage Collection:** Automatically deletes unreferenced snapshots older than 168 hours by default to save disk space.
* **Ignore Support:** Respects `.dmcignore` files and defaults (ignores `.git`, `node_modules`, `build`, etc.).

## Installation

### macOS / Linux (Homebrew)

```bash
brew tap EvilMetaMonkey/dmc
brew install dmc
```

### Windows

Download the latest `dmc.exe` from the [GitHub Releases](https://github.com/EvilMetaMonkey/dmc/releases) page, or build from source:

```powershell
dart build cli -o build/dmc
.\install.ps1
```

The installer moves the CLI bundle to `C:\bin\dmc` and adds `C:\bin\dmc\bin` to your user `PATH`.

### From Source

Requires the Dart SDK (>=3.10.8):

```bash
git clone https://github.com/EvilMetaMonkey/dmc.git
cd dmc
dart pub get
dart build cli -o build/dmc
```

## Usage

### 1. Initialize a repository

Run this in the root of your project. It creates the hidden `.dmc/` folder.

```powershell
dmc init
```

### 2. Start the watcher

Run this in a separate terminal. It will stay running and listen for file changes.

```powershell
dmc watch
```

### 3. View history

See a list of recent snapshots, including their snapshot IDs.

```powershell
dmc log
```

To inspect AI-sized change groups instead of individual file saves:

```powershell
dmc log --bursts
```

Example output:

```text
Recent Backups:
------------------------------------------------------------
[ID: 12] 2026-03-05 14:30:00 - lib/main.dart
[ID: 11] 2026-03-05 14:28:41 - lib/app.dart
[ID: 10] 2026-03-05 14:27:03 - pubspec.yaml
------------------------------------------------------------
Total: 3 backup(s)
```

### 4. Check changes

Compare your current file against the last valid snapshot. Red text is deleted content and green text is added content.

```powershell
dmc diff lib/main.dart
```

### 5. Target a specific historical snapshot for diff

Compare your current file against a specific snapshot ID from the log.

```powershell
dmc diff lib/main.dart --id 12
```

### 6. Restore a file

Revert a file to its previous state immediately.

```powershell
dmc undo lib/main.dart
```

### 7. Deep Undo to a specific snapshot

Revert a file to an exact historical snapshot ID from the log.

```powershell
dmc undo lib/main.dart --id 12
```

### 8. Preview and restore a burst

Preview a multi-file AI edit before touching the working tree:

```powershell
dmc restore --burst 1700000000000 --dry-run
```

Restore that burst if the preview matches what you want:

```powershell
dmc restore --burst 1700000000000
```

Redo the overwritten state if you restored too far:

```powershell
dmc redo --burst 1700000000000
```

## Configuration

To ignore specific files or directories, create a `.dmcignore` file in your project root:

```text
# .dmcignore
secret_keys.json
*.log
temp/
```
