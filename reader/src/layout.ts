// Pagination, page/sentence geometry and reading-position anchors (contract §5, §6).
//
// Paginated mode: <body> is a multi-column box exactly one page (W x H) in size; its overflow
// columns continue to the right with a pitch of W/cols, so page p starts at scrollX = p*W.
// <html> (position: relative, one page wide) holds <yy-pages>, one absolutely placed marker
// per page. The markers make the document's scroll width exactly pageCount*W whatever the
// engine does with the trailing column padding, and they are the scroll-snap targets.

import { log } from './bridge';

export type Mode = 'paginated' | 'scrolled';

export const state = {
  W: 0,
  H: 0,
  pageCount: 1,
  sentenceCount: 0,
  sentencePages: [] as number[],
  pageFirstSentence: [] as number[],
};

let root: HTMLElement;
let content: HTMLElement;
let pagesEl: HTMLElement;
let frags: HTMLElement[] = [];
let fragS: number[] = [];
let bySentence: HTMLElement[][] = [];

export function initLayout(c: HTMLElement): void {
  root = document.documentElement;
  content = c;
  reindex();
  pagesEl = document.createElement('yy-pages');
  pagesEl.setAttribute('aria-hidden', 'true');
  root.appendChild(pagesEl);
}

/** Finds the sentences' fragments again, after the content was rebuilt (气泡). */
export function reindex(): void {
  const c = content;
  frags = Array.prototype.slice.call(c.querySelectorAll('.s'));
  fragS = frags.map((f) => parseInt(f.getAttribute('data-s') || '', 10));
  let max = -1;
  for (const s of fragS) if (s > max) max = s;
  state.sentenceCount = max + 1;
  bySentence = [];
  for (let i = 0; i <= max; i++) bySentence.push([]);
  frags.forEach((f, i) => {
    const s = fragS[i];
    if (s >= 0) bySentence[s].push(f);
  });
}

export function mode(): Mode {
  return root.getAttribute('data-yy-mode') === 'scrolled' ? 'scrolled' : 'paginated';
}

export function paging(): 'native' | 'snap' {
  return root.getAttribute('data-yy-paging') === 'snap' ? 'snap' : 'native';
}

export function fragmentsOf(s: number): HTMLElement[] {
  return bySentence[s] || [];
}

export function sentenceOf(el: Element | null): number | null {
  const f = el && el.closest ? el.closest('.s') : null;
  if (!f || !content.contains(f)) return null;
  const s = parseInt(f.getAttribute('data-s') || '', 10);
  return s >= 0 ? s : null;
}

function cssPx(name: string, fallback: number): number {
  const v = parseFloat(getComputedStyle(root).getPropertyValue(name));
  return isFinite(v) ? v : fallback;
}

export function margin(): number {
  return cssPx('--yy-margin', 24);
}

export function topInset(): number {
  return cssPx('--yy-top', 56);
}

const scroller = (): Element => document.scrollingElement || document.documentElement;

function setVar(name: string, value: string): void {
  if (root.style.getPropertyValue(name) !== value) root.style.setProperty(name, value);
}

function setMarkers(n: number, W: number): void {
  while (pagesEl.childNodes.length > n) pagesEl.removeChild(pagesEl.lastChild as Node);
  while (pagesEl.childNodes.length < n) pagesEl.appendChild(document.createElement('yy-page'));
  for (let p = 0; p < n; p++) {
    const left = p * W + 'px';
    const el = pagesEl.childNodes[p] as HTMLElement;
    if (el.style.left !== left) el.style.left = left;
  }
}

/** Picture-only sections (core: data-kind="image") must stay on one page. reader.css centres the
 *  picture and limits it to the column height; when a caption or a second picture pushes the
 *  section past that, shrink the pictures by the excess. */
function fitPictures(): void {
  if (content.getAttribute('data-kind') !== 'image') return;
  root.style.removeProperty('--yy-imgh');
  const colh = parseFloat(getComputedStyle(content).minHeight);
  const over = content.offsetHeight - colh;
  if (!(colh > 0) || over <= 0.5) return;
  let tallest = 0;
  let sum = 0;
  const pics = content.querySelectorAll('img, svg, video');
  for (let i = 0; i < pics.length; i++) {
    const h = pics[i].getBoundingClientRect().height;
    tallest = Math.max(tallest, h);
    sum += h;
  }
  if (!sum) return;
  const scale = Math.max(0.3, (sum - over) / sum);
  root.style.setProperty('--yy-imgh', Math.floor(tallest * scale) + 'px');
}

