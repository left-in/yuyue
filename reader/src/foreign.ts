// 外文原著: the word under a click (点词), the words kept in the 生词本 marked
// with a dotted line wherever they turn up, and translations under paragraphs (译).
//
// Words are runs of Latin, Greek or Cyrillic letters; an apostrophe or hyphen between letters
// stays inside. CJK text never makes a word, so a click on Chinese stays a plain tap.

import { fragmentsOf, sentenceOf, state } from './layout';
import { Highlight, Point, pointOf, rangeOf, registry, repaint, textNodes } from './marks';

const LETTER = 'A-Za-z\\u00C0-\\u024F\\u1E00-\\u1EFF\\u0370-\\u03FF\\u0400-\\u04FF';
const WORDS = new RegExp('[' + LETTER + "](?:[" + LETTER + "]|['\\u2019\\-](?=[" + LETTER + ']))*', 'g');
const IS_LETTER = new RegExp('[' + LETTER + ']');

let lookupOn = false;

export interface WordHit {
  text: string;
  start: Point;
  end: Point;
  sentence: string;
  rect: { x: number; y: number; width: number; height: number };
}

export function setLookup(on: boolean): void {
  lookupOn = !!on;
}

// A double click translates the sentence there, so it must not also select a word.
document.addEventListener(
  'mousedown',
  (e) => {
    if (lookupOn && e.detail >= 2) e.preventDefault();
  },
  true,
);

interface CaretDoc {
  caretRangeFromPoint?(x: number, y: number): Range | null;
  caretPositionFromPoint?(x: number, y: number): { offsetNode: Node; offset: number } | null;
}

function caretAt(x: number, y: number): { node: Node; offset: number } | null {
  const d = document as unknown as CaretDoc;
  if (d.caretRangeFromPoint) {
    const r = d.caretRangeFromPoint(x, y);
    return r ? { node: r.startContainer, offset: r.startOffset } : null;
  }
  if (d.caretPositionFromPoint) {
    const p = d.caretPositionFromPoint(x, y);
    return p ? { node: p.offsetNode, offset: p.offset } : null;
  }
  return null;
}

/** The word under a click in a book being read in another language, or null. */
export function wordAt(x: number, y: number): WordHit | null {
  if (!lookupOn) return null;
  const c = caretAt(x, y);
  if (!c || c.node.nodeType !== 3) return null;
  const t = c.node as Text;
  if (sentenceOf(t.parentElement) == null) return null;
  const data = t.data;
  WORDS.lastIndex = 0;
  for (let m = WORDS.exec(data); m; m = WORDS.exec(data)) {
    const from = m.index;
    const to = from + m[0].length;
    if (c.offset < from || c.offset > to) continue;
    const r = document.createRange();
    r.setStart(t, from);
    r.setEnd(t, to);
    // The caret snaps to the nearest letter; only a click on the word itself counts.
    const boxes = Array.prototype.slice.call(r.getClientRects()) as DOMRect[];
    const box = boxes.find((b) => x >= b.left - 2 && x <= b.right + 2 && y >= b.top - 3 && y <= b.bottom + 3);
    if (!box) return null;
    const start = pointOf(t, from, true);
    const end = pointOf(t, to, false);
    if (!start || !end) return null;
    return {
      text: m[0].replace(/’/g, "'"),
      start,
      end,
      sentence: textNodes(start.s)
        .map((n) => n.data)
        .join('')
        .trim(),
      rect: { x: box.left, y: box.top, width: box.width, height: box.height },
    };
  }
  return null;
}

/** The word being looked up, washed in the accent; null clears it. */
export function setLooking(start: Point | null, end: Point | null): void {
  const reg = registry();
  if (!reg || !Highlight) return;
  const r = start && end ? rangeOf(start, end) : null;
  if (r) reg.set('yy-look', new Highlight(r));
  else reg.delete('yy-look');
  repaint();
}

/** Forms of an English word that count as the same word: fix → fixes, fixed, fixing. Keep in
 *  step with the core's `words::forms`. */
function forms(word: string): string[] {
  const w = word.trim().toLowerCase();
  const out = [w];
  if (w.length < 3 || !/^[a-z]+$/.test(w)) return out;
  const add = (s: string): void => {
    if (out.indexOf(s) < 0) out.push(s);
  };
  add(w + 's');
  add(w + 'es');
  add(w + 'ed');
  add(w + 'ing');
  add(w + "'s");
  if (w.endsWith('e')) {
    add(w + 'd');
    add(w.slice(0, -1) + 'ing');
  }
  if (w.endsWith('y')) {
    add(w.slice(0, -1) + 'ies');
    add(w.slice(0, -1) + 'ied');
  }
  return out;
}

let vocab: Record<string, true> = {};

/** 生词: the words kept to learn, dotted wherever they appear in this section. */
export function setVocab(words: string[] | null): void {
  vocab = {};
  for (const w of words || []) for (const f of forms(w)) vocab[f] = true;
  drawVocab();
}

