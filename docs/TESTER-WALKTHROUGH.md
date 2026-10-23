# Try dmc: your first recovery

This is a short, supervised test drive for development build **1.1.0-dev.5**. It should take about fifteen minutes. Use a new folder with throwaway text files, not your important project.

dmc remembers saved file versions. In this exercise, you will change a file, bring back its original contents, and then bring back your newer edit.

## Before you begin

Use the build and checksum supplied by the maintainer. Keep the full extracted bundle together. The [README](../README.md#get-the-right-build) explains installation and platform limitations.

Open your terminal and run:

```sh
dmc --version
```

It should say `dmc version 1.1.0-dev.5`. If it says something else, stop and check which build you installed. If the command isn't found, use the executable's full path or ask for installation help.

## 1. Make a small test folder

Create a new folder named `dmc-test-drive`. Open it in your editor. Inside it, create `notes.txt` containing:

```text
Version one
```

Save the file. Open a terminal **in that folder**. Your editor's “Open in Integrated Terminal” option may help. Keep using this same folder throughout the exercise.

## 2. Turn on protection

Run these commands one at a time:

```sh
dmc init
dmc start
dmc status
```

`init` creates the local history folder. `start` first remembers the eligible files already present, then watches for changes. Wait for its **Ready** message.

The status output should include:

```text
Protection: ready
```

If it says “not ready,” do not move on. Run `dmc doctor` and share the reported problem with the person guiding the test. Readiness does not mean every kind of file is protected; the README lists exclusions.

## 3. Begin a checkpoint

Run:

```sh
dmc checkpoint begin --label "first test" --source manual
```

The result must say the checkpoint is `open` and that work may begin. Save the checkpoint ID, which starts with `cp_`. If the command reports `invalid`, a fatal error, or a nonzero result, stop: the checkpoint did not authorize the test change.

Now inspect the open manifest:

```sh
dmc checkpoint show YOUR_CHECKPOINT_ID
```

Replace `YOUR_CHECKPOINT_ID` with the ID you just received. The output should list `notes.txt` as protected and its after-state as pending.

The checkpoint ID identifies the whole before/after interval. You will use that same ID to inspect, restore, and redo the test change.

## 4. Make an edit

In your editor, change the file to:

```text
Version two
```

Save it. Create a second text file named `created.txt` containing `New file`, then run:

```sh
dmc checkpoint close YOUR_CHECKPOINT_ID
dmc checkpoint diff YOUR_CHECKPOINT_ID
dmc checkpoint show YOUR_CHECKPOINT_ID
dmc stop
dmc log
```

Close should report a verified post-run manifest. Diff should classify `notes.txt` as modified and `created.txt` as created. Show should list their before/after presence. A rename would appear as a deletion plus a creation.

Stopping waits for pending watcher saves to finish. You should also see entries for the original and newer file versions in the regular log.

For this trial, leave the watcher stopped and do not edit the file during recovery. This makes the result easy to understand.

## 5. Preview the whole checkpoint restore

```sh
dmc checkpoint restore YOUR_CHECKPOINT_ID
```

Preview is the default. It should report two affected files and say to re-run with `--apply`. Open both files: `notes.txt` should still contain `Version two`, and `created.txt` should still exist.

If the preview doesn't match what you expected, stop here and keep the output for feedback.

## 6. Bring back the original

```sh
dmc checkpoint restore YOUR_CHECKPOINT_ID --apply
```

Reopen or refresh `notes.txt`. It should contain:

```text
Version one
```

Your editor may ask to reload a file changed on disk. Reload it; do not save an old editor buffer over the restored file.

`created.txt` should now be absent because it was created inside the checkpoint interval.

## 7. Bring back the newer edit

```sh
dmc checkpoint redo YOUR_CHECKPOINT_ID
dmc checkpoint redo YOUR_CHECKPOINT_ID --apply
```

The first command previews the whole checkpoint. The second applies it. Refresh the files: `notes.txt` should contain `Version two` again and `created.txt` should contain `New file`.

Checkpoint redo is available only after a completed checkpoint restore. Repeating restore or redo after the workspace is already on the other side reports a conflict instead of guessing.

## 8. Check the result

```sh
dmc doctor
dmc status
```

Doctor should report no missing or corrupt snapshots, dangling references, or unresolved watcher errors for this simple exercise.

Status should report the watcher stopped and `Protection: not ready`. **That is expected: you stopped it.** Run `dmc start` again whenever you want dmc to record future edits, and wait for Ready before making them. End this exercise with the watcher stopped.

The checkpoint remains pinned against retention while you may still restore or redo it. For a throwaway exercise that you no longer need, release it:

```sh
dmc checkpoint release YOUR_CHECKPOINT_ID
```

Release is refused while a restore or redo operation is incomplete. Do not release a checkpoint you expect to restore later.

## What to tell us

Copy this checklist into your feedback:

```text
dmc version:
Operating system and processor:
Installation method:

Did start report Ready?
Did checkpoint begin report open and provide an ID?
Did checkpoint diff classify notes.txt as modified and created.txt as created?
Did the first preview leave the file unchanged?
Did checkpoint restore bring back Version one and remove created.txt?
Did checkpoint redo bring back Version two and created.txt?
Did doctor report any errors?
Which step was confusing, slow, or surprising?

If something failed:
Command entered:
What I expected:
What happened instead:
```

Remove private folder names and file contents before sharing output. Do not attach your `.dmc/` folder: it contains saved copies of file contents. Use GitHub Issues if you have repository access, or the feedback route supplied with your test build.

## What this test does not establish

This exercise demonstrates a verified pre/post checkpoint manifest plus conflict-aware whole-checkpoint restore and redo. It does not deliberately interrupt an operation. If an apply returns exit code `6`, stop editing, run `dmc status`, save the operation ID, and ask the facilitator whether to run `dmc checkpoint recover OPERATION_ID --resume` or `--rollback`. Bursts, tasks, marks, and `snap` do not provide the same checkpoint guarantees.

Keep Git and independent backups. Do not move from this exercise to relying on dmc for important work merely because the test passed.

## Facilitator notes

- Give each tester the same identified build and a fresh folder. Confirm the installed version before interpreting feedback.
- Observe their first attempt before explaining confusing output. Record friction in installation, readiness, checkpoint IDs versus snapshot IDs, change classification, preview and editor reload behavior.
- If a command fails, stop the exercise and preserve the small sample folder. Don't repeatedly retry restore on unexpected state.
- After the basic exercise, supervised optional tests can cover a filename with spaces, a deleted file, a rename, and Ctrl+C while watching. Continue using disposable files.
- Before a broader trial, require passing CI for the exact advertised platforms and review the remaining release gates in the [Phase 5 handoff](PHASE5-IMPLEMENTATION.md).