/** Measures the page box, counts pages, places the markers and computes the geometry. */
export function measure(): void {
  forgetSteps();
  // Whole CSS pixels (contract §6). Using px rather than 100vw keeps the pitch an integer
  // on Android devices whose CSS viewport is fractional.
  const W = Math.max(1, Math.floor(window.innerWidth));
  const H = Math.max(1, Math.floor(window.innerHeight));
  state.W = W;
  state.H = H;
  setVar('--yy-pw', W + 'px');
  setVar('--yy-ph', H + 'px');

  if (mode() === 'paginated') {
    fitPictures();
    pagesEl.style.setProperty('display', 'none', 'important');
    const raw = scroller().scrollWidth; // forces layout
    const m = margin();
    // The last column ends at c*W/cols - m (WebKit and Blink both leave out the trailing
    // padding here); round that up to whole pages.
    let n = Math.max(1, Math.ceil((raw - m - 1) / W));
    pagesEl.style.removeProperty('display');
    setMarkers(n, W);
    const sw = scroller().scrollWidth;
    if (sw > n * W + 1) {
      // Something overflows past the last column (an unbreakable wide element). Give it its
      // own page rather than let native paging stop on a half page.
      const n2 = Math.ceil((sw - 1) / W);
      log('warn', 'content overflows the last column by ' + (sw - n * W) + 'px; pageCount ' + n + ' -> ' + n2);
      n = n2;
      setMarkers(n, W);
    }
    state.pageCount = n;
  } else {
    setMarkers(0, W);
    const sh = scroller().scrollHeight;
    state.pageCount = Math.max(1, Math.ceil((sh - 1) / H));
  }
  computeGeometry();
}

/** Page index of a client rect (viewport coordinates). */
export function pageOfRect(r: { left: number; top: number; width: number; height: number }): number {
  const p =
    mode() === 'paginated'
      ? Math.floor((r.left + window.pageXOffset + r.width / 2) / state.W)
      : Math.floor((r.top + window.pageYOffset + r.height / 2) / state.H);
  return p < 0 ? 0 : p >= state.pageCount ? state.pageCount - 1 : p;
}

function visibleRects(el: Element): ClientRect[] {
  const out: ClientRect[] = [];
  const rs = el.getClientRects();
  for (let k = 0; k < rs.length; k++) if (rs[k].width > 0 || rs[k].height > 0) out.push(rs[k]);
  return out;
}

/** One pass over all sentence fragments' line boxes. */
export function computeGeometry(): void {
  const n = state.pageCount;
  const sp: number[] = [];
  const pf: number[] = [];
  for (let s = 0; s < state.sentenceCount; s++) sp.push(-1);
  for (let p = 0; p < n; p++) pf.push(-1);
  for (let i = 0; i < frags.length; i++) {
    const s = fragS[i];
    if (!(s >= 0)) continue;
    const rs = frags[i].getClientRects();
    for (let k = 0; k < rs.length; k++) {
      const r = rs[k];
      if (r.width === 0 && r.height === 0) continue;
      const p = pageOfRect(r);
      if (sp[s] < 0) sp[s] = p;
      if (pf[p] < 0 || s < pf[p]) pf[p] = s;
    }
  }
  // Sentences without boxes (display:none, empty) take the page of the sentence before them.
  let last = 0;
  for (let s = 0; s < sp.length; s++) {
    if (sp[s] < 0) sp[s] = last;
    else last = sp[s];
  }
  state.sentencePages = sp;
  state.pageFirstSentence = pf;
}

// ---------- current page and navigation ----------

let targetPage: number | null = null; // paginated: the page a smooth scroll is heading to
let targetY: number | null = null; // scrolled: the offset a smooth scroll is heading to

const smoothOK = 'scrollBehavior' in document.documentElement.style;

const clampPage = (p: number): number => (p < 0 ? 0 : p >= state.pageCount ? state.pageCount - 1 : p);

export function currentPage(): number {
  return clampPage(
    mode() === 'paginated' ? Math.round(window.pageXOffset / state.W) : Math.floor((window.pageYOffset + 1) / state.H),
  );
}

/** Page the reader is on or is animating to. */
export function logicalPage(): number {
  if (targetPage != null) return targetPage;
  if (targetY != null) return clampPage(Math.floor((targetY + 1) / state.H));
  return currentPage();
}

