// Builds dist/reader.js (IIFE) and dist/reader.css (tokens bundled in).
// `node scripts/build.mjs --watch` rebuilds on change.
import * as esbuild from 'esbuild';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const watch = process.argv.includes('--watch');

// Android System WebView ships Chrome 58+ on the oldest devices we keep; Apple builds
// target iOS/macOS with Safari 18.
const target = ['es2017', 'chrome58', 'safari18'];

const common = {
  absWorkingDir: root,
  bundle: true,
  minify: false,
  target,
  logLevel: 'info',
  legalComments: 'none',
};

const configs = [
  {
    ...common,
    entryPoints: ['src/main.ts'],
    outfile: 'dist/reader.js',
    format: 'iife',
    sourcemap: false,
  },
  {
    ...common,
    entryPoints: ['src/reader.css'],
    outfile: 'dist/reader.css',
    loader: { '.css': 'css' },
  },
];

if (watch) {
  for (const c of configs) {
    const ctx = await esbuild.context(c);
    await ctx.watch();
  }
  console.log('watching src/ ...');
} else {
  await Promise.all(configs.map((c) => esbuild.build(c)));
}
