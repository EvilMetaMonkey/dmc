---
title: Recovery
description: Preview-first restore, redo, and journaled recovery for interrupted operations.
---

Recovery is the point of dmc. Every recovery operation is preview-first,
conflict-aware, and journaled.

## Before you recover

1. Stop every writer: the agent, the editor's save hooks, formatters.
2. Stop the watcher: `dmc stop`.
3. Run the preview. Do not edit affected files while a recovery is pending.

## Restore a checkpoint

```sh
dmc checkpoint restore <checkpoint-id>          # preview — changes nothing
dmc checkpoint restore <checkpoint-id> --apply  # performs the restore
```

The preview checks every affected path and every required snapshot **without
creating a journal or changing files**. Apply proceeds only when all paths still
match the recorded post-run state:

- Modified and deleted files are restored to their before-state.
- Files created during the interval are removed.
- Any drift, missing data, corrupt data, linked path, or a running watcher
  blocks the *whole* operation before the first write.

## Redo

After a completed restore, bring the agent's work back:

```sh
dmc checkpoint redo <checkpoint-id>          # preview
dmc checkpoint redo <checkpoint-id> --apply  # apply
```

Redo is available only after a completed restore. If the workspace is already
on the other side of the operation, dmc reports a conflict instead of guessing.

## Interrupted operations

Apply writes a per-file journal — exact pre-operation content, presence, hashes,
and POSIX modes — **before** mutating the workspace, and replaces files through
flushed temp files and same-directory renames.

If an apply exits with code `6`, or the process dies mid-operation:

```sh
dmc status                                     # shows the incomplete operation
dmc checkpoint recover <operation-id> --resume
dmc checkpoint recover <operation-id> --rollback
```

- `--resume` continues the operation to its intended end state.
- `--rollback` returns every target to the state captured immediately before
  the failed apply.
- Add `--preview` to inspect exact recovery targets and conflicts without
  changing anything.

The full multi-file operation is not a single filesystem transaction. Journals
make completed steps detectable and each file replacement atomic, but an
interruption can temporarily leave a mix of before/after states until resume or
rollback completes. That is why the journal comes first.

## Exit classes

| Exit | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Runtime or database failure |
| `2` | Invalid arguments or incompatible schema |
| `3` | Checkpoint or operation missing / wrong lifecycle state |
| `4` | Workspace conflict or unsafe state blocks mutation |
| `5` | Required stored data missing or corrupt — zero writes |
| `6` | A journaled operation is incomplete — recover it |

## Release

```sh
dmc checkpoint release <checkpoint-id>
```

Release detaches retention pins after recovery is complete. It is refused while
an operation is incomplete. Do not release a checkpoint you still expect to
restore.
