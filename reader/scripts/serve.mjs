// Dev server with the URL layout of contract §1.
//   /app/*          reader/dist/*
//   /book/<id>/*    reader/test/fixtures/<id>/*   (or <site>/book/<id>/* with --site <dir>)
//   /demo/*         reader/demo/*
// Section documents accept the settings core bakes into <html> as query parameters, e.g.
//   /book/beiying/s/0.html?paper=kami&fs=20&cols=2&paging=snap
// and any request accepts ?delay=<ms> to answer late (late image loads).
//
//   node scripts/serve.mjs [--port 8787] [--site /tmp/yuyue-dev/site]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, '..');

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.xhtml': 'application/xhtml+xml; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
};

const ATTRS = ['paper', 'mode', 'paging', 'justify', 'indent', 'compress', 'motion', 'tint'];
const VARS = { fs: ['--yy-fs', 'px'], lh: ['--yy-lh', ''], ps: ['--yy-ps', 'em'], margin: ['--yy-margin', 'px'], top: ['--yy-top', 'px'], bottom: ['--yy-bottom', 'px'], cols: ['--yy-cols', ''] };
const FONTS = { sans: 'var(--yy-sans)', serif: 'var(--yy-serif)', kai: 'var(--yy-kai)', mono: 'var(--yy-mono)' };

/** Rewrites the <html> start tag the way core assembles a document for the current settings. */
export function withSettings(html, q) {
  return html.replace(/<html\b([^>]*)>/i, (_, attrs) => {
    const list = [];
    attrs.replace(/([^\s=]+)(?:="([^"]*)")?/g, (m, k, v) => list.push([k, v == null ? '' : v]));
    const get = (k) => list.find((a) => a[0] === k);
    const set = (k, v) => {
      const a = get(k);
      if (a) a[1] = v;
      else list.push([k, v]);
    };
    const style = new Map();
    (get('style') ? get('style')[1] : '').split(';').forEach((d) => {
      const i = d.indexOf(':');
      if (i > 0) style.set(d.slice(0, i).trim(), d.slice(i + 1).trim());
    });
    for (const a of ATTRS) if (q.has(a)) set('data-yy-' + a, q.get(a));
    if (q.has('lang')) set('lang', q.get('lang'));
    for (const [k, [name, unit]] of Object.entries(VARS)) if (q.has(k)) style.set(name, q.get(k) + unit);
    if (q.has('font')) style.set('--yy-font', FONTS[q.get('font')] || q.get('font'));
    set('style', [...style].map(([k, v]) => k + ':' + v).join(';'));
    return '<html ' + list.map(([k, v]) => k + '="' + v.replace(/"/g, '&quot;') + '"').join(' ') + '>';
  });
}

function resolve(urlPath, site) {
  const p = decodeURIComponent(urlPath);
  if (p.startsWith('/app/')) return path.join(ROOT, 'dist', p.slice(5));
  if (p.startsWith('/demo/')) return path.join(ROOT, 'demo', p.slice(6));
  if (p === '/demo') return path.join(ROOT, 'demo', 'index.html');
  const m = /^\/book\/([^/]+)\/(.+)$/.exec(p);
  if (m) return site ? path.join(site, 'book', m[1], m[2]) : path.join(ROOT, 'test', 'fixtures', m[1], m[2]);
  return null;
}

/** First heading of a section document, as plain text. */
function headingOf(html) {
  const m = /<h[1-4]\b[^>]*>([\s\S]*?)<\/h[1-4]>/i.exec(html);
  if (!m) return '';
  return m[1].replace(/<br\b[^>]*>/gi, ' ').replace(/<[^>]+>/g, '').replace(/&[a-z#0-9]+;/gi, ' ').replace(/\s+/g, ' ').trim().slice(0, 40);
}

/** [{book, sections: [{n, title}]}] for the index page and the demo's picker. */
function sections(site) {
  const base = site ? path.join(site, 'book') : path.join(ROOT, 'test', 'fixtures');
  if (!fs.existsSync(base)) return [];
  return fs
    .readdirSync(base)
    .sort()
    .flatMap((id) => {
      const dir = path.join(base, id, 's');
      if (!fs.existsSync(dir)) return [];
      const list = fs
        .readdirSync(dir)
        .filter((f) => /^\d+\.html$/.test(f))
        .map((f) => parseInt(f, 10))
        .sort((a, b) => a - b)
        .map((n) => ({ n, title: headingOf(fs.readFileSync(path.join(dir, n + '.html'), 'utf8')) }));
      return list.length ? [{ book: id, sections: list }] : [];
    });
}

function index(site) {
  const items = sections(site).flatMap((b) =>
    b.sections.map((s) => `<li><a href="/book/${b.book}/s/${s.n}.html">${b.book} / ${s.n}</a> ${s.title}</li>`),
  );
  return `<!doctype html><meta charset="utf-8"><title>yuyue reader dev</title>
<body style="font:14px -apple-system,sans-serif;margin:24px"><p><a href="/demo/">demo</a></p><ul>${items.join('')}</ul>`;
}

export function createServer({ site } = {}) {
  return http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    const delay = Math.min(30000, parseInt(url.searchParams.get('delay') || '0', 10) || 0);
    const send = (status, type, body) => {
      setTimeout(() => {
        res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' });
        res.end(body);
      }, delay);
    };
    if (url.pathname === '/' || url.pathname === '/index.html') return send(200, TYPES['.html'], index(site));
    if (url.pathname === '/api/sections') return send(200, TYPES['.json'], JSON.stringify(sections(site)));
    const file = resolve(url.pathname, site);
    if (!file || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      if (file && fs.existsSync(path.join(file, 'index.html'))) {
        return send(200, TYPES['.html'], fs.readFileSync(path.join(file, 'index.html')));
      }
      return send(404, 'text/plain', 'not found: ' + url.pathname);
    }
    const ext = path.extname(file).toLowerCase();
    let body = fs.readFileSync(file);
    if (ext === '.html' && /^\/book\/[^/]+\/s\//.test(url.pathname)) body = withSettings(body.toString('utf8'), url.searchParams);
    send(200, TYPES[ext] || 'application/octet-stream', body);
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const arg = (name, def) => {
    const i = process.argv.indexOf(name);
    return i > 0 ? process.argv[i + 1] : def;
  };
  const port = parseInt(arg('--port', process.env.PORT || '8787'), 10);
  const site = arg('--site', null);
  createServer({ site: site && path.resolve(site) }).listen(port, '127.0.0.1', () => {
    console.log(`reader dev server: http://127.0.0.1:${port}/  (demo: /demo/, books: ${site || 'test/fixtures'})`);
  });
}
