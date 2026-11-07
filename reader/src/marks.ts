// Highlights (划线), search hits and the selection (contract §8).
//
// Places in the text are a sentence and a character offset into it: the UTF-16 length of the
// sentence's text nodes before the place, in document order across all its fragments (ruby
// readings and note markers left out). Lines under the text are drawn with the CSS Custom
// Highlight API, which paints over the text without touching the DOM, so the layout, the anchors
// and the ink line never see them; engines without it (old Android WebViews) simply show none.
// The three colours are boxes in a layer behind the text instead (placeFills): the Highlight API
// colours the whole line height in WebKit, and a highlight should only cover the letters.

import { post } from './bridge';
import { fragmentsOf, sentenceOf, state } from './layout';

export interface Point {
  s: number;
  o: number;
}

export type Style = 'yellow' | 'blue' | 'pink' | 'wave' | 'underline' | 'dotted';
export const STYLES: Style[] = ['yellow', 'blue', 'pink', 'wave', 'underline', 'dotted'];

export interface MarkSpec {
  id: string;
  start: Point;
  end: Point;
  style: Style;
  note?: boolean;
}

interface HighlightCtor {
  new (...ranges: Range[]): unknown;
}
interface HighlightRegistry {
  set(name: string, h: unknown): void;
  delete(name: string): void;
}

export const registry = (): HighlightRegistry | null => {
  const css = (window as unknown as { CSS?: { highlights?: HighlightRegistry } }).CSS;
  return css && css.highlights ? css.highlights : null;
};
export const Highlight = (window as unknown as { Highlight?: HighlightCtor }).Highlight;

function skipped(t: Node, frag: Element): boolean {
  for (let p = t.parentNode as Element | null; p && p !== frag; p = p.parentNode as Element | null) {
    if (p.nodeName === 'RT' || p.nodeName === 'RP' || (p.classList && p.classList.contains('yy-noteref'))) return true;
  }
  return false;
}

/** The sentence's text nodes in order. */
export function textNodes(s: number): Text[] {
  const out: Text[] = [];
  for (const f of fragmentsOf(s)) {
    const w = document.createTreeWalker(f, NodeFilter.SHOW_TEXT, null);
    for (let t = w.nextNode(); t; t = w.nextNode()) if (!skipped(t, f)) out.push(t as Text);
  }
  return out;
}

export function sentenceText(s: number): string {
  return textNodes(s)
    .map((t) => t.data)
    .join('');
}

/** The DOM place of a point, clamped to the sentence. */
function domPoint(p: Point): { node: Text; offset: number } | null {
  const nodes = textNodes(p.s);
  if (!nodes.length) return null;
  let left = Math.max(0, p.o);
  for (const t of nodes) {
    if (left <= t.data.length) return { node: t, offset: left };
    left -= t.data.length;
  }
  const last = nodes[nodes.length - 1];
  return { node: last, offset: last.data.length };
}

export function rangeOf(start: Point, end: Point): Range | null {
  const a = domPoint(start);
  const b = domPoint(end);
  if (!a || !b) return null;
  const r = document.createRange();
  try {
    r.setStart(a.node, a.offset);
    r.setEnd(b.node, b.offset);
  } catch (e) {
    return null;
  }
  return r.collapsed ? null : r;
}

/** The first text node at or after (forward) / before (backward) a DOM place, as a text place. */
function textAt(node: Node, offset: number, forward: boolean): { node: Text; offset: number } | null {
  if (node.nodeType === 3) return { node: node as Text, offset };
  const children = node.childNodes;
  let start: Node | null;
  if (forward) start = offset < children.length ? children[offset] : null;
  else start = offset > 0 ? children[offset - 1] : null;
  const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  if (start) {
    if (start.nodeType === 3) return { node: start as Text, offset: forward ? 0 : (start as Text).data.length };
    w.currentNode = start;
    if (forward) {
      const t = w.nextNode();
      return t ? { node: t as Text, offset: 0 } : null;
    }
    // The last text inside `start`, or the one before it.
    let last: Node | null = null;
    const inner = document.createTreeWalker(start, NodeFilter.SHOW_TEXT, null);
    for (let t = inner.nextNode(); t; t = inner.nextNode()) last = t;
    if (last) return { node: last as Text, offset: (last as Text).data.length };
    const t = w.previousNode();
    return t ? { node: t as Text, offset: (t as Text).data.length } : null;
  }
  w.currentNode = node;
  const t = forward ? w.nextNode() : w.previousNode();
  if (!t) return null;
  return { node: t as Text, offset: forward ? 0 : (t as Text).data.length };
}

