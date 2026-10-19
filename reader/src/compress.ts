// 中文标点挤压 (contract §3). Core marks the full-width punctuation that gives up half its em box:
// .pz-r drops the right half (closing punctuation before more punctuation), .pz-l the left half.
// That assumes full-width glyphs in GB style, where 。，、！？ sit in the left half of the box and
// “ 「 （ in the right half. Not every font agrees: Songti SC centres ！, Traditional Chinese fonts
// centre 。，, and Apple's system fonts draw “ ” as narrow proportional glyphs with no blank half.
// Trimming then either makes neighbours collide (centred glyphs) or leaves too little room before
// a narrow opening quote. So each marked glyph, and an opening bracket after it, is measured in
// the font it is drawn with, and the mark is undone (.yy-pz-keep) where the font has no blank to
// give up.

interface Ink {
  w: number; // advance, em
  l: number; // ink start from the pen position, em
  r: number; // ink end, em
}

const OPENING = /[“‘「『（《〈【〔〖［｛]/;

// Glyphs are measured at 100px on a canvas of this size, the pen at (PEN, BASE): room for ink that
// reaches an em to the left of the pen, 2.2em to its right, 1.6em above the baseline and 0.8em below.
const CW = 320;
const CH = 240;
const PEN = 100;
const BASE = 160;

let ctx: CanvasRenderingContext2D | null | undefined;

function context(): CanvasRenderingContext2D | null {
  if (ctx === undefined) {
    const c = document.createElement('canvas');
    c.width = CW;
    c.height = CH;
    ctx = c.getContext ? (c.getContext('2d', { willReadFrequently: true }) as CanvasRenderingContext2D | null) : null;
  }
  return ctx;
}

function measure(font: string, ch: string): Ink | null {
  const c = context();
  if (!c) return null;
  c.font = font; // at 100px
  const m = c.measureText(ch);
  const w = m.width / 100;
  if (typeof m.actualBoundingBoxRight === 'number') {
    const l = -m.actualBoundingBoxLeft / 100;
    const r = m.actualBoundingBoxRight / 100;
    // Blink reports the ink. WebKit reports the advance box, grown by any ink that overflows it but
    // never shrunk to the ink (only its vertical bounds are real), so a box that covers the whole
    // advance says nothing: read the ink off the canvas instead.
    if (l > 0.005 || r < w - 0.005) return { w, l, r };
  }
  return raster(c, ch, w);
}

/** Ink bounds from the pixels: the first and last columns with any real coverage. */
function raster(c: CanvasRenderingContext2D, ch: string, w: number): Ink | null {
  c.clearRect(0, 0, CW, CH);
  c.fillStyle = '#000';
  c.textBaseline = 'alphabetic';
  c.fillText(ch, PEN, BASE);
  let d: Uint8ClampedArray;
  try {
    d = c.getImageData(0, 0, CW, CH).data;
  } catch (e) {
    return null;
  }
  let lo = CW;
  let hi = -1;
  for (let y = 0; y < CH; y++) {
    const row = y * CW * 4 + 3;
    for (let x = 0; x < lo; x++) {
      if (d[row + x * 4] > 24) {
        lo = x;
        break;
      }
    }
    for (let x = CW - 1; x > hi; x--) {
      if (d[row + x * 4] > 24) {
        hi = x;
        break;
      }
    }
  }
  // No ink: the font has no such glyph here; trust core's markup.
  if (hi < 0) return null;
  return { w, l: (lo - PEN) / 100, r: (hi + 1 - PEN) / 100 };
}

// Measurements per font and character, kept across passes and dropped whenever a web font finishes
// loading (the same font list can then draw differently). Not kept while fonts are loading.
type Memo = { [k: string]: Ink | null };
let cache: Memo = {};
const fonts = (document as unknown as { fonts?: EventTarget & { status?: string } }).fonts;
if (fonts && fonts.addEventListener) {
  fonts.addEventListener('loadingdone', () => {
    cache = {};
  });
}

/** First non-blank character after `el` in document order. */
function nextChar(el: Element, root: Element): string {
  const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  w.currentNode = el;
  for (let t = w.nextNode(); t; t = w.nextNode()) {
    if (el.contains(t)) continue;
    const m = /\S/.exec((t as Text).data);
    if (m) return m[0];
  }
  return '';
}

export function fitCompression(content: HTMLElement): void {
  if (document.documentElement.getAttribute('data-yy-compress') !== '1') return;
  const els = content.querySelectorAll('.pz-r, .pz-l');
  if (!els.length) return;
  const memo: Memo = fonts && fonts.status === 'loading' ? {} : cache;
  const inkOf = (font: string, ch: string): Ink | null => {
    const k = font + '|' + ch;
    return k in memo ? memo[k] : (memo[k] = measure(font, ch));
  };
  for (let i = 0; i < els.length; i++) {
    const el = els[i] as HTMLElement;
    const ch = (el.textContent || '').trim();
    if (!ch) continue;
    const cs = getComputedStyle(el);
    const font = cs.fontStyle + ' ' + cs.fontWeight + ' 100px ' + cs.fontFamily;
    const g = inkOf(font, ch);
    let keep = false;
    if (g) {
      // 0.02em tolerance for anti-aliasing and side bearings.
      if (el.classList.contains('pz-r')) {
        keep = g.w - g.r < 0.48;
        const next = keep ? '' : nextChar(el, content);
        if (next && OPENING.test(next)) {
          const n = inkOf(font, next);
          keep = !!n && n.l < 0.3;
        }
      } else {
        keep = g.l < 0.48;
      }
    }
    if (keep) el.classList.add('yy-pz-keep');
    else el.classList.remove('yy-pz-keep');
  }
}
