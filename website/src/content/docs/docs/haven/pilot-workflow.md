---
title: Pilot workflow
description: Enroll an isolated copy, ask a local model, review the diff, apply through dmc, and recover if anything is interrupted.
---

The pilot workflow is Haven's end-to-end loop. Everything happens in an
**isolated copy** of your project; the original is read, never written.

## 1. Enroll an isolated pilot copy

Run **Haven: Create Fresh Pilot Copy** and approve copying the current source.
No model request is sent during creation. The copy gets its own workspace and a
`dmc` enrollment; the original folder is untouched.

## 2. Ask the model

Open the pilot copy and run **Haven: Ask Model About Pilot Copy**.

- Requests go to your configured LM Studio endpoint (loopback only).
- Choose **Targeted edit** for exact search/replace changes (up to eight
  non-overlapping replacements in one file, reviewed as one batch), or
  **Full-file rewrite** for a complete replacement.
- The entire file (up to 16 KB) is sent; targeted mode reduces required output,
  not input context.

## 3. Review and apply

The proposal arrives as an immutable diff in a regular editor tab.

- Nothing is applied by the model — **Apply Pilot Copy Change** is a separate
  action that asks for your approval.
- Apply runs under a dmc checkpoint, so the change is recoverable whether the
  apply completes or fails.
- One applied run per copy; continue work by starting a new copy from the
  approved result (**Continue From Completed Pilot**), keeping earlier copies
  and checkpoints intact.

## 4. Test recovery

- **Restore Pilot Copy** returns to the copy's starting point (including
  previously accepted edits from earlier copies).
- **Redo Pilot Copy** brings the approved result back.
- Both preview first and verify exact contents and file presence after each
  direction.

## 5. If something is interrupted

Forced termination mid-operation is not hidden. Haven surfaces the pending
operation and offers the documented follow-ups:

| Situation | Command |
| --- | --- |
| Apply was interrupted; saved file matches protected original | **Close Unapplied Pilot Edit** |
| Restore/Redo pending, file matches approved before/after bytes | **Resume Interrupted Pilot Recovery** |
| Rollback had started | **Roll Back Interrupted Pilot Recovery** |
| No longer want the proposal | **Discard Current Proposal** (changes nothing) |

Absent, partial, or manually modified files remain blocked. Dirty editor
buffers are never discarded; if the editor does not synchronize with verified
disk contents within five seconds, Haven reports an actionable error instead of
silently finishing.

## Limits to keep in view

- 16 KB per file; larger files are rejected rather than truncated.
- One applied run per copy; sequential work uses separate copies.
- A valid match is not a promise the change fulfills your request — review
  every diff.
- Real-project context access, inline autocomplete, and multi-file edits are
  proposed scope, not current features.
