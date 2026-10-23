---
title: Checkpoints
description: Record a verified before/after manifest of one agent run.
---

A **checkpoint** covers one serialized run — an agent session, a refactor, a
formatter pass. It is the strongest guarantee dmc offers: a verified
before-state, a verified after-state, and a recovery path that refuses to guess.

## Begin

```sh
dmc checkpoint begin --label "refactor auth" --source haven
```

Begin scans the workspace and records the presence and hash of every eligible
file. It only succeeds in a clean state:

- The workspace must be initialized (`dmc init`).
- No other checkpoint may be active in a blocking state.
- Any fatal scan issue fails the begin — resolve it and start a new checkpoint.

The result is a checkpoint ID (`cp_…`) in `open` state, plus a list of
**exclusions**: ignored, binary, oversized, and linked paths that are outside
the checkpoint guarantee. Exclusions are shown, never hidden.

## Work, then close

Do the work — with the agent, or by hand — then stop all writers and close:

```sh
dmc checkpoint close <checkpoint-id>
dmc checkpoint show <checkpoint-id>
dmc checkpoint diff <checkpoint-id>
```

`diff` classifies each path as `modified`, `created`, or `deleted`. A rename
appears as one deletion plus one creation. Between begin and close, the policy
is re-checked: if ignore rules or config changed, the close is invalidated
instead of pretending the interval is intact.

## Lifecycle

| Status | Meaning |
| --- | --- |
| `creating` | Begin is capturing the before-state |
| `open` | Work may proceed; the after-state is pending |
| `closing` | Close is verifying the after-state |
| `closed` | Verified before/after manifest; ready to restore or redo |
| `invalid` | Capture or policy verification failed; cannot restore |
| `released` | Retention pins detached after an explicit release |

Only `invalid`, `closed`, and `released` checkpoints allow a new begin.

## Listing and inspecting

```sh
dmc checkpoint list                      # recent checkpoints + protection counts
dmc checkpoint list --limit 100          # accepted range: 1–1000
dmc checkpoint show <checkpoint-id>      # manifest + operation history
```

`show` includes the operation history, so an interrupted apply can be found
even after a restart.

## Retention

While a checkpoint may still be restored or redo'ed, its snapshots are pinned
against garbage collection. `dmc gc` preserves them. Release only when you no
longer need the checkpoint:

```sh
dmc checkpoint release <checkpoint-id>
```

Release detaches the retention pins (keeping small audit metadata), and is
refused while a restore or recovery operation is incomplete.

## Machine-readable output

Every checkpoint command supports `--json --schema-version 1` and emits exactly
one JSON object on stdout — metadata and hashes, never file contents. See the
[Haven integration contract](/docs/imported/haven-integration/).