/** A DOM place as a point: inside a sentence, or the nearest sentence edge in that direction. */
export function pointOf(node: Node, offset: number, forward: boolean): Point | null {
  let here = textAt(node, offset, forward);
  const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  while (here) {
    const s = sentenceOf(here.node.parentElement);
    if (s != null) {
      const nodes = textNodes(s);
      const i = nodes.indexOf(here.node);
      if (i >= 0) {
        let o = here.offset;
        for (let k = 0; k < i; k++) o += nodes[k].data.length;
        return { s, o };
      }
    }
    // Between sentences, or in a ruby reading: go on to the next text that counts.
    w.currentNode = here.node;
    const t = forward ? w.nextNode() : w.previousNode();
    here = t ? { node: t as Text, offset: forward ? 0 : (t as Text).data.length } : null;
  }
  return null;
}

const before = (a: Point, b: Point): boolean => a.s < b.s || (a.s === b.s && a.o < b.o);
const notAfter = (a: Point, b: Point): boolean => !before(b, a);

// ---------- marks ----------

let marks: MarkSpec[] = [];
const FILLS: Style[] = ['yellow', 'blue', 'pink'];

function draw(): void {
  placeFills();
  const reg = registry();
  if (!reg || !Highlight) return;
  const by: { [k: string]: Range[] } = {};
  for (const m of marks) {
    const r = rangeOf(m.start, m.end);
    if (!r) continue;
    if (FILLS.indexOf(m.style) < 0) (by[m.style] || (by[m.style] = [])).push(r);
    if (m.note) (by.note || (by.note = [])).push(r);
  }
  for (const k of STYLES.concat(['note' as Style])) {
    if (by[k]) reg.set('yy-' + k, new Highlight(...by[k]));
    else reg.delete('yy-' + k);
  }
  repaint();
}

let fillsEl: HTMLElement | null = null;

/** The colour marks as boxes behind the text, one per line, as tall as its letters. Called
 *  again after every relayout. */
export function placeFills(): void {
  const out = document.createDocumentFragment();
  const dx = window.pageXOffset;
  const dy = window.pageYOffset;
  for (const m of marks) {
    if (FILLS.indexOf(m.style) < 0) continue;
    const r = rangeOf(m.start, m.end);
    if (!r) continue;
    for (const b of lineBoxes(r)) {
      const i = document.createElement('i');
      i.className = 'yy-' + m.style;
      i.style.cssText = `left:${b.left + dx}px;top:${b.top + dy}px;width:${b.right - b.left}px;height:${b.bottom - b.top}px`;
      out.appendChild(i);
    }
  }
  if (!fillsEl) {
    if (!out.childNodes.length) return;
    fillsEl = document.createElement('yy-fills');
    fillsEl.setAttribute('aria-hidden', 'true');
    document.documentElement.appendChild(fillsEl);
  }
  while (fillsEl.firstChild) fillsEl.removeChild(fillsEl.firstChild);
  fillsEl.appendChild(out);
}

