# dmc tester-readiness audit and hardening-plan review

> Historical audit following Phase 1. Phases 2–4 have since been implemented locally for review; see [the Phase 4 handoff](PHASE4-IMPLEMENTATION.md), [Phase 3 handoff](PHASE3-IMPLEMENTATION.md), and [Phase 2 handoff](PHASE2-IMPLEMENTATION.md) for fixes, current verification, and remaining release gates. Findings below describe the earlier audited state, not fresh reproductions against the newer implementation.

Audit date: September 4, 2026. Canonical repository `EvilMetaMonkey/dmc`, base `e2494b3`, with the uncommitted Phase 1 implementation and preserved user UI work.

## Verdict

**No-go for an unsupervised release on testers' real projects today.** Phase 1 is a useful, tested foundation, but dmc has reproducible failures in its core recovery promise. Completeness and predictable restore behavior must come before more features or visual polish.

**A supervised exercise on disposable repositories is reasonable now**, explicitly presented as a diagnostic trial. The facilitator should control the exercise, and nobody should depend on dmc as the only copy of their work. This can validate usability while reliability work continues.

The product idea remains credible: an independent recovery tool across editors and agents can be useful. The strongest first product is a small, dependable workflow: protect before a risky run, show exactly what changed, restore it, and redo if needed. The current code provides file-history building blocks; the exact project-level promise needs Phases 2–4. Haven integration should follow that proof.

## Evidence and scope

- Read production modules covering CLI, initialization, paths, config/ignore rules, daemon, watcher/manual capture, storage/database, history selection/logging, marks/tasks, diff, restore/redo, doctor/GC, status, and UI action/restore/render paths.
- Inspected tests, README, CHANGELOG, AGENTS, package/lock configuration, Windows installer and release workflow.
- Reviewed all six phases, database/API design and acceptance gates in `DMC-Checkpoint-Hardening-Plan.md`. That original plan outside this repository was not edited; this document is its review addendum.
- Ran **106 product tests**, analyzer, an arm64 CLI bundle build, compiled recovery smoke and six diagnostic probes on temporary repositories. The diagnostic probes observed existing defects; passing probes do not mean those recovery requirements passed.
- Checked live GitHub repository/release visibility, the Homebrew formula target, unauthenticated asset access and dependency freshness.

No real user vault was used for destructive testing. The fake PID probe did not signal a real process. No source visibility, release, license, dependency, UI or Phase 2+ implementation changes were made.

This is a source and local-behavior audit, not a security certification. Windows/Linux runtime, clean-machine installers, broad dependency advisory scanning, actual disk-full/power-loss, exhaustive race testing and human terminal accessibility sessions remain unverified. Phase 1 validation details are in [PHASE1-IMPLEMENTATION.md](PHASE1-IMPLEMENTATION.md).

## Release blockers

### R1 — Workspace symlinks can write outside the project

**Confirmed with a disposable reproduction; block real-project trials.** `workspace.dart:56` checks lexical containment only. `snap.dart:43` follows links during recursive listing, capture reads through them, and `restore.dart:586` writes without validating existing parent components.

Probe: link a workspace path to a file in a second temporary directory, capture it, edit the outside file, then restore the captured ID. Capture and restore succeeded; the outside file reverted. Phase 1 protects snapshot-store filenames, not workspace path containment.

Required: shared canonical-path rules for capture/diff/restore/redo/scans and vault paths; reject escaping or excluded links; inspect existing parent components; test Windows junctions/reparse points, directory/file swaps and reserved `.dmc` paths. Cover final-component and parent-directory links. One path check does not eliminate races with external writers.

### R2 — Watcher lifecycle gaps lose recoverable versions

**Confirmed with actual macOS filesystem events.** `watcher.dart:98` subscribes without a baseline. The event handler at line 147 accepts only modify/delete. `stop()` at line 131 cancels debounce timers without draining. Foreground shutdown handles SIGINT; daemon stop uses default process termination.

| Probe | Observed result |
| --- | --- |
| Existing file, start watcher, first edit, undo | One history entry; `restorePossible=false`; original bytes were never saved |
| Simple new-file write | Captured on this Mac through an accepted event; not proof of complete create-event support |
| Rename a captured file | Old path became a tombstone; destination had no snapshot |
| Edit, stop inside debounce window | Final contents were not captured |

