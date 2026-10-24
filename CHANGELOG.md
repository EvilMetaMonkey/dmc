## 1.1.0-dev.5.1 — Unreleased

- Add `checkpoint recover OP --resume|--rollback --preview` and advertise `operationRecoveryPreview` under machine schema 1.
- Report journal-bound per-file recovery targets and conflicts without changing workspace files, source SQLite sidecars, or operation state.
- Verify saved pre-operation recovery bytes during the shared preflight before rollback starts.
- Keep existing explicit recovery execution behavior. Haven's existing pinned bundle is not automatically upgraded.
- Release under the MIT License.
- Remove the unused `_shiftArtLineLeft` UI helper; the CI analyzer gate now fails on any diagnostic (fixes the Windows CI failure caused by path matching in the old exception).

## 1.1.0-dev.5 — Unreleased

- Finalize Haven machine envelope schema 1 with DMC version, process exit code, canonical workspace path, and stable workspace fingerprint on every JSON response.
- Add explicit `--schema-version 1` negotiation and reject unsupported requested versions before running a checkpoint command.
- Add `checkpoint list`, including checkpoint protection counts and operation IDs, and include operation history in `checkpoint show`.
- Define cancellation outcomes for capture and journaled apply/recovery commands. Add compiled-subprocess tests that forcibly terminate both paths and prove detection and recovery.
- Add a standalone Haven reference harness that uses argument arrays and JSON to complete begin, close, list, show, diff, restore, redo, and release with spaces, quotes, and Unicode paths.
- Verify machine output never includes fixture file contents and keep diagnostics off JSON stdout.
- Document the stable Haven subprocess contract, timeouts, exit classes, approval boundary, and recovery flow.

## 1.1.0-dev.4 — Unreleased

- Add conflict-aware whole-checkpoint restore and redo with preview as the default and an explicit `--apply` requirement.
- Preflight every changed path and required snapshot before applying; workspace drift, missing data, corrupt data, linked paths, and a running watcher block the whole operation before project files change.
- Add schema-version 3 operation journals with exact pre-operation content, presence, hashes, and POSIX permission modes, persisted before the first workspace mutation.
- Apply files through flushed temporary files and same-directory renames. Preserve replaced/deleted files in operation recovery storage until the operation completes.
- Add per-file completion records and `checkpoint recover <operation-id> --resume|--rollback` for interrupted multi-file operations.
- Make status and doctor surface incomplete operations and operation-storage problems. Block checkpoint release while recovery is incomplete; release detaches operation and manifest retention pins together.
- Add restore/redo round trips for modified, created, deleted, renamed, and permission-only changes, plus corruption, drift, interruption, resume, rollback, migration, CLI, and symlink-safety tests.

This remains a development preview. Local validation is macOS arm64; the configured macOS/Windows/Linux CI matrix must pass for the exact revision before broader tester claims.

## 1.1.0-dev.3 — Unreleased

- Add schema-version 2 checkpoint manifests with stable local IDs, explicit lifecycle states, before/after presence and hashes, change classifications, exclusions, and fatal issues.
- Add `checkpoint begin`, `close`, `show`, `diff`, and `release` without changing legacy burst, task, mark, snap, restore, redo, or UI semantics.
- Capture and verify complete eligible pre-run and post-run manifests; refuse a second active checkpoint and invalidate incomplete capture or changed policy.
- Pin checkpoint snapshots against retention until explicit release while retaining small manifest/audit metadata after references are detached.
- Add versioned JSON schema 1 output and preliminary `capabilities --json`; checkpoint JSON writes exactly one stdout result.
- Surface active, interrupted, and invalid checkpoint states through status and doctor.
- Add migration, lifecycle, classification, exclusion, failure, retention, JSON, status, and compiled-bundle coverage.

Checkpoint apply/restore, conflicts, redo, and interrupted-operation journals remain Phase 4 work. This is still a development preview.

## 1.1.0-dev.2 — Unreleased

- Harden snapshot publication, schema migration, integrity checks, restore preimages, and retention references (Phase 1).
- Capture a baseline before watcher readiness; reconcile creates, moves, deletes, atomic saves, and offline changes after restart.
- Drain pending and in-flight captures during graceful shutdown, and expose persistent watcher errors and exclusions in status/doctor.
- Validate workspace and vault paths, exclude links, and prune ignored directories before scanning. Reject unsupported ignore policies explicitly.
- Replace PID-based daemon signaling with an exclusive watcher lock and authenticated local control. Refuse ambiguous legacy watcher metadata.
- Add Git exclusion for new vaults, CLI help and error statuses, and explicit-only retention cleanup.
- Add cross-platform test/analyzer/bundle CI and make release builds depend on it with a pinned SDK and lockfile.
- Rewrite installation guidance and add a disposable-project tester walkthrough.

This is a development preview, not a published release. Full project checkpoints and recoverable/conflict-aware multi-file apply remain future phases. Existing UI work is preserved.

## 1.0.0

- Initial version.
