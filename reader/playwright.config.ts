import { defineConfig } from '@playwright/test';

// Port of the test server (scripts/serve.mjs over test/fixtures); not the dev default 8787.
const PORT = 8796;

export default defineConfig({
  testDir: 'test',
  // test-results/screens/ (written by screens.spec.ts) lives next to, not inside, this
  // directory, which Playwright empties at the start of every run.
  outputDir: 'test-results/artifacts',
  timeout: 60_000,
  fullyParallel: true,
  reporter: [['list']],
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    viewport: { width: 393, height: 852 },
  },
  webServer: {
    command: `node scripts/serve.mjs --port ${PORT}`,
    url: `http://127.0.0.1:${PORT}/`,
    reuseExistingServer: false,
    stdout: 'ignore',
  },
  projects: [
    { name: 'webkit', use: { browserName: 'webkit' } },
    // YY_CHROME=1 uses the installed Google Chrome instead of Playwright's Chromium build.
    // channel 'chromium' runs the full Chromium build headless (the separate headless shell is not
    // installed).
    { name: 'chromium', use: { browserName: 'chromium', channel: process.env.YY_CHROME ? 'chrome' : 'chromium' } },
  ],
});
