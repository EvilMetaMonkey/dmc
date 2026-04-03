# dmc

A local, background version control tool for AI-assisted coding.

I built this because coding with AI agents (Claude, Cursor, Aider) is fast, but they often break code across multiple files simultaneously. Standard Git commits are too slow for micro-iterations, and standard undo (`Ctrl+Z`) doesn't work reliably when an external process modifies your files.

`dmc` runs in the background, watches for file changes, and maintains a local SQLite history of every save. If an agent hallucinates or breaks a build, you can diff the changes and revert specific files instantly without polluting your Git history.

## Features

* **Background Watcher:** Monitors file system events and snapshots changes automatically.
* **Debouncing:** Waits 500ms after a file save to prevent spamming snapshots during rapid writes.
* **Deduplication:** Uses SHA-256 hashing to ensure only actual content changes are stored.
* **Local Vault:** All data is stored in a hidden `.dmc/` directory (SQLite + raw file snapshots).
* **Garbage Collection:** Automatically deletes snapshots older than 48 hours to save disk space.
* **Ignore Support:** Respects `.dmcignore` files and defaults (ignores `.git`, `node_modules`, `build`, etc.).

## Installation

You need the Dart SDK installed. Clone the repo and run the build script.

1. Clone the repository:

   ```powershell
   git clone https://github.com/EvilMetaMonkey/dmc.git
   cd dmc
   ```

2. Install dependencies and build the native executable:

   ```powershell
   dart pub get
   dart compile exe bin/dmc.dart -o dmc.exe
   ```

3. Run the installer (Windows):

   ```powershell
   .\install.ps1
   ```

This moves the binary to `C:\bin\dmc.exe` and adds `C:\bin` to your user `PATH`.

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

## Configuration

To ignore specific files or directories, create a `.dmcignore` file in your project root:

```text
# .dmcignore
secret_keys.json
*.log
temp/
```