/** True while a smooth scroll started here has not settled yet. */
export function animating(): boolean {
  return targetPage != null || targetY != null;
}

export function clearTarget(): void {
  targetPage = null;
  targetY = null;
}

// In native paging the platform scroll view animates page turns; script must never do it.
const smooth = (animated: boolean): boolean => animated && paging() === 'snap' && smoothOK;

function scrollTo(x: number, y: number, animated: boolean): void {
  if (smooth(animated)) window.scrollTo({ left: x, top: y, behavior: 'smooth' });
  else window.scrollTo(x, y);
}

const maxY = (): number => Math.max(0, scroller().scrollHeight - state.H);

/** Scrolled mode: scrolls to offset y (clamped to the document); returns the offset. Whole pixels:
 *  that is where the engines land, so a step computed from targetY while a smooth scroll runs
 *  matches one computed after it (a line within half a pixel of the band's edge would otherwise
 *  count as in on one and out on the other). */
function scrollToY(y: number, animated: boolean): number {
  y = Math.round(Math.max(0, Math.min(maxY(), y)));
  const moving = smooth(animated) && Math.abs(y - window.pageYOffset) > 0.5;
  scrollTo(0, y, animated);
  targetY = moving ? y : null;
  targetPage = null;
  return y;
}

export function scrollToPage(p: number, animated: boolean): number {
  p = clampPage(Math.floor(p) || 0);
  if (mode() === 'paginated') {
    scrollTo(p * state.W, 0, animated);
    targetPage = smooth(animated) && p !== currentPage() ? p : null;
  } else {
    scrollToY(p * state.H, animated);
  }
  return p;
}

export function nextPage(animated: boolean): boolean {
  if (mode() === 'scrolled') return scrollStep(1, animated);
  const p = logicalPage();
  if (p >= state.pageCount - 1) return false;
  scrollToPage(p + 1, animated);
  return true;
}

export function prevPage(animated: boolean): boolean {
  if (mode() === 'scrolled') return scrollStep(-1, animated);
  const p = logicalPage();
  if (p <= 0) return false;
  scrollToPage(p - 1, animated);
  return true;
}

/** Scrolled mode: the strip of the viewport text is read in, between the top and bottom insets
 *  (native floats its bars and controls over the rest). Viewport coordinates. */
export function band(): { top: number; bottom: number } {
  const H = state.H || window.innerHeight;
  const top = topInset();
  const bottom = H - cssPx('--yy-bottom', 88);
  // Insets that leave less than this were meant for a taller screen: use the whole viewport.
  return bottom - top >= H * 0.3 ? { top, bottom } : { top: 0, bottom: H };
}

// Steps taken in a row, so a step the other way retraces the last one exactly (Space then
// Shift-Space shows the screen before again, not one a line away from it). Dropped when the
// reader is anywhere else (a manual scroll, a jump) and on every relayout.
let steps: { dir: 1 | -1; from: number; to: number }[] = [];

function forgetSteps(): void {
  steps = [];
}

/** Scrolled page step (Space, Page Down and the like on the Mac). It moves by about one band, from
 *  the offset a running smooth scroll is heading to so repeated presses add up, and lands on a line:
 *  the last line whose glyphs are wholly inside the band becomes the first one (stepping back, the
 *  first becomes the last), so one line overlaps and the line the band's edge cut through is shown
 *  whole. Where no line fits (a tall picture) it steps max(0.875, 1 - 40px) of the band, like
 *  WebKit. Returns false only at the ends. */