Required: queued baseline/reconciliation and explicit readiness; create/move/atomic-save handling; bounded retries for unstable reads; shutdown drain; persistent health/errors. Reconcile missed periods after restart. A baseline cannot recover bytes changed while dmc was absent, so coverage wording must be precise.

### R3 — Burst/task/mark recovery is not pre-run project rollback

**Confirmed; blocks the AI-run rollback claim.** `restore.dart:107` selects the latest snapshot per file within a group. A mark points at the latest burst; a task labels events. Neither is a complete pre-run manifest; reused task names can combine sessions.

Probe: save `before run` in burst 1, then `agent change` in burst 2; restore burst 2. The file still contained `agent change`. That matches the current group-selection semantics but does not undo the run that produced the group. Untouched files are absent; run-created files cannot reliably be identified for removal.

Required: explicit begin/close manifests, presence states and stable run IDs in Phases 3–4. Preserve and document legacy meanings. Do not advertise a mark, burst or `snap` as a complete project checkpoint. Task labels are not reliable agent attribution.

### R4 — Restore can partially apply or overwrite newer manual work

**Confirmed from code; crash/race effects not exhaustively exercised.** `restore.dart:567` verifies bytes, captures a preimage, writes directly to the target, then records an event. There is no pre-mutation operation journal, workspace lock, expected-current-hash conflict gate or final target-hash verification. Tombstones directly delete files. Group operations can partially apply before an I/O or audit failure.

Phase 1 catches existing corrupt group snapshots before the first write and blocks a file's write if its preimage fails. It does not make an entire apply atomic. A later manual edit can still be overwritten. A crash after mutation but before audit can make redo undiscoverable through ordinary commands. Redo selects the latest successful undo/restore event (`database.dart:571`) without a consumed-operation lifecycle.

Required: Phase 4 journal, conflicts, atomic per-file replacement, recoverable deletion and verified resume/rollback. Extend safety to legacy CLI/UI write routes or explicitly gate them during beta. Otherwise users can bypass safe checkpoint commands accidentally. Preview is not durable permission to overwrite a later state.

### R5 — Ignore semantics and private-data coverage are unreliable

**Rooted-pattern failure confirmed; other syntax gaps from code.** `ignore.dart:42` and `:105` implement a small matcher. `/secret.txt` did not match `secret.txt` in the probe. Git-style negation, special `**`, character classes, nested ignore files and escaping are not fully implemented. Directory-only information is not consistently used to distinguish files from directories.

Git's actual rules include anchoring, negation and recursive wildcard behavior; see [Git ignore documentation](https://git-scm.com/docs/gitignore). Implement the claimed compatibility or clearly define a smaller dmc syntax and warn on unsupported forms. Silently accepting ineffective exclusions is unsafe for sensitive files.

Snapshots retain raw old contents, including secrets if captured. Deleting a live secret does not delete its history. `init` does not add `.dmc/` to each user's Git exclusions. This source repository's own `.gitignore` protects only this repository. Add safe vault-exclusion/setup behavior or explicit guidance, honest local-data wording, and redacted diagnostics. Test nested projects/vaults and repository moves.

### R6 — Daemon PID liveness is not watcher identity or health

**Confirmed using a fake adapter.** `daemon.dart:123` checks liveness; `:222` compares saved metadata to the expected launch command, not the identity of the running process. Reused PIDs or editable PID metadata can cause `stop` to target another process. Legacy numeric PID files have no command metadata. Simultaneous starts can race.

Probe: supply an unrelated running PID through the fake adapter; `stopDaemon` requested termination of that PID and returned success. No real process was touched.

Required: identity/start-time validation or authenticated local handshake, validated positive PIDs, exclusive daemon lock, atomic metadata, readiness acknowledgement, graceful stop acknowledgement and persistent failure logs. Test detached native bundles as well as source execution. A live PID alone must not imply healthy protection.

### R7 — The documented installation path is blocked

**Verified live.** GitHub reports `EvilMetaMonkey/dmc` as **PRIVATE**, with latest release `v1.0.0`, published April 24, 2026. The Homebrew formula targets that release. An unauthenticated GET of its arm64 download returned **404**.

