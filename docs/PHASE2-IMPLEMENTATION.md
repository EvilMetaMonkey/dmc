# Phase 2 implementation and review handoff

September 4, 2026. Canonical repository: `EvilMetaMonkey/dmc`. Development version: `1.1.0-dev.2`. These are local, uncommitted changes on top of Phase 1 and the user's existing UI edits. No release, push, visibility change, or license selection has been performed.

## Review verdict

**Phase 2 implementation is ready for code review and a supervised exercise on a disposable project. It is not clearance for unsupervised recovery on testers' important projects.** Local verification is on macOS arm64. The configured Windows, Linux, and Intel macOS CI runs still need to pass on the exact distributed revision.

The watcher now establishes a baseline, reports readiness, handles more filesystem changes, and drains pending work before shutdown. That fixes important gaps in per-file history. It does not yet establish a complete project checkpoint or make multi-file restore recoverable after a crash. Those remain Phases 3 and 4.

## What changed

### Workspace paths and exclusions

- Shared path validation checks existing components against the resolved workspace root. It rejects outside paths, reserved `.dmc`/`.git` file targets, and symlinks below the root, including links inside the vault. Internal links and external links are both excluded.
- The workspace root itself can resolve through a filesystem alias; components below it must satisfy the exclusion policy. Capture and restore recheck paths around reads/writes. These checks reduce ordinary path hazards; they are not a hostile-process sandbox or an OS-level race-free open protocol.
- A directory-at-a-time scanner prunes ignored subtrees before descent, avoids following links, and reports exclusions and scan failures. Manual snap and watcher baseline refuse capture when the scan detects unsupported policy or traversal errors.
- Root `.gitignore` and `.dmcignore` have a documented subset: anchoring, directory patterns, `*`, `**`, and `?`. Negation, character classes, Git escapes, and nested `.gitignore` in scanned directories fail explicitly. Stop and restart after changing ignore policies; full Git compatibility is not claimed.
- New initialization adds `.dmc/.gitignore` to keep the raw history vault out of ordinary Git adds. Existing rules are preserved. This does not untrack a vault that someone previously committed or erase captured secrets.

### Watching and readiness

- Start is asynchronous. Per-directory subscriptions are installed during traversal before baseline reads, and arriving events are queued until the baseline and queued changes are reconciled.
- Every restart scans current eligible files and records known-path deletions. It cannot recreate intermediate versions written while dmc was stopped.
- Create/modify/delete/move events, move destinations, directory changes, and temp-file replacement feed the capture queue. A two-second reconciliation scan provides fallback coverage for missed events. Unchanged contents are deduplicated by hash.
- Captures run serially. Watcher and restore-preimage reads check file metadata before/after reading; unstable watcher reads receive up to three attempts. This is a bounded consistency check, not a lock on external editors.
- Stop is asynchronous and idempotent. It stops event intake, cancels subscriptions/timers, waits for in-flight work, drains pending paths, performs a final reconciliation, persists the result, and only then closes the database.
- Persistent health records distinguish starting, ready, degraded, stopping, stopped, and failed states. Status/doctor expose capture, scan, subscription, and health errors plus exclusions. A running process alone no longer means protection is ready.
- Retention is explicit through `gc`; startup no longer prunes an older baseline before establishing coverage.

### Background process control and CLI

- A workspace file lock prevents cooperating new watchers from owning the same vault. A random-token loopback HTTP endpoint provides state and graceful stop; no saved PID is used to signal a process.
- `start` waits up to 30 seconds for authenticated readiness; `stop` waits for graceful completion. A timeout returns failure and leaves the state inspectable instead of forcibly terminating an unknown process.
- Legacy PID metadata without a control endpoint blocks startup. Stop the older watcher from its own terminal and verify it is gone before removing only its stale PID file. Old and new binaries must not share a live vault.
- CLI help, argument validation, top-level failure handling, and legacy status/log/mark/task failure codes are corrected. Output is still primarily human-readable; a stable JSON integration contract is future Phase 5 work.

### Testing, packaging, and documentation

- Added a cross-platform workflow running locked dependencies, the analyzer gate, tests, CLI bundle build, and real compiled-process smoke checks. Release jobs depend on that gate and use the same Dart 3.11.5 SDK and lockfile.
- The analyzer gate carries exactly the existing unused `_shiftArtLineLeft` warning in `lib/src/ui.dart`; other diagnostics fail. This preserves the user's UI work without silently ignoring new warnings.
- The compiled smoke check exercises native SQLite, a background watcher, duplicate-start refusal, immediate-stop capture, an explicit-ID preview/restore/redo, health, GC preview, and invalid flags.
- README now describes this unreleased build, the whole native bundle, local-data behavior, supported exclusions, recovery limits, and an exact-version exercise. The separate walkthrough is suitable for a facilitator to give to invited testers.

