# Phase 4 implementation and review handoff

September 5, 2026. Canonical repository: `EvilMetaMonkey/dmc`. Development version: `1.1.0-dev.4`. These are local, uncommitted changes on top of Phases 1–3 and the user's existing UI edits. No commit, push, release, source-visibility change, or license selection has been performed.

## Review verdict

**Phase 4 is implemented for code review and supervised testing in disposable projects. It is not yet a public-release verdict.** DMC can now preview, apply, redo, resume, and roll back an eligible project checkpoint. It refuses pre-existing conflicts and missing/corrupt required snapshots before changing project files, and it records every apply step before the first workspace mutation.

Local verification is macOS arm64. The configured macOS arm64/Intel, Linux, and Windows jobs have not run remotely for this revision. Windows ACL behavior, reparse points, archive installation, signing, and the final supported-platform statement remain release gates.

## User-visible workflow

```text
dmc checkpoint restore <checkpoint-id> [--dry-run] [--apply] [--json]
dmc checkpoint redo <checkpoint-id> [--dry-run] [--apply] [--json]
dmc checkpoint recover <operation-id> (--resume|--rollback) [--json]
```

Restore and redo preview by default. `--apply` is required to change project files, and combining it with `--dry-run` is a usage error. There is no force option. The watcher must be stopped before apply or recovery.

Restore expects every changed path to match the checkpoint's verified post-run state and targets the pre-run state. Redo is available only after a completed restore, expects the pre-run state, and targets the post-run state. Repeating an already-applied direction produces an explicit conflict because its expected side no longer matches.

Exit classes are:

| Code | Meaning |
| --- | --- |
| `0` | Success or valid preview |
| `1` | Other failure |
| `2` | Invalid command usage |
| `3` | Missing, released, invalid, or ineligible checkpoint/operation |
| `4` | Workspace conflict or unsafe current path |
| `5` | Required snapshot reference/content missing or corrupt |
| `6` | Interrupted/busy operation that needs recovery |

## Planner and conflict behavior

`CheckpointPlanner` is read-only. It validates all changed relative paths through the shared workspace validator, verifies every snapshot needed for the intended side, reads regular files stably, and compares presence, SHA-256, and recorded POSIX permission mode. It returns the entire action/conflict/data-error set and does not create history or operation rows.

Apply acquires the shared checkpoint operation lock, rejects a live authenticated watcher, runs the planner, captures an exact pre-operation state for every action, and repeats the planner before writing the journal. Any detected drift blocks the whole apply while the workspace is still unchanged. Captured immutable history may exist even when the second preflight catches a concurrent edit; it is ordinary unreferenced history, not a partially applied operation.

The path checks exclude `.git`, `.dmc`, symlinks, directories, sockets, and targets outside the workspace. Each step revalidates and rereads its target before mutation. This narrows ordinary link-swap and concurrent-write hazards but cannot create a hostile-process sandbox or eliminate every time-of-check/time-of-use race with Dart's path-based filesystem APIs.

## Journal and filesystem protocol

Schema version 3 adds POSIX mode columns to checkpoint manifests and two tables:

- `checkpoint_operations`: checkpoint, direction, lifecycle timestamps, status, and failure message;
- `checkpoint_operation_files`: deterministic sequence, path, expected/intended/pre-operation presence, snapshot IDs, hashes, modes, per-file status/error, and recovery filename.

The operation plus every file step is inserted in one SQLite transaction before the first project-file mutation. SQLite uses `synchronous=FULL`. Operation states are `planned`, `applying`, `completed`, `failed`, `rolling_back`, and `rolled_back`; file states are `pending`, `applied`, and `rolled_back`.

For an existing target, DMC first renames the exact current file into `.dmc/operations/<operation-id>/`. Intended file bytes are reread from a hash-verified immutable snapshot, written and flushed in a temporary directory beside the destination, then renamed into place and reread for hash/mode verification. Intended absence leaves the original in recovery storage. Recovery storage is removed only after every step and the terminal journal state succeed.

The full project operation is not a single filesystem transaction. A process exit can temporarily leave some paths on each side. The journal and recovery files make that state detectable:

