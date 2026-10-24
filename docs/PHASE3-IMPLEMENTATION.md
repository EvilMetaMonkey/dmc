# Phase 3 implementation and review handoff

September 5, 2026. Canonical repository: `EvilMetaMonkey/dmc`. Development version: `1.1.0-dev.3`. These are local, uncommitted changes on top of Phases 1–2 and the user's existing UI edits. No release, push, source-visibility change, or license selection has been performed.

## Review verdict

**Phase 3 is ready for code review and supervised manifest testing on disposable projects. It is not ready to restore a project checkpoint.** The new workflow can prove that an eligible pre-run manifest was captured, close the interval after writers stop, and classify the resulting file changes. Phase 4 must add conflict-aware planning and a recoverable operation journal before dmc can safely apply that manifest across a project.

Local verification is on macOS arm64. CI is configured for macOS arm64/Intel, Linux, and Windows, but those remote jobs have not run in this task. Do not advertise an operating system as verified for this revision solely because the workflow exists.

## Implemented behavior

### Checkpoint lifecycle

- `checkpoint begin [--label <text>] [--source <name>]` generates a timestamp-and-secure-random local ID, persists `creating`, captures every eligible pre-run file, performs a second verification scan, and moves to `open` only when there are no fatal issues.
- A dedicated workspace checkpoint lock serializes begin, close, and release across cooperating processes. A database partial unique index permits one checkpoint in `creating`, `open`, or `closing` and remains the final active-state guard. A competing lifecycle command fails without changing state.
- Unsupported ignore policy, scan failures, unstable/unreadable captures, a file appearing/disappearing during manifest verification, or corrupt reused history create an inspectable `invalid` checkpoint with a nonzero exit. Agent work must not start.
- Ignored paths, binary files, oversized files, links, and unsupported filesystem objects are recorded separately as exclusions. Exclusions are visible and outside the protection guarantee; they do not silently count as protected.
- `checkpoint close <id>` moves an open checkpoint to `closing`, reloads and fingerprints policy, rescans, captures and verifies post-run state, and records `modified`, `created`, `deleted`, or `unchanged`. Renames are represented as deletion plus creation. A changed policy or incomplete post-state makes the checkpoint `invalid`.
- Close can resume from a persisted `closing` checkpoint: prior partial close metadata is discarded and the post-run scan restarts from the durable before-manifest. Closing an already closed checkpoint is idempotent.
- `checkpoint show <id>` displays the lifecycle state, source/label, protected paths, before/after presence, classifications, exclusions, and fatal issues. `checkpoint diff <id>` lists changed paths and exclusions without changing files.
- `checkpoint release <id>` is explicit abandonment/unpinning. It works for closed, invalid, or interrupted active states, clears snapshot foreign-key references while retaining hashes, classifications, issues, label/source, counts, and timestamps, and changes status to `released`. This enables a new begin and allows retention/GC to reclaim blobs later. Release is idempotent.

The manifest records all eligible filesystem changes inside the interval. It does not attribute a change to an agent, user, editor, formatter, or hook. Haven must serialize one agent run, wait for successful begin before mutation, stop writers before close, and treat every nonzero result as failure.

### Schema and retention

Schema version 2 adds:

- `checkpoints` for lifecycle, source, label, manifest version, timestamps, policy fingerprint, and issue counts;
- `checkpoint_files` for canonical relative paths, before/after presence, snapshot IDs, hashes, and classification;
- `checkpoint_issues` for phase, stable code, path, message, and fatality;
- foreign keys from manifest entries to checkpoint/history rows, plus indexes for active-state and issue lookup.

Version 0 legacy vaults still migrate through the Phase 1 schema. Version 1 vaults migrate in place to version 2 without rewriting history. Newer unknown versions remain refused. GC excludes snapshots referenced by every non-released checkpoint. Release detaches those IDs in a transaction before the released state becomes visible.

### Human and machine interfaces

Available commands:

```text
dmc capabilities --json
dmc checkpoint begin [--label <text>] [--source <name>] [--json]
dmc checkpoint close <checkpoint-id> [--json]
dmc checkpoint show <checkpoint-id> [--json]
dmc checkpoint diff <checkpoint-id> [--json]
dmc checkpoint release <checkpoint-id> [--json]
```

JSON uses one stable envelope shape:

```json
{
  "schemaVersion": 1,
  "ok": true,
  "command": "checkpoint.begin",
  "data": {},
  "warnings": [],
  "errors": []
}
```