## Verification record

All tests use temporary fixtures. No real project history was restored or pruned during verification.

| Check | Result / boundary |
| --- | --- |
| Complete regression suite | 124 tests passed on macOS arm64, sequential execution; includes the existing UI tests |
| New Phase 2 cases | 18 tests covering baseline/first edit, native events, moves/atomic saves, immediate and in-flight stop, restart, deduplication, unstable reads, exclusions/paths, authenticated control, legacy metadata, CLI failures, and Git vault exclusion |
| Analyzer gate | Passed with only the pre-existing UI warning described above |
| Final native bundle | Built successfully; packaged smoke passed using `/tmp/dmc-phase2-final-build/bundle/bin/dmc` |
| Whitespace and preservation | `git diff --check` passed; both user UI files retained their pre-Phase-2 SHA-256 values |
| CI matrix | Configured, not run remotely in this task. Cross-platform acceptance remains open until those results exist |

One earlier full-test invocation was terminated with exit 137 while another check was running, before any test failure was reported. A sequential rerun passed, and the final suite including the added vault-exclusion test also passed. The reason for the terminated process was not established.

Reproduce from the canonical repository with Dart 3.11.5:

```sh
dart pub get --enforce-lockfile
dart test --concurrency=1
dart run tool/check_analyzer.dart
dart build cli -o build/dmc
dart run tool/smoke_bundle.dart build/dmc/bundle/bin/dmc
```

On Windows use `build/dmc/bundle/bin/dmc.exe` for the last argument. File-symlink tests may skip when the OS cannot create links; that is a coverage gap, not proof that Windows reparse points/junctions are safe.

Preserved UI hashes:

```text
lib/src/ui.dart
b45fb235d58c25769f1394bc5e7d6d7c8cbb7f4483b1d00bf768731edb07855a
test/ui_test.dart
3d81a9aceaff3d4edefe0a1924f5f286ed9d3c7a1ab8bedf8e148bce7b783c10
```

## What remains before wider testing

1. **Review this phase and run the platform matrix.** Test Windows junction/reparse behavior, case-only renames, locked files, real terminal shutdown, and clean-machine native bundle loading before advertising each platform. Automated local link tests do not settle every filesystem behavior.
2. **Implement Phase 3 checkpoints.** Explicit pre/post manifests, stable run IDs, presence states, and checkpoint inspection must replace assumptions that a burst or mark is a pre-run rollback point.
3. **Implement Phase 4 safe apply.** Restore still writes directly, can partially apply a group, and lacks durable operation journals, expected-current-state conflicts, crash resume, and shared locking/pinning across GC and restore. All public legacy and UI write routes must join that protection or be explicitly limited.
4. **Finish the invited distribution gate.** Choose access and licensing terms, publish the exact reviewed revision, test the archive/checksum installation path and upgrade/rollback, and identify the build precisely. This task did not make private assets public, update Homebrew, sign binaries, or fix the Windows installer's replacement strategy.
5. **Measure and exercise failures.** The periodic full scan favors correctness over performance and is not benchmarked for large projects. Test disk-full/process-death cases, non-UTF-8 files, file-type replacements, executable-mode expectations, concurrency, retention expiry, and doctor/GC behavior during active writes. Metadata stability checks do not guarantee an instantaneous project snapshot.

The initial diagnostic cohort should use the [tester walkthrough](TESTER-WALKTHROUGH.md), keep writers stopped during recovery, and report sanitized command/results rather than uploading vaults. Stop trials on silent data loss, a false successful restore, or readiness that conceals a known capture failure.

## Audit disposition

The [original readiness audit](TESTER-READINESS-AUDIT.md) remains a historical record of Phase 1. Phase 2 addresses its R1 path containment, R2 lifecycle, R5 ignore/vault exclusion, R6 process ownership, basic CLI errors, and the source configuration portion of R8 CI. The residual filesystem races, platform checks, and distribution execution gates above remain open. R3 complete checkpoints, R4 recoverable apply, and R7 release access/installer safety are not closed by this implementation.

Work stops here for Phase 2 review. No Phase 3 checkpoint commands or Phase 4 recovery journal have been implemented.