- `--resume` accepts recorded pre-state, intended state, or the mid-step absent state backed by a recovery file, then completes remaining/idempotent steps;
- `--rollback` walks in reverse and returns every path to its exact pre-operation content/presence and recorded POSIX mode;
- arbitrary drift blocks recovery before it performs further mutations;
- a failed recovery remains visible to `status` and `doctor` and can be retried after the reported cause is resolved.

## Retention, release, and diagnostics

Unreleased checkpoint manifests and operation pre/intended snapshots pin history against GC. `checkpoint release` refuses a checkpoint with any planned, applying, failed, or rolling-back operation. After completion or rollback, release clears manifest and operation snapshot IDs in one transaction while retaining hashes, modes, path classifications, statuses, and audit metadata.

`status` prints the oldest incomplete operation with its direction/checkpoint. `doctor` reports every incomplete operation, dangling operation snapshot reference, operation directory with no journal, non-directory storage entry, and recovery directory left behind after a terminal state. Doctor reports; it does not guess how to repair or delete recovery data.

## Verification scope

The Phase 4 tests cover:

- preview with no history/journal change;
- exact restore/redo of modified, created, deleted, and renamed paths;
- POSIX permission-only restore/redo;
- whole-operation refusal for workspace drift and corrupt required snapshots;
- journal persistence and all file rows before the first mutation;
- injected second-step failure followed by resume and by rollback;
- recovery after the original file has moved but before replacement is written;
- repeated restore/redo conflict behavior;
- release refusal and diagnostic visibility for incomplete operations;
- snapshot-reference detachment on release;
- symlink-swap refusal without changing the outside target;
- JSON output, CLI mode validation, and version 2 to 3 migration.

Verification completed locally on macOS arm64:

| Check | Result |
| --- | --- |
| Locked dependency resolution | Passed with the checked-in lockfile |
| Complete sequential regression suite | 153 tests passed |
| Analyzer gate | Passed with only the preserved pre-existing `_shiftArtLineLeft` UI warning |
| Native bundle build | Produced the complete CLI/native SQLite bundle |
| Native bundle smoke | Passed help/version, capabilities, watcher start/readiness/stop, legacy diff/restore/redo, checkpoint begin/close/show/diff, checkpoint preview/restore/redo, release, doctor, GC preview, and invalid-command exit behavior |
| UI preservation | `lib/src/ui.dart` and `test/ui_test.dart` retained their reviewed SHA-256 values |
| Remote platform CI | Configured but not run for this local revision |

The verification commands were:

```sh
dart pub get --enforce-lockfile
dart test --concurrency=1
dart run tool/check_analyzer.dart
dart build cli -o build/dmc
dart run tool/smoke_bundle.dart build/dmc/bundle/bin/dmc
```

## Remaining release risks

1. **Remote platform evidence is still missing.** Local macOS behavior cannot establish Windows reparse-point/ACL safety or Linux packaging correctness. POSIX permission bits are restored on macOS/Linux; Windows ACL preservation is not implemented or claimed.
2. **Concurrent hostile writers remain outside the trust boundary.** DMC detects stable-read drift and rechecks each file, while an unrelated process can still race path operations. Haven must serialize agent work and stop writers before close/apply/recovery.
3. **Durability is journaled, not a power-loss proof.** File content is flushed and SQLite is FULL synchronous, but directory-entry fsync is not available through the current portable Dart implementation. Native crash/power-loss fault testing has not been performed.
4. **Empty directory topology is not a checkpoint artifact.** File creates may recreate parent directories, while restore does not remove empty directories left after files are removed. File contents, presence, rename representation, and POSIX modes are the contract.
5. **Legacy single-file and UI restore retain their earlier semantics.** They do not use the project-checkpoint journal. Documentation must keep those paths distinct, and testers should use `checkpoint restore` for agent-run recovery.
6. **Scale and cancellation remain unmeasured.** Planning and capture intentionally read all changed files before apply. Large-checkpoint timing, progress UX, and cancellation behavior need measurement in Phase 5 without weakening the all-target gate.
7. **Distribution remains blocked.** Exact CI results, install/upgrade/uninstall trials, archive checksums, code signing/notarization decisions, license, privacy wording, support channel, and rollback build remain unresolved.

Phase 4 stops at this review boundary. Haven orchestration and its final subprocess/cancellation contract belong to Phase 5.