interface Box {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/** The letters a range covers, one box per line: each text node's own boxes (not the elements
 *  around them, nor ruby readings), joined where they sit side by side on the same line. */
function lineBoxes(r: Range): Box[] {
  const rects: Box[] = [];
  const root = r.commonAncestorContainer;
  const w = document.createTreeWalker(root.nodeType === 3 ? (root.parentNode as Node) : root, NodeFilter.SHOW_TEXT, null);
  const part = document.createRange();
  for (let t = w.nextNode() as Text | null; t; t = w.nextNode() as Text | null) {
    if (!r.intersectsNode(t)) continue;
    const p = t.parentNode as Element | null;
    if (p && (p.nodeName === 'RT' || p.nodeName === 'RP')) continue;
    part.setStart(t, t === r.startContainer ? r.startOffset : 0);
    part.setEnd(t, t === r.endContainer ? r.endOffset : t.data.length);
    if (part.collapsed) continue;
    const rs = part.getClientRects();
    for (let k = 0; k < rs.length; k++) {
      const b = rs[k];
      if (b.width > 0 && b.height > 0) rects.push({ left: b.left, top: b.top, right: b.right, bottom: b.bottom });
    }
  }
  const lines: Box[] = [];
  for (const b of rects) {
    const mid = (b.top + b.bottom) / 2;
    const same = lines.filter((l) => mid > l.top && mid < l.bottom && b.left <= l.right + 2 && b.right >= l.left - 2)[0];
    if (same) {
      same.left = Math.min(same.left, b.left);
      same.right = Math.max(same.right, b.right);
      same.top = Math.min(same.top, b.top);
      same.bottom = Math.max(same.bottom, b.bottom);
    } else lines.push({ left: b.left, top: b.top, right: b.right, bottom: b.bottom });
  }
  return lines;
}

/** Draws the marks again from their places, after the content was rebuilt (气泡). */
export function redraw(): void {
  draw();
  if (source != null) setSource(source);
}

export function setMarks(list: MarkSpec[] | null): void {
  marks = (list || []).filter((m) => m && m.start && m.end && STYLES.indexOf(m.style) >= 0);
  draw();
}

/** The mark at a point of the viewport, the newest when several overlap. */
export function markAt(x: number, y: number): string | null {
  if (!marks.length) return null;
  const d = document as unknown as { caretRangeFromPoint?(x: number, y: number): Range | null };
  const r = d.caretRangeFromPoint ? d.caretRangeFromPoint(x, y) : null;
  if (!r) return null;
  const p = pointOf(r.startContainer, r.startOffset, true);
  if (!p) return null;
  for (let i = marks.length - 1; i >= 0; i--) {
    const m = marks[i];
    if (notAfter(m.start, p) && before(p, m.end)) {
      // The caret lands between characters: make sure the point is really over the mark's text.
      const range = rangeOf(m.start, m.end);
      if (range && Array.prototype.some.call(range.getClientRects(), (b: DOMRect) => x >= b.left - 1 && x <= b.right + 1 && y >= b.top - 2 && y <= b.bottom + 2))
        return m.id;
    }
  }
  return null;
}

// ---------- search hits ----------

/** Marks every place `query` turns up in this section; `current` ({s, nth}) gets the solid
 *  colour. Returns the number of hits. */
export function setHits(query: string | null, current?: { s: number; nth: number } | null): number {
  const reg = registry();
  const q = (query || '').toLowerCase();
  if (!q) {
    if (reg) {
      reg.delete('yy-hit');
      reg.delete('yy-hit-now');
    }
    return 0;
  }
  const all: Range[] = [];
  const now: Range[] = [];
  for (let s = 0; s < state.sentenceCount; s++) {
    const text = sentenceText(s).toLowerCase();
    let nth = 0;
    for (let k = text.indexOf(q); k >= 0; k = text.indexOf(q, k + q.length)) {
      const r = rangeOf({ s, o: k }, { s, o: k + q.length });
      if (r) (current && current.s === s && current.nth === nth ? now : all).push(r);
      nth++;
    }
  }
  if (reg && Highlight) {
    reg.set('yy-hit', new Highlight(...all));
    reg.set('yy-hit-now', new Highlight(...now));
    repaint();
  }
  return all.length + now.length;
}

/** WebKit on the Mac doesn't paint a changed highlight while the keyboard is in a native field
 *  (⌘G from the search box left the old hit solid, though the new one was set): give the text a
 *  layer of its own, or take it away, so it is painted again. */
let flip = false;
export function repaint(): void {
  // On <body>, which holds the columns: inside it, a layer of its own would split the text
  // across columns differently, and the absolutely placed pieces are placed from <html>.
  flip = !flip;
  document.body.style.setProperty('will-change', flip ? 'transform' : '');
}

/** 书伴's 出处: the whole sentence `s` washed in the accent and "出处" in the margin beside its
 *  first line, or nothing. */
let source: number | null = null;
let fromEl: HTMLElement | null = null;

export function setSource(s: number | null): void {
  source = s == null || s < 0 || s >= state.sentenceCount ? null : s;
  const reg = registry();
  if (reg && Highlight) {
    const r = source == null ? null : rangeOf({ s: source, o: 0 }, { s: source, o: sentenceText(source).length });
    if (r) reg.set('yy-source', new Highlight(r));
    else reg.delete('yy-source');
    repaint();
  }
  placeSource();
}

/** Puts the margin label back beside the sentence; called again after every relayout. */
export function placeSource(): void {
  const box = source == null ? null : firstBox(source);
  if (!box) {
    if (fromEl) fromEl.style.display = 'none';
    return;
  }
  if (!fromEl) {
    fromEl = document.createElement('yy-from');
    fromEl.setAttribute('aria-hidden', 'true');
    fromEl.textContent = '出处';
    document.documentElement.appendChild(fromEl);
  }
  const root = getComputedStyle(document.documentElement);
  const m = parseFloat(root.getPropertyValue('--yy-margin')) || 24;
  const x = box.left + window.pageXOffset;
  let left = m;
  if (document.documentElement.getAttribute('data-yy-mode') !== 'scrolled' && state.W > 0) {
    const cols = Math.max(1, parseInt(root.getPropertyValue('--yy-cols'), 10) || 1);
    const pitch = state.W / cols;
    left = Math.floor(x / pitch) * pitch + m;
  }
  fromEl.style.display = '';
  // Only where the margin has room for it.
  if (m < 36) {
    fromEl.style.display = 'none';
    return;
  }
  fromEl.style.left = left - 5 + 'px';
  fromEl.style.top = box.top + window.pageYOffset + box.height / 2 + 'px';
}

function firstBox(s: number): DOMRect | null {
  for (const f of fragmentsOf(s)) {
    const rs = f.getClientRects();
    for (let k = 0; k < rs.length; k++) if (rs[k].width > 0) return rs[k];
  }
  return null;
}

// ---------- selection ----------

let posted = false;
let timer = 0;

function postSelection(): void {
  timer = 0;
  const sel = window.getSelection ? window.getSelection() : null;
  const text = sel ? sel.toString() : '';
  if (!sel || sel.isCollapsed || !sel.rangeCount || !text.trim()) {
    if (posted) post({ type: 'selection', start: null, end: null, text: null, rect: null });
    posted = false;
    return;
  }
  const r = sel.getRangeAt(0);
  const start = pointOf(r.startContainer, r.startOffset, true);
  const end = pointOf(r.endContainer, r.endOffset, false);
  if (!start || !end || !before(start, end)) return;
  // The selection's lines on this page; the card goes above the first of them.
  const boxes = Array.prototype.filter.call(
    r.getClientRects(),
    (b: DOMRect) => b.width > 0 && b.right > 0 && b.left < window.innerWidth,
  ) as DOMRect[];
  if (!boxes.length) return;
  let left = Infinity;
  let right = -Infinity;
  let top = Infinity;
  let bottom = -Infinity;
  for (const b of boxes) {
    left = Math.min(left, b.left);
    right = Math.max(right, b.right);
    top = Math.min(top, b.top);
    bottom = Math.max(bottom, b.bottom);
  }
  posted = true;
  post({
    type: 'selection',
    start,
    end,
    text,
    rect: { x: Math.round(left), y: Math.round(top), width: Math.round(right - left), height: Math.round(bottom - top) },
  });
}

function schedule(delay: number): void {
  if (timer) clearTimeout(timer);
  timer = window.setTimeout(postSelection, delay);
}

let pressing = false;

export function initSelection(): void {
  // While the mouse is down the selection is still being dragged out: report it once released.
  document.addEventListener('pointerdown', () => (pressing = true), true);
  const released = (): void => {
    pressing = false;
    schedule(30);
  };
  document.addEventListener('pointerup', released, true);
  // Android ends a long press that starts a selection with pointercancel, not pointerup.
  document.addEventListener('pointercancel', released, true);
  document.addEventListener('selectionchange', () => {
    if (!pressing) schedule(250);
  });
}

export function clearSelection(): void {
  const sel = window.getSelection ? window.getSelection() : null;
  if (sel) sel.removeAllRanges();
  posted = false;
}

/** Selects from `start` to `end` (a mark tapped, to show what the card is about). */
export function select(start: Point, end: Point): void {
  const r = rangeOf(start, end);
  const sel = window.getSelection ? window.getSelection() : null;
  if (!r || !sel) return;
  sel.removeAllRanges();
  sel.addRange(r);
}

/** Where a mark is drawn on this page, for placing a card by it. */
export function markRect(id: string): { x: number; y: number; width: number; height: number } | null {
  const m = marks.filter((x) => x.id === id)[0];
  const r = m ? rangeOf(m.start, m.end) : null;
  if (!r) return null;
  const boxes = Array.prototype.filter.call(r.getClientRects(), (b: DOMRect) => b.width > 0 && b.right > 0 && b.left < window.innerWidth) as DOMRect[];
  if (!boxes.length) return null;
  const b = boxes[0];
  return { x: Math.round(b.left), y: Math.round(b.top), width: Math.round(b.width), height: Math.round(b.height) };
}
