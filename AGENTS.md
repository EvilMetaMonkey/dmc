# AGENTS.md

## Project Summary
dmc (DeLorean Motor Company) is a Dart CLI for local shadow-history version control designed for AI-assisted coding workflows. It watches project files, debounces rapid changes, stores snapshot metadata plus hashed backups in a hidden repo-local `.dmc/` SQLite vault, restores prior file states quickly, and can diff a working file against historical snapshots.

The long-term product direction is:

> dmc is a trusted rollback safety net for AI coding agents.

It is **not** intended to replace Git.  
Git is for source control and commits.  
dmc is for recovering from risky or broken AI-assisted edits before commit.

---

## Current Phase Status
- Phase 1: Init flow complete.
- Phase 2: Watcher flow complete.
- Phase 3: Restore/log flow complete.
- Phase 4: Global Windows compilation and installation complete.
- Phase 5: Polish complete (`.dmcignore` support and retention pruning added).
- Phase 6: Diff complete (`dmc diff <file>` added with ANSI-colored output).
- Phase 7: Deep Undo complete (`log` shows IDs and `undo`/`diff` accept `--id`).

### Next Planned Phases
- Phase 8: Trust foundation improvements
  - `restore` alias
  - dry-run / preview restore
  - restore audit trail
  - redo
  - `status`
  - `doctor`
  - configurable retention
  - binary file detection
  - max file size support
  - watcher hardening
- Phase 9: Burst-level recovery
- Phase 10: Task/session-aware recovery
- Phase 11: Agent/source-aware metadata
- Phase 12: Cross-tool integrations and polish

---

## Product Goals
dmc should help developers safely recover from:
- bad AI edits
- multi-file hallucinations
- destructive agent runs
- mixed manual + agent workflows
- risky refactors before Git commits

The most important product qualities are:
1. **Trust**
2. **Safety**
3. **Clarity**
4. **Predictability**
5. **Minimal workflow friction**

---

## Tech Stack
- Language: Dart
- Storage: SQLite via `sqlite3`
- Path handling: `path`
- Hashing: `crypto` (SHA-256)
- CLI parsing: `args`
- Text diffing: `diff_match_patch`

---

## Architecture Rules (Must Follow)
- All internal logic MUST remain in `lib/src/`.
- `bin/dmc.dart` is only the CLI entry point and should only call into library code.
- Public API exports are managed via `lib/dmc.dart`.
- Keep concerns separated:
  - CLI parsing and routing
  - application/services
  - repository/data access
  - watcher/file system logic
  - diff/restore logic
  - config handling
- Prefer additive changes over rewrites.
- Do not move large amounts of logic unless necessary to support a feature cleanly.
- Avoid introducing framework-like complexity into a small CLI tool.
- New features should fit the existing repo-local `.dmc/` model.

---

## Runtime/Data Notes
- DMC working directory: `.dmc/`
- Snapshots folder: `.dmc/snapshots/`
- Database file: `.dmc/dmc.db`
- Current history schema fields: `id`, `file_path`, `snapshot_path`, `timestamp`, `hash`
- Default watcher ignore rules: `.git`, `.dmc`, `.dart_tool`, `build`, `node_modules`
- Optional user ignore file: `.dmcignore`
- `.dmcignore` is loaded once when `dmc watch` starts
- Empty lines and `#` comments in `.dmcignore` are ignored
- Debounce delay: `500ms`
- Current retention policy default: `48` hours, but this is expected to become configurable
- `dmc log` shows snapshot IDs for historical targeting
- `dmc diff <file>` compares the working file to its latest snapshot and prints ANSI-colored additions/deletions
- `dmc undo --id <id> <file>` and `dmc diff --id <id> <file>` target exact historical snapshots

### Data/Storage Direction
When extending the schema or storage model:
- prefer forward-compatible schema design
- keep migrations simple and explicit
- do not break existing local repos silently
- preserve repo-local operation
- optimize for correctness and trust over premature optimization

---

## Command and UX Principles
- Commands should feel safe, explicit, and predictable.
- Prefer clear command names over clever ones.
- `undo` is convenient, but `restore` should be supported where it improves clarity.
- Destructive actions should support preview/dry-run whenever practical.
- Output should be concise, readable, and useful in plain terminals.
- Errors must be actionable and specific.
- Avoid silent destructive behavior.
- If behavior is ambiguous, fail clearly rather than guessing.
- Logs should become increasingly human-readable as metadata expands.

---

## Safety and Recovery Principles
These rules are critical because dmc is a recovery tool.

- Never silently overwrite user work in a surprising way.
- Prefer warnings before destructive restore behavior.
- Preview/dry-run should be used whenever possible for restore-like operations.
- Restore operations should become auditable.
- Redo should be supported for restore workflows.
- If restore target selection is ambiguous, return a clear error instead of guessing.
- Trust and correctness are more important than cleverness or speed.

---

## File Watching Principles
- Preserve the current per-file debounce concept unless explicitly redesigning it.
- Be conservative when handling duplicate events, rapid write bursts, and atomic-save patterns.
- Avoid creating noisy duplicate snapshots.
- Snapshot creation should be deterministic and explainable.
- File watching behavior should remain Windows-safe.
- Cross-platform correctness is important, but Windows compatibility must not regress.

