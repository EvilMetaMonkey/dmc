---
title: Status & support
description: Current versions, platform evidence, licensing state, and how to get a build.
---

:::caution[Development preview]
dmc and Haven are unreleased development previews for invited trials. Passing
local tests is not a public-release verdict. Licensing, distribution, and
release gates are still open.
:::

## Current versions

| Product | Version | Form |
| --- | --- | --- |
| dmc | `1.1.0-dev.5.1` | Compiled platform bundles (GitHub releases / maintainer archive) |
| Haven | `0.7.5` | VS Code preview VSIX (`haven-0.7.5.vsix`) |

## How to get a build

1. Request an invited trial build from the maintainer (GitHub Issues or the
   feedback route supplied with your invitation).
2. Receive an exact archive plus its SHA-256 checksum.
3. Verify the checksum, extract the whole bundle, and confirm
   `dmc --version` before opening any project.

Never distribute or rely on an unverified older release for these workflows.

## Platform evidence

| Platform | Status | Notes |
| --- | --- | --- |
| macOS arm64 | Verified locally | Compiled bundle, smoke test, integration harness |
| macOS x86_64 | CI + release bundles | Configured in the GitHub Actions matrix |
| Linux x86_64 | CI + release bundles | Configured in the GitHub Actions matrix |
| Windows x86_64 | CI + release bundles | Symlink tests may need Developer Mode |

CI is configured for all listed platforms; check the results for the exact
revision you install. The local validation environment for the current preview
is macOS arm64.

## Licensing

No public license has been granted yet. Preview builds are shared for evaluation
and do not grant an open-source license. A licensing and distribution decision
is part of the remaining release work.

## What is intentionally not promised yet

- Automatic storage caps and orphan repair (GC is explicit, with `--dry-run`).
- Windows ACL preservation (POSIX modes are recorded and restored on macOS/Linux).
- Proof of authorship for changes inside a checkpoint interval.
- A hosted or synced vault: history is repo-local by design.

## Reporting issues

Include the exact version, OS/processor, commands, expected vs actual result,
and whether the watcher was Ready. **Never attach your `.dmc/` vault** — it
contains raw saved file contents and may contain secrets — and remove private
paths and file contents from logs before sharing.