function scrollStep(dir: 1 | -1, animated: boolean): boolean {
  const base = targetY != null ? targetY : window.pageYOffset;
  if (dir > 0 ? base >= maxY() - 1 : base <= 0.5) return false;
  const last = steps.length ? steps[steps.length - 1] : null;
  if (!last || Math.abs(last.to - base) > 1) steps = [];
  else if (last.dir !== dir) {
    steps.pop();
    scrollToY(last.from, animated);
    return true;
  }
  const b = band();
  const bandH = b.bottom - b.top;
  // Boxes are measured at the current offset; `off` moves them to where they will be at `base`.
  const off = base - window.pageYOffset;
  const q = docChars();
  let y = NaN;
  if (dir > 0) {
    const n = firstIndexWhere(q, (r) => r.bottom - off > b.bottom + 0.5);
    const c = n > 0 ? boxAt(q, Math.min(n, q.total) - 1, -1) : null;
    if (c && c.r.top - off >= b.top - 0.5) y = base + c.r.top - off - halfLeading(c.node, c.r) - b.top;
    if (!(y - base >= bandH / 3)) y = base + Math.max(bandH * 0.875, bandH - 40);
  } else {
    const f = firstIndexWhere(q, (r) => r.top - off >= b.top - 0.5);
    const c = f < q.total ? boxAt(q, f, 1) : null;
    if (c && c.r.bottom - off <= b.bottom + 0.5) {
      // The earliest line the band can start on and still show all of c's glyphs at its bottom.
      const minTop = c.r.bottom - off - bandH;
      const hl = halfLeading(c.node, c.r);
      const g = firstIndexWhere(q, (r) => r.top - off - hl >= minTop - 0.5);
      const d = g < q.total ? boxAt(q, g, 1) : null;
      if (d) y = base + d.r.top - off - halfLeading(d.node, d.r) - b.top;
    }
    if (!(base - y >= bandH / 3)) y = base - Math.max(bandH * 0.875, bandH - 40);
  }
  steps.push({ dir, from: base, to: scrollToY(y, animated) });
  return true;
}

/** First box of an element, or of the nearest following content when it has none. */
function firstRectOf(el: Element): ClientRect | null {
  let rs = visibleRects(el);
  if (rs.length) return rs[0];
  const range = document.createRange();
  range.selectNode(el);
  rs = Array.prototype.slice.call(range.getClientRects());
  if (rs.length) return rs[0];
  let cur: Node | null = el;
  for (let guard = 0; guard < 200 && cur; guard++) {
    cur = nextNode(cur);
    if (cur && cur.nodeType === 1) {
      rs = visibleRects(cur as Element);
      if (rs.length) return rs[0];
    }
  }
  return null;
}

function nextNode(n: Node): Node | null {
  if (n.firstChild) return n.firstChild;
  while (n) {
    if (n.nextSibling) return n.nextSibling;
    n = n.parentNode as Node;
    if (!n || n === content) return null;
  }
  return null;
}

/** Space between the top of a line box and the top of a box on that line (text in one font is
 *  centred in its line). */
function halfLeading(node: Node, r: ClientRect): number {
  const el = node.nodeType === 1 ? (node as Element) : node.parentElement;
  const lh = el ? parseFloat(getComputedStyle(el).lineHeight) : NaN;
  return lh > r.height ? (lh - r.height) / 2 : 0;
}

/** Where a scroll target goes in scrolled mode. 'top': its line starts the band (restoring a reading
 *  position). 'third': a third of the way down the screen, so the text before it stays in view
 *  (following the voice, links). */
export type Align = 'top' | 'third';

function scrollToRect(r: ClientRect, el: Node, animated: boolean, align: Align): number {
  // The page the target is on, as sentencePages counts it; taken before r goes stale.
  const p = pageOfRect(r);
  if (mode() === 'paginated') return scrollToPage(p, animated);
  const y = r.top + window.pageYOffset;
  scrollToY(align === 'top' ? y - halfLeading(el, r) - band().top : y - state.H / 3, animated);
  return p;
}

/** First line box of sentence s (null when it has none: hidden). */
function startOf(s: number): { el: HTMLElement; r: ClientRect } | null {
  for (const f of fragmentsOf(s)) {
    const rs = visibleRects(f);
    if (rs.length) return { el: f, r: rs[0] };
  }
  return null;
}

export function scrollToSentence(s: number, animated: boolean, align: Align = 'third'): number {
  if (mode() === 'paginated') {
    const p = state.sentencePages[s];
    return scrollToPage(p == null ? 0 : p, animated);
  }
  const st = startOf(s);
  return st ? scrollToRect(st.r, st.el, animated, align) : currentPage();
}

export function scrollToAnchor(id: string, animated: boolean, align: Align = 'third'): number {
  const el = id ? document.getElementById(id) : null;
  if (!el) return -1;
  const r = firstRectOf(el);
  if (!r) return -1;
  return scrollToRect(r, el, animated, align);
}

// ---------- reading-position anchors ----------
// An anchor is the first character the reader sees: the first on the current page (paginated), or
// the first at the top of the band (scrolled, with dy keeping its exact offset from the band's top).
// Relayouts (settings, resize, late images, fonts) bring it back, so the text the reader was looking
// at stays on screen even when the sentence started earlier.

