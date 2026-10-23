---
title: What is dmc?
description: A local shadow-history vault and recovery engine for AI-assisted coding.
---

dmc is a local shadow-history version control tool that runs **beside** your
editor. It records eligible file versions in a repo-local `.dmc/` folder as they
are saved, groups them into verified checkpoints, and restores them — before you
commit.

Its purpose is narrow and deliberate:

> **dmc is a trusted rollback safety net for AI coding agents.**

It is **not** a GitHub replacement. Git is source control and history; dmc is
the safety net under the risky edit that hasn't been committed yet.

## The model

- **Shadow history.** While dmc runs, each saved version of an eligible text
  file is hashed and stored in the vault. Duplicate content is deduplicated.
- **Checkpoints.** `dmc checkpoint begin` records the before-state of every
  eligible file. After the work stops, `dmc checkpoint close` records a verified
  after-manifest. The pair is the unit of recovery.
- **Preview first.** Recovery operations show exactly what they would change and
  require an explicit `--apply` to touch the workspace.
- **Journaled apply.** Every apply writes a per-file operation journal before
  the first write. An interrupted run can be resumed or rolled back.
- **Single-file history.** The older per-file workflow — `dmc log`, `dmc diff`,
  `dmc restore`, `dmc undo`, `dmc redo` — remains available for ordinary
  history.

## A 30-second example

```sh
dmc init
dmc checkpoint begin --label "refactor auth" --source manual
# …the agent edits files…
dmc checkpoint close <checkpoint-id>
dmc checkpoint diff <checkpoint-id>
dmc checkpoint restore <checkpoint-id> --apply
```

Each step checks its preconditions. If a path drifted, if a snapshot is
missing or corrupt, or if the vault is linked, the operation stops before
writing instead of guessing.

## What dmc will not do

- It cannot recover versions it never captured — it only records while running
  with a ready baseline.
- It is not a backup: the vault shares the disk with your project.
- It does not prove who caused a change inside a checkpoint interval.
- It excludes binary files, oversized files, ignored paths, and links by design.

## Next

- [Getting started](/docs/dmc/getting-started/) — install a build and protect a
  disposable folder.
- [Checkpoints](/docs/dmc/checkpoints/) — begin, close, list, show, diff.
- [Recovery](/docs/dmc/recovery/) — preview, apply, redo, resume, roll back.