---

## Config Principles
- Config should remain repo-local and simple.
- New config options should be easy to understand and validate.
- Invalid config should fail clearly.
- Config design should allow future settings such as:
  - retention duration
  - max file size
  - storage cap
  - binary handling policy

---

## Testing Rules (Must Follow)
- Add or update tests for every behavior change.
- Prefer focused unit tests plus integration-style tests for command workflows when practical.
- Do not merge features without reasonable coverage of happy path and failure path.
- Test safety-sensitive features carefully:
  - restore
  - redo
  - retention cleanup
  - watcher behavior
  - config parsing
  - schema migrations
- If a behavior is difficult to test directly, add the most practical coverage possible and document the gap.

---

## Refactor Rules
- Refactor only as much as needed to support the feature cleanly.
- Do not rewrite unrelated files.
- Do not introduce large abstractions prematurely.
- Keep public behavior stable unless explicitly changing it.
- Preserve existing commands unless the task explicitly includes a migration/update.
- Avoid mixing unrelated cleanup with feature work.

---

## Database and Migration Rules
- SQLite schema changes must be explicit and safe.
- Prefer additive migrations.
- Existing `.dmc` repositories should continue working after upgrade when practical.
- Migration code should be understandable and testable.
- New metadata should be designed with future features in mind:
  - restore audit trail
  - burst IDs
  - task/session IDs
  - source/agent attribution
  - marks/bookmarks

---

## Performance Rules
- Correctness first, then performance.
- Avoid unnecessary DB writes and duplicate snapshots.
- Continue using hashing/deduplication for snapshot efficiency.
- Be mindful of storage growth as new metadata and snapshot features are added.
- Large-file and binary-file handling should be conservative and safe.

---

## Implementation Workflow for Agents
Before making changes:
1. Inspect the relevant files first.
2. Briefly explain the implementation plan.
3. List the files you intend to modify.
4. Make the smallest clean change that fits the existing architecture.
5. Do not rewrite unrelated code.
6. Add or update tests.
7. Summarize what changed and note any follow-up work.

When implementing a feature:
- preserve current behavior unless the task explicitly changes it
- prefer service/repository extraction over CLI bloat
- keep `bin/dmc.dart` thin
- keep Windows compatibility intact

---

## Near-Term Build Priorities
Implement in roughly this order:

1. Trust foundation
   - `restore` alias
   - dry-run / preview restore
   - restore audit trail
   - redo
   - `status`
   - `doctor`
   - configurable retention
   - binary detection
   - max file size
   - watcher hardening

2. Visibility improvements
   - richer `log`
   - better status/reporting
   - restore metadata display

3. Burst-level recovery
   - burst model
   - burst assignment
   - `log --bursts`
   - `diff --burst`
   - `undo/restore --burst`
   - `redo --burst`

4. Task/session-aware recovery
   - `task start`
   - `task end`
   - `log --tasks`
   - `undo/restore --task`
   - `redo --task`
   - marks/bookmarks

5. Agent-aware recovery
   - source metadata
   - manual vs agent inference
   - `log --by-agent`

6. Scale/polish
   - explicit GC
   - storage caps
   - content-addressed storage
   - interactive history
   - docs/help improvements

---

## Common Commands
- `dart run bin/dmc.dart init`
- `dart run bin/dmc.dart watch`
- `dart run bin/dmc.dart log`
- `dart run bin/dmc.dart undo <file>`
- `dart run bin/dmc.dart undo --id <snapshot-id> <file>`
- `dart run bin/dmc.dart diff <file>`
- `dart run bin/dmc.dart diff --id <snapshot-id> <file>`
- `dart test`
- `dart analyze`
- `dart compile exe bin/dmc.dart -o dmc.exe`

### Planned Commands
These may not all exist yet, but new work should be compatible with them:
- `dmc restore <file>`
- `dmc redo <file>`
- `dmc status`
- `dmc doctor`
- `dmc log --bursts`
- `dmc diff --burst <id>`
- `dmc undo --burst <id>`
- `dmc redo --burst <id>`
- `dmc task start "<label>"`
- `dmc task end`
- `dmc log --tasks`
- `dmc undo --task "<label>"`
- `dmc redo --task "<label>"`
- `dmc mark "<label>"`
- `dmc marks`
- `dmc restore --mark "<label>"`
- `dmc snap`
- `dmc gc`

---

## Windows Global Install
- Compile: `dart compile exe bin/dmc.dart -o dmc.exe`
- Install: `.\install.ps1`

Installer behavior:
- Ensures `C:\bin` exists
- Moves `dmc.exe` to `C:\bin\dmc.exe`
- Adds `C:\bin` to persistent user `PATH` if missing
- Instructs user to restart terminal

---

## Non-Goals
dmc should NOT become:
- a Git replacement
- a remote/cloud-first source control platform
- an overly abstract framework
- a tool that hides risky restore behavior behind vague UX

The focus is:
- local trust
- safe rollback
- AI-assisted coding workflows
- minimal friction