export interface Anchor {
  node: Node;
  offset: number; // -1: the anchor is the element itself (e.g. an image-only page)
  s: number;
  dy?: number; // scrolled: top of the anchor's box minus the top of the band, when captured
}

const skipText = (t: Node): boolean => {
  for (let p = t.parentNode as Element | null; p && p !== content; p = p.parentNode as Element | null) {
    const tag = p.nodeName;
    if (tag === 'RT' || tag === 'RP') return true;
    if (p.classList && p.classList.contains('yy-noteref')) return true;
  }
  return false;
};

function textNodesOf(els: HTMLElement[]): Text[] {
  const out: Text[] = [];
  for (const el of els) {
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
    for (let t = w.nextNode(); t; t = w.nextNode()) {
      if ((t as Text).data.length && !skipText(t)) out.push(t as Text);
    }
  }
  return out;
}

/** A run of text nodes addressed by character index. */
interface Chars {
  nodes: Text[];
  starts: number[];
  total: number;
}

function charsOf(nodes: Text[]): Chars {
  const starts: number[] = [];
  let total = 0;
  for (const t of nodes) {
    starts.push(total);
    total += t.data.length;
  }
  return { nodes, starts, total };
}

// All sentence text of the section, in document order (the text never changes after boot).
let allChars: Chars | null = null;
const docChars = (): Chars => allChars || (allChars = charsOf(textNodesOf(frags)));

function charAt(q: Chars, i: number): { node: Text; offset: number } {
  let lo = 0;
  let hi = q.nodes.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (q.starts[mid] <= i) lo = mid;
    else hi = mid - 1;
  }
  return { node: q.nodes[lo], offset: i - q.starts[lo] };
}

const range = (): Range => document.createRange();

function charRect(node: Text, off: number): ClientRect | null {
  const r = range();
  r.setStart(node, off);
  r.setEnd(node, Math.min(node.data.length, off + 1));
  const rs = r.getClientRects();
  for (let k = 0; k < rs.length; k++) if (rs[k].width > 0 || rs[k].height > 0) return rs[k];
  return null;
}

/** The character at index i, or the nearest one with a box in direction dir (collapsed white space
 *  has none). */
function boxAt(q: Chars, i: number, dir: 1 | -1): { node: Text; offset: number; r: ClientRect } | null {
  for (let j = i, k = 0; j >= 0 && j < q.total && k < 24; j += dir, k++) {
    const c = charAt(q, j);
    const r = charRect(c.node, c.offset);
    if (r) return { node: c.node, offset: c.offset, r };
  }
  return null;
}

/** Binary search for the first character whose box satisfies `pred` (monotonic in document order);
 *  q.total when there is none. */