Choose invited private distribution or publicly accessible release assets. Source visibility is a separate decision; distributing public binaries does not require opening source. Give invited testers the exact tested archive and checksum, or repair public installation before advertising it. No LICENSE file is tracked; decide distribution/licensing terms before opening source instead of adding an arbitrary license.

Windows README says to download `dmc.exe`, while automation produces a ZIP with a native-assets CLI bundle. Document extracting the whole bundle and preserving its layout. `install.ps1` removes the old installation before moving the replacement; stage and verify the replacement before swapping, with rollback. Preserve the macOS `/usr/bin/dmc` collision guidance.

Evidence: [repository](https://github.com/EvilMetaMonkey/dmc), [release](https://github.com/EvilMetaMonkey/dmc/releases/tag/v1.0.0), [Homebrew formula](https://github.com/EvilMetaMonkey/homebrew-dmc/blob/main/Formula/dmc.rb). Access can change after this audit.

### R8 — Release automation does not enforce the quality gate

**Confirmed in `.github/workflows/release.yml`.** The only workflow builds four platform artifacts and checksums on version tags. It has no test/analyzer gate, real watcher scenarios, archive-install smoke, upgrade/rollback smoke or version-consistency assertion. Local success was verified only on arm64 macOS.

Add CI before Phase 2 grows. Run unit/integration and real filesystem tests on every advertised OS and make releases depend on them. Pin or record the SDK/toolchain; verify packaged SQLite after installation. Initially advertise fewer platforms if necessary. The existing UI warning may be explicitly carried for this review, then resolved in separate UI work before requiring a fully clean analyzer gate.

## Additional findings for beta readiness

| Area | Finding and action |
| --- | --- |
| Retention | Mark/audit protection is fixed, but an unchanged unmarked file can lose its only old baseline after 168 hours. Define last-known-state retention, reconciliation or clearly reported expiry. Startup currently prunes before watching. |
| Concurrency | SQL transactions serialize candidate deletion, not filesystem operations. Mark creation, restore selection, preimage reuse, audit insertion and GC can race. Specify durable pinning and an operation-lock protocol used by all mutating paths. |
| Storage growth | Audit references can pin data indefinitely; no release/expiry lifecycle exists. Orphans are reported but not automatically reclaimed. Add deliberate safe maintenance after locking exists; don't delete staging entries belonging to active captures. |
| Doctor/status | Doctor opens/migrates an existing DB, scans whole blobs, can report transient capture entries and can still throw on later DB/list errors. Define read-only versus mutating behavior, close on every failure path and report actionable categories. Status is not a coverage report and measures DB size rather than total vault size. |
| File semantics | Byte hashes do not preserve executable modes, ownership or timestamps. Stable reads, directory/file replacement, empty directories, hardlinks, case-only rename, Unicode normalization, locked files and non-UTF-8 text need explicit support/exclusion rules. Unbounded preimage capture can exhaust memory; refuse restore rather than skip its preimage. |
| Performance | No explicit query indexes beyond primary keys are present. Measure history lookup, GC and doctor on representative large repositories. Recursive scans traverse ignored directories before filtering. Add bounds and measured indexes. |
| CLI | Compiled `--help` exited 255 with an unhandled exception. Several legacy wrappers return 0 after helpers print errors, and argument/DB failures can escape the entry point. Phase 1 fixes `snap` status only. Add help, top-level error handling, strict argument checks and stdout/stderr discipline. |
| UI | Preserved user work. Some splash actions display instructions instead of performing the named action. Empty vaults cannot enter the UI; history/status do not continuously refresh, and the restore key invokes undo directly. Review menu wording, empty/failure states, restore interaction, terminal control characters and accessibility on real terminals. |
| Dependencies | `dart pub outdated` reports sqlite3 3.1.6 → 3.5.2 within constraints; dart_console 4.1.2 → 4.1.4 within constraints, with 5.1.0 a major migration. No upgrade performed. Freshness is not a vulnerability assessment: review advisories/changelogs and native bundles separately. |
| Documentation | AGENTS lists completed features as future work and says 48-hour retention; code uses 168. CHANGELOG only says initial version. README omits current functionality and blurs group history with pre-run rollback. Reconcile docs with the beta contract and assign tester builds a distinct prerelease version. |

## Required additions to the hardening plan

The main order is sound: trustworthy snapshots → reliable coverage/paths → explicit manifests → recoverable apply → integration. Keep independently reviewed phases and these additions:

1. **Move CI, daemon safety, ignore semantics and basic CLI errors forward.** Put them in Phase 2 or small prerequisites. Waiting until Phase 6 to discover platform or daemon failures is too late.
2. **Define checkpoint guarantees.** Begin/close captures an interval, including outside/manual edits; it cannot inherently identify the author of each change. Require the host to stop its agent before close/apply and explain possible interference. A sequential scan is not a simultaneous filesystem snapshot.
3. **Specify locks and pinning.** Name every participant, owner identity, timeout, stale-lock recovery and lock order. A cooperative dmc lock cannot stop arbitrary editors. Recheck expected state immediately before replacement and state residual races honestly.
4. **Complete the state machine.** Define abort/cancel/retry for interrupted creating/open/invalid/closing work, close idempotency, death after publication but before response, invalid-checkpoint inspection/release, and permitted actions in each state. Add a closing state or equivalent if needed. Every persistent state needs a recovery route.
5. **Resolve release versus foreign keys.** Released checkpoints with restrictive references still pin history unless references are safely detached or intentionally retained. Specify surviving manifest/audit data, reclamation and incomplete-operation protection. Distinguish deliberate release from broken references.
6. **Cover all accessible restore routes.** Phase 4 leaves legacy behavior available. Define how CLI/UI legacy writes join the journal/conflict system or become explicitly limited during beta.
7. **Define filesystem/durability limits.** Add stable-read retries, executable modes, case/path normalization and unsupported objects. Verify filesystem directory-entry durability separately from SQLite `FULL`. Per-file rename does not make a multi-file restore atomic.
8. **Specify migration and diagnostics.** Add a golden vault produced by the actual v1.0.0 release, backed up consistently before upgrade. Keep unknown-version refusal; prevent old binaries concurrently writing upgraded vaults. Make diagnostic exports opt-in and redact content/paths by default.
9. **Split trial gates.** Keep JSON design in Phase 3 and finalize Haven's executable contract in Phase 5. A standalone closed alpha can precede Haven after Phases 2–4 and relevant release gates pass. Every platform and the full Haven editor need not be finished before a small cohort can teach us something.

## Proposed release sequence

| Step | Work | Exit criterion |
| --- | --- | --- |
| Now | Review Phase 1 and this audit | Accept/revise storage work; no automatic Phase 2 implementation |
| Next bounded change | Phase 2 plus R1/R2/R5/R6 and basic help/error/CI work | Readiness, containment, event coverage and safe shutdown demonstrated on initially supported systems |
| Separate recovery phases | Phases 3 and 4 | Exact modify/create/delete/rename round-trip, conflict refusal, restart recovery and safe legacy/UI routes |
| Closed-alpha packaging | Relevant Phase 6 work | Tested versioned bundle/checksum, honest quickstart/exclusions, chosen distribution terms and upgrade/recovery procedure |
| Small invited cohort | Suggested 5–10 developers | Observe installation, understanding, recovery and return use; stop on silent loss or false success |
| Haven / wider beta | Phase 5 and expanded platform matrix | Compiled subprocess lifecycle and cancellation work; critical recovery failures resolved |

Before unsupervised testers, record at least 20 destructive/recovery scenarios with expected and actual hashes/presence. Include first edit; create/delete/rename; atomic save; shutdown/restart; ignored/private/binary/large/unreadable files; parent symlink; source mutation; corruption; DB/disk failure; GC pinning; concurrency; manual drift; repeated restore/redo; and process death at every journal boundary. Run high-risk cases on every advertised OS. Unit-test counts do not replace this matrix.

Give the first cohort a sample project and ten-minute exercise: initialize, wait for explicit readiness, begin a checkpoint, make a deliberate multi-file change, close, inspect, restore, redo and check health. Provide a feedback template with version/OS, command sequence, expected/actual behavior and sanitized diagnostics. Don't request raw source/vault uploads by default. Measure whether people understand and reuse recovery, not only whether they like the dashboard.

**Next priority: Phase 2 with these audit additions, approved and reviewed as a bounded change. No Phase 2 or checkpoint implementation was performed in this turn.**
