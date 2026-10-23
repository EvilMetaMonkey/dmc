---
title: What is Haven?
description: A VS Code review cockpit that proposes local-model edits, waits for approval, and recovers through dmc.
---

Haven is a **VS Code extension** for working with local models on real code —
without handing an agent unsupervised write access. It proposes edits, shows
you exactly what would change, and only applies after explicit approval. Edits
land through dmc checkpoints, so every applied change can be restored.

Current preview: **Haven 0.7.5** (`haven-0.7.5.vsix`), installed manually from
an invited build.

## How it fits with dmc

Haven never imports dmc's code or reads its database. It drives the compiled
`dmc` executable through the versioned
[`haven-checkpoint-v1` contract](/docs/imported/haven-integration/) — an
argument-array subprocess interface with one JSON object per command.

That means:

- dmc stays a standalone tool you can use with no Haven at all.
- Haven stays a review layer; dmc remains the only component that writes
  recovery journals or restores files.
- A missing or mismatched dmc version is detected before work starts, and the
  run is refused.

## The safety posture

- **You approve everything.** Proposals arrive as immutable diffs; apply is a
  separate, explicit approval step.
- **The original project is read, never written.** Model work happens in an
  isolated *pilot copy*.
- **Local only.** Model requests go to your LM Studio endpoint on loopback.
  Haven adds no telemetry and executes no model-chosen commands.
- **Fail closed.** Malformed proposals, changed files, dirty buffers, partial
  writes, and interrupted operations are blocked or surfaced — never
  auto-repaired or silently retried.
- **Honest bounds.** 16 KB per file, one applied run per copy, targeted edits or
  full-file rewrites. The limits are visible in the UI.

## Requirements and bounds

| | |
| --- | --- |
| Editor | VS Code `^1.95.0`, trusted single-folder workspace |
| Model | LM Studio server (default `http://127.0.0.1:1234/v1`) |
| Recovery | A supported `dmc` bundle (`1.1.0-dev.5.1` for rollback workflows) |
| Not supported | Remote/virtual/multi-folder workspaces, Restricted Mode, autonomous agents |

## Next

- [Pilot workflow](/docs/haven/pilot-workflow/) — the end-to-end review loop.
- [Integration contract](/docs/imported/haven-integration/) — for other tools
  driving dmc.
