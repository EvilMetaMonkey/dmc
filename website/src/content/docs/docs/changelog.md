---
title: Changelog
description: Recent changes to the dmc and Haven development previews.
---

These previews move quickly. This page summarizes recent milestones; the full
histories live in each source repository.

## dmc

### 1.1.0-dev.5.1 — current

- Add `checkpoint recover <op> --resume|--rollback --preview` — inspect
  journal-bound recovery targets and conflicts without changing workspace
  files, SQLite sidecars, or operation state.
- Verify saved pre-operation recovery bytes during the shared preflight before
  rollback starts.
- Advertise `operationRecoveryPreview` under machine schema 1.

### 1.1.0-dev.5

- Finalize the Haven machine envelope schema 1 (version, exit code, workspace
  identity) with explicit `--schema-version 1` negotiation.
- Add `checkpoint list`; include operation history in `checkpoint show`.
- Define cancellation outcomes and prove detection/recovery with
  forcibly-terminated compiled subprocess tests.
- Standalone Haven reference harness covering paths with spaces, quotes, and
  Unicode; machine output never contains captured file contents.

### 1.1.0-dev.4

- Conflict-aware whole-checkpoint restore and redo; preview by default,
  `--apply` required.
- Schema-version 3 operation journals with exact pre-operation content, hashes,
  and POSIX modes — persisted before the first workspace mutation.
- Per-file atomic replacement with flushed temp files and same-directory
  renames; `checkpoint recover --resume|--rollback`.
- Status and doctor surface incomplete operations; release is blocked while
  recovery is incomplete.

### Earlier

- `1.1.0-dev.3` — checkpoint manifests v2, begin/close/show/diff/release,
  versioned JSON schema 1, `capabilities`.
- `1.1.0-dev.2` — hardening: snapshot integrity, migrations, preimages, watcher
  drains, path/ignore safety, authenticated daemon control, CI.
- `1.0.0` — initial version.

## Haven

### 0.7.5 — current

- **Roll Back Interrupted Pilot Recovery**: previews dmc's actual
  pre-operation target, requires approval, rechecks under editor protection,
  and verifies saved bytes, permissions, terminal status, and editor refresh.

### 0.7.4

- Wait for the pilot editor to match verified recovered disk contents before
  reporting success; dirty buffers are never discarded.

### 0.7.3 / 0.7.2 / 0.7.1 / 0.7.0

- Resume interrupted pilot recovery; close unapplied pilot edits; prefer the
  validated copy in this window; continue from a completed pilot.

### 0.6.x

- Discard current proposal; finish interrupted pilot edits; targeted edits —
  up to eight exact replacements reviewed and recovered as one batch.

## Full histories

- dmc: `CHANGELOG.md` in the dmc repository.
- Haven: the Haven repository README and per-phase documents.
