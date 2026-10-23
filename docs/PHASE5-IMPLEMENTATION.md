# Phase 5 implementation and review handoff

September 5, 2026. Canonical repository: `/Users/mike_h/Projects/dmc`. Development version: `1.1.0-dev.5`. These changes remain local and uncommitted on top of Phases 1–4 and the user's existing UI edits. No commit, push, release, license choice, or public distribution change has been performed.

## Review verdict

**The DMC side of Phase 5 is implemented for review. Haven can now be built against a documented, version-negotiated subprocess contract without importing Dart code or reading SQLite. This is not evidence that the real Haven application is integrated, and it is not a public-release verdict.**

The real Haven controller still needs to implement the guide, preserve workspace identity, serialize agent writes, require approval before apply, and enter recovery-required state after forced termination. Phase 6 remains the distribution and public-beta gate.

## Implemented contract

- Machine envelope schema 1 now includes `dmcVersion`, `exitCode`, command name, canonical workspace path and SHA-256 path fingerprint, command data, warnings, and errors.
- `--schema-version 1` performs explicit negotiation. Unsupported versions and unknown flags fail with exit `2` and one JSON error object before checkpoint work begins.
- `capabilities` identifies `haven-checkpoint-v1`, supported machine and manifest schemas, required commands, safety features, and cancellation follow-up.
- `checkpoint list` returns recent checkpoint IDs, status, protection/change/exclusion/fatal counts, and operation records. The default limit is 50; accepted limits are 1–1000.
- `checkpoint show` includes operation history, allowing Haven to recover an operation ID after process death without database access.
- Restore/redo previews always return `operationId: null`. Applied operations and every recovery result expose the operation ID.
- Machine results expose metadata and hashes but never captured file contents. The compiled harness places a unique secret string in fixture content and rejects any JSON response containing it.
- Missing checkpoint IDs now consistently use lifecycle exit class `3`; exit class `5` remains reserved for missing or corrupt required stored data.

## Compiled-process evidence

`tool/haven_reference.dart` builds no in-process dependency on DMC. It invokes a supplied compiled executable with argument arrays in a disposable workspace whose path and filenames contain spaces, quotes, and Unicode. It exercises capabilities, incompatible schema, unknown flag, initialization, begin, close, list, show, diff, restore preview/apply, redo preview/apply, and release.

`tool/haven_contract_test.dart` is an explicit integration-test target that builds the native CLI and runs that reference lifecycle. It also runs two forced-termination scenarios against the compiled executable:

1. Terminate a large `checkpoint begin` after the durable `creating` state appears, verify all workspace files remain unchanged, discover the checkpoint through `checkpoint list`, and release it.
2. Terminate a multi-file restore after an `applying` journal appears, discover the operation through `checkpoint show`, resume it, and verify the first and final files reach the intended state.

These tests establish defined process-death behavior on the locally tested filesystem. They do not simulate sudden power loss, kernel failure, disk-full behavior, or every journal instruction boundary.

## Verification

| Check | Result |
|---|---|
| Locked dependency resolution | Passed with `dart pub get --enforce-lockfile` |
| Complete unit/regression suite | 154 tests passed sequentially |
| Explicit compiled Haven integration target | 3 tests passed: full lifecycle, capture cancellation, journaled apply cancellation/recovery |
| Analyzer gate | Passed with only the preserved `_shiftArtLineLeft` warning in `lib/src/ui.dart` |
| Native build | Produced `/tmp/dmc-phase5-final/bundle/bin/dmc`; reports `1.1.0-dev.5` |
| Packaged smoke | Passed help/version, schema negotiation, watcher lifecycle, legacy recovery, checkpoint list/begin/close/show/diff/restore/redo/release, doctor, GC, and invalid command behavior |
| Standalone Haven reference harness | Passed against the native bundle |

The configured remote matrix has not run for this uncommitted revision. These results are local macOS arm64 evidence.

## Files changed in Phase 5

Production and contract:

- `lib/src/machine_output.dart`
- `lib/src/cli.dart`
- `lib/src/checkpoint_service.dart`
- `lib/src/checkpoint_repository.dart`
- `lib/src/checkpoint_operation_repository.dart`
- `lib/src/checkpoint_restore_service.dart`
- `lib/src/version.dart`
- `pubspec.yaml`

Tests and executable harness:

- `test/checkpoint_test.dart`
- `tool/haven_contract_test.dart`
- `tool/haven_reference.dart`
- `tool/smoke_bundle.dart`

Documentation:

- `README.md`
- `AGENTS.md`
- `CHANGELOG.md`
- `docs/HAVEN-INTEGRATION.md`
- `docs/PHASE5-IMPLEMENTATION.md`
- `docs/TESTER-WALKTHROUGH.md`

The Phase 5 work does not edit `lib/src/ui.dart` or `test/ui_test.dart`.

## Remaining gates

1. Connect the actual Haven process controller and test its UI, approval, cancellation, restart, and recovery states against this contract.
2. Run the exact revision through configured macOS, Linux, and Windows CI. Local compiled cancellation evidence is currently macOS arm64 only.
3. Measure large-repository scan and preview times before choosing Haven's final progress and timeout UX.
4. Exercise disk-full, database-write failure, sudden power loss, signing/notarization, installer upgrade/uninstall, archive checksum, and rollback scenarios in Phase 6.
5. Keep legacy per-file, burst, task, mark, snap, and terminal-UI restore behavior out of Haven's checkpoint path. They do not use the whole-checkpoint journal contract.

Phase 5 stops at this review boundary. Phase 6 release hardening and real Haven application work have not started in this implementation.
