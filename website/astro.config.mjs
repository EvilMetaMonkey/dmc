// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

const repo = 'https://github.com/EvilMetaMonkey/dmc';

export default defineConfig({
  integrations: [
    starlight({
      title: 'dmc + Haven',
      description:
        'Local-first rollback and review for AI coding agents. dmc is the recovery engine; Haven is the review cockpit.',
      favicon: '/favicon.svg',
      customCss: [
        '@fontsource-variable/inter',
        '@fontsource-variable/jetbrains-mono',
        './src/styles/starlight-theme.css',
      ],
      social: [
        { icon: 'github', label: 'GitHub', href: repo },
      ],
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Overview', slug: 'docs' },
            { label: 'Status & support', slug: 'docs/status' },
            { label: 'Changelog', slug: 'docs/changelog' },
          ],
        },
        {
          label: 'dmc — recovery engine',
          items: [
            { label: 'What is dmc?', slug: 'docs/dmc' },
            { label: 'Getting started', slug: 'docs/dmc/getting-started' },
            { label: 'Checkpoints', slug: 'docs/dmc/checkpoints' },
            { label: 'Recovery', slug: 'docs/dmc/recovery' },
          ],
        },
        {
          label: 'Haven — review cockpit',
          items: [
            { label: 'What is Haven?', slug: 'docs/haven' },
            { label: 'Pilot workflow', slug: 'docs/haven/pilot-workflow' },
          ],
        },
        {
          label: 'From the source repos',
          items: [
            {
              label: 'Haven integration contract',
              slug: 'docs/imported/haven-integration',
            },
            {
              label: 'Recovery preview details',
              slug: 'docs/imported/recovery-preview',
            },
            {
              label: 'Tester walkthrough',
              slug: 'docs/imported/tester-walkthrough',
            },
          ],
        },
      ],
    }),
  ],
});