Checkpoint JSON mode redirects incidental diagnostics away from stdout and writes exactly one encoded result there. Arrays are emitted in path/issue order and file contents are never included. Exit classes used in this phase are `0` success, `2` usage, `3` incomplete/invalid checkpoint, `5` missing checkpoint data, and `1` other failure. Conflict `4` and interrupted operation `6` are reserved for Phase 4.

`capabilities` deliberately reports `checkpointApply: false`. Its schema is useful for Phase 3 testing but remains preliminary until Phase 5 finalizes Haven's full subprocess contract.

### Status and diagnostics

- `status` shows the active checkpoint or latest checkpoint with state and counts.
- `doctor` reports persisted `creating`/`closing` states as interrupted and lists invalid checkpoints as protection failures. It also checks checkpoint-to-history references as part of dangling-reference diagnostics.
- Explicit release provides a recovery route for an abandoned `creating`/`closing` state. It does not resume a killed begin scan or reconstruct bytes that were never captured.

## Verification record

All automated scenarios use temporary folders. No user project was restored, released, or pruned.

| Check | Result / boundary |
| --- | --- |
| Complete regression suite | 136 tests passed on macOS arm64 with sequential execution |
| Phase 3 focused tests | Begin/close classification, exclusions, injected read failure, invalid policy, active-state enforcement, lifecycle serialization, restart close, interrupted release, retention pins, JSON shape/single output, capabilities, status/doctor, and v1-to-v2 migration |
| Analyzer gate | Passed with only the preserved pre-existing `_shiftArtLineLeft` warning in `lib/src/ui.dart` |
| Native bundle smoke | Builds and exercises background watch, legacy file restore/redo, checkpoint begin/close/show/diff/release, doctor, and GC preview |
| UI preservation | `lib/src/ui.dart` and `test/ui_test.dart` retain their pre-Phase-2 SHA-256 values |
| Cross-platform CI | Configured but not run remotely for this revision |

Reproduce using Dart 3.11.5:

```sh
dart pub get --enforce-lockfile
dart test --concurrency=1
dart run tool/check_analyzer.dart
dart build cli -o build/dmc
dart run tool/smoke_bundle.dart build/dmc/bundle/bin/dmc
```

Append `.exe` to the final path on Windows. Windows link/junction behavior and file-permission behavior require native platform validation; a skipped link test is not a pass for reparse-point safety.

## Deliberate boundaries and remaining risks

1. **There is no checkpoint restore in Phase 3.** Existing file, burst, task, mark, and UI restore routes retain legacy behavior. They are not substitutes for applying a checkpoint.
2. **Manifest scans are sequential.** Stable reads and a second verification scan detect ordinary concurrent drift, but dmc does not freeze the filesystem or prevent a hostile/concurrent process from changing a path between checks. Haven must serialize and stop writers at lifecycle boundaries.
3. **Phase 4 must preflight and journal every apply.** It still needs present-state conflict checks, zero-write failure for missing/corrupt inputs, atomic per-file replacement, recoverable deletion, redo state, per-step verification, resume/rollback, lock order, and safe handling of every legacy/UI mutation route.
4. **Policy exclusions remain meaningful risk.** Created ignored/binary/oversized/linked paths are declared but absent from the protected manifest. A file protected at begin that becomes ineligible at close invalidates the checkpoint. Previously captured excluded data remains in history until retention removes it.
5. **Interrupted begin is not resumable.** Doctor exposes it and release abandons it. A fresh begin is required. Interrupted close may be retried from its durable before-state or released.
6. **Release is final for checkpoint pinning.** Small metadata and hashes remain, while snapshot IDs are detached. It does not immediately erase blobs; GC applies retention rules. A released checkpoint cannot later be applied as an exact checkpoint.
7. **Distribution remains blocked.** Remote CI, archive/install/upgrade tests, signing, public/private asset access, license choice, and supported-platform decisions are still open. This implementation was not published.
8. **Performance is unmeasured on large repositories.** Begin and close intentionally scan and verify twice for trust. Large-repository bounds and progress/cancellation UX need measured work without weakening the completion gate.

The [tester walkthrough](TESTER-WALKTHROUGH.md) now demonstrates checkpoint begin/close/show/diff and clearly uses the older single-file restore only as a separate history exercise. The [README](../README.md) explains the same boundary for installers and invited users.

Work stops here for Phase 3 review. No Phase 4 restore planner, apply command, redo command, journal, recovery command, force option, or Haven integration has been implemented.