function firstIndexWhere(q: Chars, pred: (r: ClientRect) => boolean): number {
  let lo = 0;
  let hi = q.total;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    const b = boxAt(q, mid, 1);
    if (!b || pred(b.r)) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

/** Scrolled mode: the first character whose box is at least half below the top of the band (text
 *  above it is under native's bars); the last character when all text is above (a section that
 *  ends in a picture). */
function firstInBand(): { node: Text; offset: number; r: ClientRect; s: number } | null {
  const q = docChars();
  if (!q.total) return null;
  const top = band().top;
  const i = firstIndexWhere(q, (r) => r.top + r.height / 2 >= top);
  const c = i < q.total ? boxAt(q, i, 1) || boxAt(q, i, -1) : boxAt(q, q.total - 1, -1);
  if (!c) return null;
  const s = sentenceOf(c.node.parentElement);
  return { node: c.node, offset: c.offset, r: c.r, s: s == null ? -1 : s };
}

/** In paginated mode the anchor is the start of the first sentence that starts on the page, not the
 *  first character on it. The two differ whenever a sentence straddles the page break, and native's
 *  reading position is a sentence index: native saves the same sentence for the page (the first s
 *  with sentencePages[s] == p), so a relayout cannot leave reader and saved position on different
 *  pages. The cost: when the layout changes, the tail of the sentence before can move off the top of
 *  the screen. A page on which no sentence starts (a long one fills it) keeps its first character. */
export function captureAnchor(): Anchor | null {
  if (mode() !== 'paginated') {
    const c = firstInBand();
    return c ? anchorOfChar(c) : null;
  }
  const p = logicalPage();
  const first = state.pageFirstSentence[p];
  for (let s = first == null ? -1 : first; s >= 0 && s < state.sentenceCount; s++) {
    const sp = state.sentencePages[s];
    if (sp > p) break;
    if (sp === p) {
      const a = sentenceAnchor(s);
      if (a) return a;
    }
  }
  return pageTopAnchor(p);
}

/** The first character of sentence `s` that has a box, as an anchor. */
export function sentenceAnchor(s: number): Anchor | null {
  const q = charsOf(textNodesOf(fragmentsOf(s)));
  const c = q.total ? boxAt(q, 0, 1) : null;
  return c ? { node: c.node, offset: c.offset, s } : null;
}

function anchorOfChar(c: { node: Text; offset: number; r: ClientRect }): Anchor {
  const s = sentenceOf(c.node.parentElement);
  return { node: c.node, offset: c.offset, s: s == null ? -1 : s, dy: c.r.top - band().top };
}

/** First character on page `p` (any sentence, the tail of one that started earlier included): the
 *  page says where the reader is, so a mode switch to scrolled starts there rather than at the
 *  sentence boundary the paginated anchor prefers. */
export function pageTopAnchor(pg?: number): Anchor | null {
  if (!state.W) return null;
  const p = Math.max(0, Math.min(state.pageCount - 1, pg == null ? logicalPage() : pg));
  const s = state.pageFirstSentence[p];
  if (s == null || s < 0) {
    // A page without sentences (an illustration): anchor to the first picture on it.
    const pics = content.querySelectorAll('img, svg, video, figure, table');
    for (let i = 0; i < pics.length; i++) {
      const r = visibleRects(pics[i]);
      if (r.length && pageOfRect(r[0]) === p) return { node: pics[i], offset: -1, s: -1 };
    }
    return null;
  }
  const q = charsOf(textNodesOf(fragmentsOf(s)));
  const i = firstIndexWhere(q, (r) => pageOfRect(r) >= p);
  const c = i < q.total ? boxAt(q, i, 1) : null;
  return c ? { node: c.node, offset: c.offset, s } : { node: fragmentsOf(s)[0], offset: -1, s };
}

/** Viewport rect of the anchor in the current layout. */
function anchorRect(a: Anchor): ClientRect | null {
  if (!a.node.parentNode && a.node !== content) return null;
  if (a.offset >= 0 && a.node.nodeType === 3) {
    const t = a.node as Text;
    for (let o = a.offset; o < Math.min(t.data.length, a.offset + 24); o++) {
      const r = charRect(t, o);
      if (r) return r;
    }
  }
  return a.node.nodeType === 1 ? firstRectOf(a.node as Element) : null;
}

/** Page the anchor is on now (-1 when it is gone). */
export function pageOfAnchor(a: Anchor): number {
  const r = anchorRect(a);
  return r ? pageOfRect(r) : -1;
}

/** Scrolls (instantly) so the anchor is visible again; returns the page. Scrolled mode puts it back
 *  at its offset in the band, or, for an anchor taken in paginated mode, starts the band with its
 *  line. */
export function restoreAnchor(a: Anchor | null): number {
  const r = a ? anchorRect(a) : null;
  if (!a || !r) {
    if (a && a.s >= 0) return scrollToSentence(a.s, false, 'top');
    return scrollToPage(currentPage(), false);
  }
  if (mode() === 'paginated') return scrollToPage(pageOfRect(r), false);
  const y = r.top + window.pageYOffset - band().top;
  scrollToY(a.dy != null ? y - a.dy : y - halfLeading(a.node, r), false);
  return currentPage();
}

/** The sentence a reading position is saved as (paginated: the first on the page; scrolled: what
 *  `scroll` reports). In scrolled mode that is the sentence of the first character in the band,
 *  except when that sentence began above the band and the next one begins on the same line: then
 *  the next one. Restoring it with align 'top' shows the same line at the top, whereas the earlier
 *  sentence would move each save-and-restore back by a line or more. */
export function firstVisibleSentence(): number | null {
  if (mode() === 'scrolled') {
    const c = firstInBand();
    if (c) {
      if (c.s < 0) return null;
      const st = startOf(c.s);
      if (st && st.r.top + st.r.height / 2 < band().top && c.s + 1 < state.sentenceCount) {
        const n = startOf(c.s + 1);
        if (n && n.r.top < c.r.bottom && n.r.bottom > c.r.top) return c.s + 1;
      }
      return c.s;
    }
  }
  const s = state.pageFirstSentence[currentPage()];
  return s != null && s >= 0 ? s : null;
}
