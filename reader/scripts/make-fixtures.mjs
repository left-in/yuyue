// Builds test/fixtures/ from a core export (`yuyue site <library> <out> --app reader/dist`):
// copies a handful of real section documents under short book ids, with the resources they
// reference, and adds one section with generated pictures (core's fixture books have no inline
// illustrations).
//
//   node scripts/make-fixtures.mjs [siteDir]      (default /tmp/yuyue-dev/site)
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.resolve(here, '../test/fixtures');
const SITE = path.resolve(process.argv[2] || '/tmp/yuyue-dev/site');

const read = (p) => fs.readFileSync(p, 'utf8');
const sectionsOf = (dir) =>
  fs.existsSync(path.join(dir, 's'))
    ? fs.readdirSync(path.join(dir, 's')).filter((f) => /^\d+\.html$/.test(f)).map((f) => parseInt(f, 10)).sort((a, b) => a - b)
    : [];

// Book ids in a core export are hashes; find the books by their content instead.
const books = fs.readdirSync(path.join(SITE, 'book')).sort().map((id) => path.join(SITE, 'book', id));
function find(test) {
  for (const dir of books) {
    for (const n of sectionsOf(dir)) {
      if (test(read(path.join(dir, 's', n + '.html')), n, dir)) return dir;
    }
  }
  throw new Error('fixture book not found in ' + SITE);
}

const pick = [
  { id: 'beiying', dir: find((h, n, d) => !fs.existsSync(path.join(d, 'r')) && h.includes('>背影</span></h2>')), sections: [0] },
  { id: 'edge', dir: find((h) => h.includes('标点和注音')), sections: [0, 1] },
  { id: 'pride', dir: find((h) => h.includes('id="Chapter_I"')), sections: [0, 1, 3, 4] },
  { id: 'gatsby', dir: find((h) => /lang="en"/.test(h) && h.includes('Gatsby')), sections: [2, 4] },
  { id: 'hlm', dir: find((h) => h.includes('甄士隱夢幻識通靈')), sections: [0, 2] },
];

fs.rmSync(OUT, { recursive: true, force: true });

function copy(src, dst) {
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
}

for (const b of pick) {
  const resources = new Set();
  for (const n of b.sections) {
    const file = path.join(b.dir, 's', n + '.html');
    if (!fs.existsSync(file)) continue;
    const html = read(file);
    copy(file, path.join(OUT, b.id, 's', n + '.html'));
    for (const m of html.matchAll(/(?:href|src)="\.\.\/(r\/[^"?#]+)/g)) resources.add(decodeURI(m[1]));
  }
  for (const r of resources) {
    const src = path.join(b.dir, r);
    if (fs.existsSync(src)) copy(src, path.join(OUT, b.id, r));
  }
  console.log(b.id.padEnd(8), path.basename(b.dir), 'sections', b.sections.join(','), 'resources', resources.size);
}

// ---------- the illustrated section ----------

const crcTable = new Int32Array(256).map((_, n) => {
  let c = n;
  for (let i = 0; i < 8; i++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c;
});
function crc32(buf) {
  let c = -1;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
/** RGB PNG; pixel(x, y) returns [r, g, b]. */
function png(w, h, pixel) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    const row = y * (w * 3 + 1);
    raw[row] = 0; // filter: none
    for (let x = 0; x < w; x++) {
      const [r, g, b] = pixel(x, y);
      raw[row + 1 + x * 3] = r;
      raw[row + 2 + x * 3] = g;
      raw[row + 3 + x * 3] = b;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type: RGB
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const mix = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));
const PAPER = [245, 244, 237];
const INK = [43, 76, 126];
// Ink-wash hills: layered ridges fading into the paper, and a low sun.
function hills(w, h, seed) {
  const ridge = (x, k) =>
    0.55 + 0.12 * k + 0.08 * Math.sin(x * (3 + k) + seed + k) + 0.04 * Math.sin(x * (11 + 2 * k) + seed * 2);
  return (x, y) => {
    const u = x / w;
    const v = y / h;
    let c = mix(PAPER, [228, 232, 236], v * 0.6);
    for (let k = 0; k < 3; k++) if (v > ridge(u * 6.283, k) - 0.18) c = mix(c, INK, 0.18 + 0.2 * k);
    const sun = Math.hypot((u - 0.72) * (w / h), v - 0.28) < 0.06;
    return sun ? mix(c, [214, 120, 98], 0.75) : c;
  };
}

const img = path.join(OUT, 'image', 'r', 'images');
fs.mkdirSync(img, { recursive: true });
fs.writeFileSync(path.join(img, 'wide.png'), png(1200, 700, hills(1200, 700, 1)));
fs.writeFileSync(path.join(img, 'tall.png'), png(500, 1400, hills(500, 1400, 2)));
fs.writeFileSync(path.join(img, 'late.png'), png(800, 600, hills(800, 600, 3)));

// The 背影 TXT section as core wrote it, with pictures after paragraphs 1, 3 and 5.
const base = read(path.join(OUT, 'beiying', 's', '0.html'));
const pics = {
  1: '<p class="pic"><img src="../r/images/wide.png" alt="山"></p>',
  3: '<figure><img src="../r/images/tall.png" alt="长卷"><figcaption>长卷：比一页还高的图，缩到一页之内</figcaption></figure>',
  // ?delay=: the dev server answers late, so the picture arrives after `ready` (relayout test).
  5: '<p class="pic"><img src="../r/images/late.png?delay=1500" alt="迟到的图"></p>',
};
let para = 0;
const doc = base
  .replace(/<\/p>/g, (m) => m + (pics[++para] || ''))
  .replace('<span class="s" data-s="0">背影</span>', '<span class="s" data-s="0">背影（插图）</span>');
fs.mkdirSync(path.join(OUT, 'image', 's'), { recursive: true });
fs.writeFileSync(path.join(OUT, 'image', 's', '0.html'), doc);
console.log('image    generated: wide.png, tall.png, late.png');

// ---------- a web font that arrives late ----------
// 背影 again, with a publisher stylesheet declaring a font whose file the dev server answers
// (with a 404) only after 900ms. Open it with ?font="YY Slow",serif: `ready` must wait for it.
fs.mkdirSync(path.join(OUT, 'font', 's'), { recursive: true });
fs.mkdirSync(path.join(OUT, 'font', 'r'), { recursive: true });
fs.writeFileSync(
  path.join(OUT, 'font', 'r', 'font.css'),
  '@font-face { font-family: "YY Slow"; src: url("missing.woff2?delay=900") format("woff2"); }\n',
);
fs.writeFileSync(
  path.join(OUT, 'font', 's', '0.html'),
  base.replace('<link rel="stylesheet" href="/app/reader.css">', '<link rel="stylesheet" href="../r/font.css">\n<link rel="stylesheet" href="/app/reader.css">'),
);
console.log('font     generated: font.css (late font)');
