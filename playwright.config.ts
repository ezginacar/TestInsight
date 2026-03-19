import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 30_000,
  retries: 1,

  reporter: [
    // list reporter to show json output
    ['list'],
    ['html', { open: 'never' }],
    ['json', { outputFile: 'test-results/results.json' }]
  ],

  use: {
    trace: 'on-first-retry',
    browserName: 'chromium'
  }
});