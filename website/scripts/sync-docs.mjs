#!/usr/bin/env node
/**
 * Sync selected markdown from the dmc repository's docs/ folder into the
 * Starlight content collection so the site always renders the reviewed,
 * versioned documents instead of hand-copied duplicates.
 *
 * Source of truth:  <repo>/docs/*.md          (this repo)
 * Target:           website/src/content/docs/docs/imported/*.md
 *
 * The script is idempotent and safe to run on every build. If the source
 * docs folder is missing (e.g. the website folder is copied elsewhere),
 * it warns and exits 0 so the build still succeeds with the hand-authored
 * pages.
 */

import { mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const sourceDir = join(here, '..', '..', 'docs');
const targetDir = join(here, '..', 'src', 'content', 'docs', 'docs', 'imported');

/** file -> { title, description } */
const DOCS = {
  'HAVEN-INTEGRATION.md': {
    title: 'Haven integration contract',
    description:
      'The versioned subprocess contract (machine schema 1) for driving dmc from another process.',
  },
  'RECOVERY-PREVIEW.md': {
    title: 'Recovery preview details',
    description:
      'What checkpoint recover --preview reports and how clients should gate on it.',
  },
  'TESTER-WALKTHROUGH.md': {
    title: 'Tester walkthrough',
    description:
      'A supervised fifteen-minute recovery exercise on a disposable folder.',
  },
};

function stripLeadingH1(markdown) {
  // Starlight renders the frontmatter title as the page heading; drop the
  // document's own duplicate first-level heading when importing.
  return markdown.replace(/^#\s+.*\r?\n+/, '');
}

function withFrontmatter(markdown, { title, description }) {
  const trimmed = markdown.trimStart();
  if (trimmed.startsWith('---')) {
    // Already has frontmatter; leave it untouched.
    return markdown;
  }
  const note =
    `:::note[Synced from the dmc repository]\n` +
    `This page is imported from \`docs/\` at build time and may not resolve ` +
    `relative links. Edit the source document upstream; this copy refreshes on ` +
    `every build.\n:::\n\n`;
  return `---\ntitle: ${JSON.stringify(title)}\ndescription: ${JSON.stringify(description)}\n---\n\n${note}${stripLeadingH1(markdown)}`;
}

async function main() {
  if (!existsSync(sourceDir)) {
    console.warn(
      `[sync-docs] Source folder not found: ${sourceDir} — skipping import.`
    );
    return;
  }

  await rm(targetDir, { recursive: true, force: true });
  await mkdir(targetDir, { recursive: true });

  const available = new Set(await readdir(sourceDir));
  let copied = 0;

  for (const [fileName, meta] of Object.entries(DOCS)) {
    if (!available.has(fileName)) {
      console.warn(`[sync-docs] Missing source file: ${fileName} — skipped.`);
      continue;
    }
    const source = await readFile(join(sourceDir, fileName), 'utf8');
    const outName = fileName.toLowerCase();
    await writeFile(join(targetDir, outName), withFrontmatter(source, meta), 'utf8');
    copied += 1;
    console.log(`[sync-docs] ${fileName} -> imported/${outName}`);
  }

  console.log(`[sync-docs] Done: ${copied} document(s) imported.`);
}

main().catch((error) => {
  console.error('[sync-docs] Failed:', error);
  process.exitCode = 1;
});
