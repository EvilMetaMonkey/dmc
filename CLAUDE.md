# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Description

dmc (DeLorean Motor Company) is a local shadow-history version control CLI built in Dart. It allows developers to instantly undo rogue AI edits without polluting their main Git history.

## Dependencies

Key packages (check pubspec.yaml for latest):
- `args` - CLI argument parsing
- `crypto` - SHA-256 hashing
- `path` - Cross-platform file paths
- `sqlite3` - Local SQLite database

After modifying pubspec.yaml, run `dart pub get` to install.

## Build Commands

```bash
dart run bin/dmc.dart init           # Initialize DMC in current directory
dart run bin/dmc.dart watch          # Start watching for file changes
dart run bin/dmc.dart log            # Show recent backup history
dart run bin/dmc.dart undo <file>    # Restore a file to previous state
dart test                            # Run all tests
dart analyze                         # Lint and analyze code
```

## Architecture Rules

- **All internal logic MUST go in `lib/src/`** - Keep modules separate and modular
- **CLI entry point is `bin/dmc.dart`** - This is the only file that should contain `void main()`
- **Public API is exported from `lib/dmc.dart`** - Re-export modules for clean imports

## Coding Conventions

- Use the `path` package for all file paths to ensure Windows compatibility (e.g., `p.join(cwd, '.dmc')`)
- Use `sqlite3` package for the local SQLite database
- Keep functions small and modular
- Use `dart:io` for file system operations
- Each feature area should have its own file in `lib/src/`

## SQLite3 Patterns

- Use `_db.select(query, [args])` for SELECT queries
- Use `_db.execute(query, [args])` for INSERT/UPDATE/DELETE
- Use `Database.close()` (not deprecated `dispose()`)

## Database Schema

The SQLite database (`dmc.db`) contains a `history` table:

```sql
CREATE TABLE history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  file_path TEXT NOT NULL,
  snapshot_path TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  hash TEXT NOT NULL
);
```

## Watcher Behavior

- Ignores: `.git/`, `.dmc/`, `.dart_tool/`, `build/`, `node_modules/`
- Debounces file changes by 500ms to avoid rapid-fire saves
- Uses SHA-256 hash to skip duplicate content saves

## Project Structure

```
lib/
  dmc.dart           # Public API exports
  src/
    cli.dart         # Command-line argument parsing
    database.dart    # SQLite database operations
    init.dart        # Initialization logic
    restore.dart     # Restore and log functions
    watcher.dart     # File system watcher and backup recorder
bin/
  dmc.dart           # CLI entry point
test/
  dmc_test.dart      # Unit tests
```