export function drawVocab(): void {
  const reg = registry();
  if (!reg || !Highlight) return;
  const ranges: Range[] = [];
  if (Object.keys(vocab).length) {
    for (let s = 0; s < state.sentenceCount; s++) {
      for (const t of textNodes(s)) {
        if (!IS_LETTER.test(t.data)) continue;
        WORDS.lastIndex = 0;
        for (let m = WORDS.exec(t.data); m; m = WORDS.exec(t.data)) {
          if (!vocab[m[0].toLowerCase().replace(/’/g, "'")]) continue;
          const r = document.createRange();
          r.setStart(t, m.index);
          r.setEnd(t, m.index + m[0].length);
          ranges.push(r);
        }
      }
    }
  }
  if (ranges.length) reg.set('yy-vocab', new Highlight(...ranges));
  else reg.delete('yy-vocab');
  repaint();
}

// ---------- 难词注释 ----------

let glosses: Record<string, string> = {};
let glossLayer: HTMLElement | null = null;

/** 难词注释: a short meaning above each harder word, keyed by its spelling in lower case. */
export function setGlosses(list: { form: string; gloss: string }[] | null): void {
  glosses = {};
  for (const g of list || []) glosses[g.form] = g.gloss;
  drawGlosses();
}

/** Writes the meanings above the words, in the leading between lines; called again after
 *  every relayout. Where two would run into each other on a line, the second is left out. */
export function drawGlosses(): void {
  if (glossLayer) glossLayer.textContent = '';
  if (!Object.keys(glosses).length) return;
  if (!glossLayer) {
    glossLayer = document.createElement('yy-glosses');
    glossLayer.setAttribute('aria-hidden', 'true');
    document.documentElement.appendChild(glossLayer);
  }
  const probe = document.createElement('yy-gl');
  probe.textContent = '注';
  glossLayer.appendChild(probe);
  const size = probe.getBoundingClientRect().height || 9;
  glossLayer.removeChild(probe);
  const sx = window.pageXOffset;
  const sy = window.pageYOffset;
  const out = document.createDocumentFragment();
  let lineTop = NaN;
  let lineRight = -Infinity;
  for (let s = 0; s < state.sentenceCount; s++) {
    for (const t of textNodes(s)) {
      if (!IS_LETTER.test(t.data)) continue;
      WORDS.lastIndex = 0;
      for (let m = WORDS.exec(t.data); m; m = WORDS.exec(t.data)) {
        const gloss = glosses[m[0].toLowerCase().replace(/’/g, "'")];
        if (!gloss) continue;
        const r = document.createRange();
        r.setStart(t, m.index);
        r.setEnd(t, m.index + m[0].length);
        const b = r.getClientRects()[0];
        if (!b || !b.width) continue;
        const width = gloss.length * size;
        const mid = b.left + b.width / 2;
        if (!(Math.abs(b.top - lineTop) <= 2)) {
          lineTop = b.top;
          lineRight = -Infinity;
        }
        if (mid - width / 2 < lineRight + size / 2) continue;
        lineRight = mid + width / 2;
        const el = document.createElement('yy-gl');
        el.textContent = gloss;
        el.style.left = mid + sx + 'px';
        el.style.top = b.top + sy - size * 1.05 + 'px';
        out.appendChild(el);
      }
    }
  }
  glossLayer.appendChild(out);
}

// ---------- 译 ----------

/** The block a sentence's first fragment sits in: a paragraph, a heading, a list item. */
export function blockOf(s: number): Element | null {
  const f = fragmentsOf(s)[0];
  if (!f) return null;
  let el: Element | null = f.parentElement;
  while (el && el !== document.body) {
    const d = getComputedStyle(el).display;
    if (d === 'block' || d === 'list-item' || d === 'table-cell') return el;
    el = el.parentElement;
  }
  return null;
}

export interface Paragraph {
  /** First and last sentence in it. */
  first: number;
  last: number;
  text: string;
}

/** The section's paragraphs that have words in another language, for translating. */
export function paragraphs(): Paragraph[] {
  const out: Paragraph[] = [];
  let block: Element | null = null;
  for (let s = 0; s < state.sentenceCount; s++) {
    const b = blockOf(s);
    const text = textNodes(s)
      .map((n) => n.data)
      .join('');
    if (b && b === block && out.length) {
      const p = out[out.length - 1];
      p.last = s;
      p.text += text;
    } else {
      out.push({ first: s, last: s, text });
      block = b;
    }
  }
  return out
    .map((p) => ({ first: p.first, last: p.last, text: p.text.replace(/\s+/g, ' ').trim() }))
    .filter((p) => IS_LETTER.test(p.text));
}

/** Puts each translation under its paragraph (keyed by the paragraph's last sentence); null
 *  takes them all away. The caller relays out afterwards. */
export function setTranslations(list: { last: number; text: string }[] | null): void {
  const old = document.querySelectorAll('yy-tr');
  for (let i = 0; i < old.length; i++) old[i].parentNode && old[i].parentNode!.removeChild(old[i]);
  for (const item of list || []) {
    const b = blockOf(item.last);
    if (!b || !b.parentNode) continue;
    const el = document.createElement('yy-tr');
    el.setAttribute('lang', 'zh-Hans');
    el.textContent = item.text;
    b.parentNode.insertBefore(el, b.nextSibling);
  }
}
