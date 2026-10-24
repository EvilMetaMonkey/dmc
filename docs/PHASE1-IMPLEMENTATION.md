# Phase 1 implementation — review handoff

Audit date: September 4, 2026 (America/Chicago). Canonical repository: `EvilMetaMonkey/dmc`. Base commit: `e2494b3`. Changes are uncommitted and unreleased.

Scope: Phase 1 of the DMC checkpoint hardening plan. Implementation stops here. Remaining work is assessed in [TESTER-READINESS-AUDIT.md](TESTER-READINESS-AUDIT.md).

## Delivered behavior

- Schema version 1 uses `PRAGMA user_version`, transactional migration, foreign-key enforcement, a busy timeout, WAL, and `synchronous=FULL`. Initialization is idempotent; newer unsupported versions fail. Failed migration rolls back additive changes and closes the connection.
- Existing history IDs, names, hashes, marks and audit rows remain in place. Legacy `command_name` audit tables remain readable and writable: new events populate both the legacy required column and `command`.
- `SnapshotStore` reads the live content once, hashes and persists the same owned byte buffer, flushes a staging file inside `.dmc`, renames it to a unique snapshot filename, then commits metadata. Storage failure produces a structured failure. Metadata failure may leave a complete orphan, with no committed history row for it.
- Watcher capture, manual snapshots, and restore preimages share the service. Deduplication verifies the existing blob before reusing its ID. Manual snapshots return failure if an eligible capture fails; the CLI propagates that status.
- Diff, restore preview, restore apply and redo verify the selected snapshot's SHA-256. Restore writes the exact bytes verified at application time. A failed preimage capture prevents that file's workspace write.
- Burst/task restore and redo preflight all selected snapshots for existing corruption before changing the first file. This is not a multi-file transaction or protection against changes after preflight.
- A tombstone requires both reserved values; a partially damaged sentinel cannot authorize deletion.
- GC protects marked bursts and both restore-event references. It removes exact eligible history rows in one transaction before unlinking blobs. Shared legacy blobs stay if a retained row references the same filename. Unlink failures leave reported orphans. Invalid blob paths and symlinked snapshot directories are rejected or left for inspection.
- Doctor separates missing blobs, corrupt/invalid blobs, dangling audit/mark references, orphan entries and staging entries, and checks SQLite integrity. It reports a missing database without creating an empty replacement. It does not repair/delete data.

## Files and compatibility

Production changes: `lib/src/database.dart`, `snapshot_store.dart` (new), `watcher.dart`, `snap.dart`, `restore.dart`, `diff.dart`, `gc.dart`, `doctor.dart`, `cli.dart`, and `lib/dmc.dart`.

The small CLI addition makes failed manual capture return a nonzero process status. Existing command selection semantics remain. Dart callers now receive `Future<int>` from `takeManualSnapshot` and `Future<CaptureResult>` from `captureFileNow`; callers that simply await them continue to work. New internal snapshot names differ from legacy names; old names remain supported.

New tests: `test/snapshot_store_test.dart` and `test/migration_test.dart`. No preexisting tests were edited.

The user's UI work was neither edited nor formatted. Before/after SHA-256:

```text
lib/src/ui.dart
b45fb235d58c25769f1394bc5e7d6d7c8cbb7f4483b1d00bf768731edb07855a
test/ui_test.dart
3d81a9aceaff3d4edefe0a1924f5f286ed9d3c7a1ab8bedf8e148bce7b783c10
```

## Validation

Environment: macOS arm64; Dart 3.11.5. SDK executable: the Flutter-bundled Dart SDK.

| Check | Result |
| --- | --- |
| Complete test suite | **106 passed:** 83 preexisting tests and 23 new tests |
| Analyzer | No new issues; one preexisting `unused_element` warning at `lib/src/ui.dart:1387` for `_shiftArtLineLeft`; analyzer exit 2 because of that warning |
| Phase 1 acceptance | Legacy migration/restore/redo; captured-byte hash under source mutation; missing/corrupt diff/restore; marked retention; injected DB failure; interrupted GC all passed |
| Additional failure coverage | Publication obstruction, damaged dedup target, failed preimage, group restore/redo integrity preflight, failed GC transaction rollback, malformed tombstone and unsafe blob paths |
| Packaged executable | `dart build cli -o /tmp/dmc-phase1-build` passed, including SQLite native assets |
| Packaged recovery smoke | Init → snapshot → explicit-ID diff → preview → restore → redo → doctor → GC dry-run passed on a disposable project with spaces in a filename |
| Diff hygiene | `git diff --check` passed |

Development tests exposed and corrected a temporary-directory API mistake and a changed max-size warning. These results are from the corrected implementation.

Temporary evidence: `/tmp/dmc-phase1-tests.log`, `/tmp/dmc-readiness-probes.log`, `/tmp/dmc-compiled-smoke.py`, `/tmp/dmc-readiness-probes_test.dart`, `/tmp/dmc-phase1-build`. These are disposable; durable conclusions are recorded here and in the audit.

## Remaining boundaries

1. This is snapshot integrity, not complete project checkpoints. Baseline/readiness, complete manifests, attribution, operation journals, conflicts and cross-process workspace locks are not implemented.
2. Foreign-key enforcement is enabled, but legacy tables are not rebuilt to add constraints. Existing dangling references are reported, not removed. New checkpoint tables need explicit constraints in Phase 3.
3. Interruption is covered with deterministic fault injection. Actual power cuts, disk exhaustion and process termination at every boundary were not tested. Snapshot directories are not explicitly synced after rename; SQLite `FULL` does not establish durability for external blob directory entries. Do not claim whole-vault power-loss atomicity. See [SQLite synchronous documentation](https://www.sqlite.org/pragma.html#pragma_synchronous) and [Dart flushSync](https://api.dart.dev/dart-io/RandomAccessFile/flushSync.html).
4. A captured byte buffer can reflect an unstable concurrently written source. Its stored hash is accurate, but a stable version or simultaneous multi-file view is not established. Size/binary policies deliberately exclude files.
5. Restore writes directly to destinations and records events afterward. Group preflight cannot prevent mid-apply failure or subsequent outside edits. Workspace and parent symlinks remain Phase 2 blockers.
6. GC protects references committed when candidates are selected. Other commands can race to reference old IDs without operation locking/pinning. Concurrent restore/GC safety is not guaranteed.
7. Doctor can observe transient orphan/staging entries during capture. Stop writers before diagnosing persistent findings. No automatic orphan repair was added.
8. Migration fixtures use actual SQLite legacy schemas and real blobs, but are not archived vaults produced by every historical binary. Windows, Linux, macOS Intel and clean installer tests remain outstanding.

Phase 1 is ready for review. This is not a product release approval.
