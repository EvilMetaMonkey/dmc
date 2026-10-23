# Recovery preview: development contract addition

September 22, 2026 — dmc 1.1.0-dev.5.1, machine schema 1.

This additive change is not Phase 6 distribution or a public release. Existing
`checkpoint recover OP --resume|--rollback` still executes explicitly; adding
`--preview` inspects the same operation without executing it. Both modes are
supported, except an interrupted rollback permits only rollback continuation.

The preview returns operation/checkpoint identity, mode, all journal paths,
current state, recorded pre-state, actual recovery target, per-file no-op flags,
conflicts and a `canRecover` decision. It never infers rollback bytes from the
restore/redo direction. See HAVEN-INTEGRATION.md for exact fields and exit codes.

## Read-only boundary

- Opens the existing checkpoint lock read-only with a shared lock. It does not
  create a missing lock. Cooperating DMC writers use an exclusive lock.
- Requires the watcher to be stopped, as execution does. All other writers must
  also be stopped; the lock cannot control editors or unrelated processes.
- Reads a temporary private copy of SQLite metadata and its WAL, then opens that
  copy read-only with query-only enabled. This avoids SQLite creating or changing
  shared-memory sidecars in the source vault, even for an otherwise read-only
  connection. It refuses a different database schema instead of migrating it.
- Deletes its temporary metadata copy on normal completion/error. Forced process
  termination can retain a `dmc-recovery-preview-*` directory in the OS temporary
  area containing private metadata. It is not a new checkpoint or snapshot store.
  Do not collect those directories as routine diagnostics.
- Does not change target files, modes, snapshots, journal rows, or source vault
  files. Reading may update filesystem access times.
- Uses the same snapshot/path/current-state preflight as execution. Saved
  recovery pre-state files are now hash-verified before rollback can start,
  rather than only checking for their existence.

Preview does not guarantee later success: external changes, permissions, disk
space and interruption can still prevent execution. Haven must recheck after
approval, execute without force, and verify the terminal operation and bytes.

## Validation and integration boundary

Fifteen focused tests cover interrupted restore/redo, rollback continuation,
planned/applying/completed states, no-ops, mixed create/delete targets, manual
drift, corrupted saved recovery data, unavailable snapshots, unsafe links,
unreadable files, missing/busy locks, old-schema refusal, schema-1 CLI/capability
output and WAL-backed journals. They compare file inventories,
bytes, modification times and modes across repeated previews, including vault
contents. These are controlled local tests, not cross-platform release evidence.

Local macOS validation on September 22:

- `dart test --concurrency=1`: **169 passed**, including the 15 new tests.
- `dart test tool/haven_contract_test.dart --concurrency=1`: **3 passed**;
  builds a native bundle and covers reference lifecycle, forced capture
  cancellation, and forced journaled-apply cancellation. The last test now
  verifies both compiled recovery previews preserve the whole workspace/vault
  inventory before resuming successfully.
- `dart run tool/check_analyzer.dart`: passed, with only the explicitly allowed
  pre-existing `_shiftArtLineLeft` warning.
- `git diff --check`: passed.

The compiled test bundle is disposable and removed by the test harness; no
installed executable or user checkpoint was replaced. Linux/Windows and live
Haven approval/editor acceptance have not been run for this addition.

Haven 0.7.4 and its pinned dmc 1.1.0-dev.5 bundle remain unchanged. A new compiled
bundle needs its own contract tests and explicit Haven compatibility update
before any Haven rollback control is enabled.
