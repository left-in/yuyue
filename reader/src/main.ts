// 语阅 reader: runs inside the section document (contract §2), exposes window.yy (§4) and posts
// messages to native (§5).

import { post, log, Geometry } from './bridge';
import * as L from './layout';
import { classify } from './typography';
import * as ink from './ink';
import { applyToRoot, currentSettings, normalizeRoot, Settings } from './settings';
import { initTaps } from './taps';
import { fitCompression } from './compress';
import * as marks from './marks';
import * as foreign from './foreign';
import * as bubbles from './bubbles';

const VERSION = '0.1.0';

const root = document.documentElement;
const content = (document.getElementById('yy-content') || document.body) as HTMLElement;
const section = parseInt(content.getAttribute('data-section') || '0', 10) || 0;

let ready = false;
let lastGeometry = '';

// Reading position kept across relayouts. Captured when a scroll settles; cleared by programmatic
// navigation (the next settle or relayout captures a fresh one). Reusing it, rather than capturing
// again on every relayout, stops the position from creeping backwards over a series of font-size
// steps or resize events.
let lastAnchor: L.Anchor | null = null;
let settled = { x: 0, y: 0 };

function geometry(): Geometry {
  const s = L.state;
  return {
    section,
    pageCount: s.pageCount,
    pageWidth: s.W,
    pageHeight: s.H,
    sentencePages: s.sentencePages.slice(),
    pageFirstSentence: s.pageFirstSentence.slice(),
  };
}

function anchorNow(): L.Anchor | null {
  if (lastAnchor && document.contains(lastAnchor.node)) return lastAnchor;
  return L.captureAnchor();
}

/** Everything that depends on the fonts and the viewport, then the page geometry. */
function measure(): void {
  fitCompression(content);
  L.measure();
}

function relayout(anchor: L.Anchor | null, always: boolean): void {
  cancelPending();
  const t0 = performance.now();
  measure();
  L.restoreAnchor(anchor);
  lastAnchor = anchor;
  settled = { x: window.pageXOffset, y: window.pageYOffset };
  L.clearTarget();
  ink.refresh();
  marks.placeSource();
  marks.placeFills();
  foreign.drawGlosses();
  // A re-layout moves the text under the finger, so the position a scrolled section reports has
  // changed even without a scroll event (postScroll drops it when the value is the same).
  if (ready && L.mode() === 'scrolled') postScroll(true);
  const g = geometry();
  const key = JSON.stringify(g);
  const changed = key !== lastGeometry;
  lastGeometry = key;
  if (ready && (always || changed)) post({ type: 'layout', ...g });
  if (ready) postPageIfChanged();
  const ms = performance.now() - t0;
  if (ms > 100) log('debug', 'relayout took ' + Math.round(ms) + 'ms for ' + g.pageCount + ' pages');
}

// ---------- deferred relayouts (resize, late images, late fonts) ----------

let pendingAnchor: L.Anchor | null | undefined;
let pendingTimer = 0;

function cancelPending(): void {
  if (pendingTimer) clearTimeout(pendingTimer);
  pendingTimer = 0;
  pendingAnchor = undefined;
}

function requestRelayout(delay: number): void {
  if (!ready) return;
  // Decide the anchor now: in scrolled mode a resize has already reflowed the text.
  if (pendingAnchor === undefined) pendingAnchor = anchorNow();
  if (pendingTimer) return;
  pendingTimer = window.setTimeout(() => {
    const a = pendingAnchor === undefined ? anchorNow() : pendingAnchor;
    pendingTimer = 0;
    pendingAnchor = undefined;
    relayout(a, false);
  }, delay);
}

// ---------- scroll tracking ----------

let settleTimer = 0;
let postedPage = 0;
let lastScrollPost = 0;
let scrollPostTimer = 0;
let lastScrollMsg = { sentence: null as number | null, progress: -1 };

function postPageIfChanged(): void {
  if (L.mode() !== 'paginated' || L.paging() !== 'snap') return;
  const p = L.currentPage();
  if (p !== postedPage) {
    postedPage = p;
    post({ type: 'page', page: p });
  }
}

function scrollProgress(): number {
  const el = document.scrollingElement || root;
  const max = el.scrollHeight - window.innerHeight;
  return max > 0 ? Math.max(0, Math.min(1, window.pageYOffset / max)) : 0;
}

function postScroll(final: boolean): void {
  lastScrollPost = performance.now();
  const sentence = L.firstVisibleSentence();
  const progress = Math.round(scrollProgress() * 10000) / 10000;
  const prev = lastScrollMsg;
  const moved = Math.abs(progress - prev.progress) >= (final ? 0.0001 : 0.01);
  if (sentence === prev.sentence && !moved) return;
  lastScrollMsg = { sentence, progress };
  post({ type: 'scroll', sentence, progress });
}

function onSettle(): void {
  settleTimer = 0;
  L.clearTarget();
  const x = window.pageXOffset;
  const y = window.pageYOffset;
  if (Math.abs(x - settled.x) > 0.5 || Math.abs(y - settled.y) > 0.5) {
    settled = { x, y };
    lastAnchor = L.captureAnchor();
    if (pendingTimer) pendingAnchor = lastAnchor || undefined;
  }
  if (L.mode() === 'scrolled') postScroll(true);
  else postPageIfChanged();
}

function onScroll(): void {
  if (!ready) return;
  if (settleTimer) clearTimeout(settleTimer);
  settleTimer = window.setTimeout(onSettle, 120);
  if (L.mode() !== 'scrolled') return;
  // Throttled: at most one `scroll` message per 150ms while scrolling, plus one when it settles.
  const since = performance.now() - lastScrollPost;
  if (since >= 150) postScroll(false);
  else if (!scrollPostTimer) {
    scrollPostTimer = window.setTimeout(() => {
      scrollPostTimer = 0;
      postScroll(false);
    }, 150 - since);
  }
}

function onScrollEnd(): void {
  if (!ready) return;
  if (settleTimer) clearTimeout(settleTimer);
  onSettle();
}

// ---------- public API (contract §4) ----------

// After programmatic navigation the anchor is the target page's first character (captured now,
// even while a smooth scroll is still on its way), so a relayout that was already pending (a
// late image) cannot pull the reader back. Scrolled mode waits for the scroll to settle.
function navigated<T>(v: T): T {
  if (L.mode() === 'paginated') {
    lastAnchor = L.captureAnchor();
    settled = { x: L.logicalPage() * L.state.W, y: 0 };
  } else {
    lastAnchor = null;
  }
  if (pendingTimer) pendingAnchor = lastAnchor || undefined;
  return v;
}

/** Third argument of scrollToSentence/scrollToAnchor. align (scrolled mode only): 'top' starts the
 *  band with the target's line (restoring a saved position); 'third', the default, puts it a third
 *  of the way down (following the voice, links). */
interface ScrollOptions {
  align?: 'top' | 'third';
}
const alignOf = (o?: ScrollOptions | null): L.Align => (o && o.align === 'top' ? 'top' : 'third');

const api = {
  version: VERSION,
  applySettings(s: Settings): void {
    if (!s || typeof s !== 'object') return;
    const before = L.mode();
    // What is on screen now. Leaving it for scrolled mode would put the sticky anchor (which a size
    // change can leave anywhere on the page) at the top of the band and hide the text above it.
    const onScreen = before === 'paginated' ? L.pageTopAnchor() : L.captureAnchor();
    const kept = lastAnchor && document.contains(lastAnchor.node) ? lastAnchor : onScreen;
    applyToRoot(s);
    const mode = L.mode();
    relayout(mode !== before ? onScreen : kept, true);
    // Into paginated mode: from here on the position is the page's (its first sentence start), as
    // after a page turn, so it names the sentence native will save for this page.
    if (mode !== before && mode === 'paginated') lastAnchor = L.captureAnchor();
  },
  scrollToPage(p: number, animated?: boolean): number {
    return navigated(L.scrollToPage(p, !!animated));
  },
  nextPage(animated?: boolean): boolean {
    const ok = L.nextPage(!!animated);
    return ok ? navigated(ok) : ok;
  },
  prevPage(animated?: boolean): boolean {
    const ok = L.prevPage(!!animated);
    return ok ? navigated(ok) : ok;
  },
  // options.align: scrolled mode only, 'top' starts the band with the sentence's line (restoring a
  // reading position), 'third' (default) puts it a third of the way down (following the voice).
  scrollToSentence(s: number, animated?: boolean, opts?: ScrollOptions | null): number {
    const p = navigated(L.scrollToSentence(s, !!animated, alignOf(opts)));
    if (L.mode() === 'paginated') {
      // A jump to a sentence is a reading position: keep the anchor on it, so a relayout still shows
      // it rather than the first sentence that happens to start on the page it landed on.
      const a = L.sentenceAnchor(s);
      if (a) {
        lastAnchor = a;
        if (pendingTimer) pendingAnchor = a;
      }
    }
    return p;
  },
  scrollToAnchor(id: string, animated?: boolean, opts?: ScrollOptions | null): number {
    const p = L.scrollToAnchor(String(id || '').replace(/^#/, ''), !!animated, alignOf(opts));
    return p >= 0 ? navigated(p) : p;
  },
  currentPage(): number {
    return L.logicalPage();
  },
  setActive(s: number | null, opts?: ink.ActiveOptions | null): void {
    ink.setActive(s, opts);
  },
  setPlaying(playing: boolean): void {
    ink.setPlaying(!!playing);
  },
  setMarks(list: marks.MarkSpec[] | null): void {
    marks.setMarks(list);
  },
  setHits(query: string | null, current?: { s: number; nth: number } | null): number {
    return marks.setHits(query, current);
  },
  setSource(s: number | null): void {
    marks.setSource(s);
  },
  setLookup(on: boolean): void {
    foreign.setLookup(on);
  },
  setLooking(start: marks.Point | null, end: marks.Point | null): void {
    foreign.setLooking(start, end);
  },
  /** 有声书: the paragraphs holding sentences first…last get an amber line beside them, for a
   *  stretch the recording doesn't line up with; null takes it away. */
  setFlag(first: number | null, last?: number | null): void {
    document.querySelectorAll('.yy-flag').forEach((el) => el.classList.remove('yy-flag'));
    if (first == null || !(first >= 0)) return;
    const end = last != null && last >= first ? last : first;
    for (let s = first; s <= end; s++) foreign.blockOf(s)?.classList.add('yy-flag');
  },
  /** 气泡模式: the section's dialogue as bubbles (§4, setBubbles); null puts it back. */
  setBubbles(lines: bubbles.BubbleLine[] | null): void {
    // The text nodes are rebuilt, so keep the place by sentence.
    const at = L.firstVisibleSentence();
    if (!bubbles.setBubbles(lines)) return;
    L.reindex();
    lastAnchor = null;
    ink.rebuild();
    marks.redraw();
    relayout(null, true);
    if (at != null) L.scrollToSentence(at, false, 'top');
  },
  setVocab(words: string[] | null): void {
    foreign.setVocab(words);
  },
  setGlosses(list: { form: string; gloss: string }[] | null): void {
    foreign.setGlosses(list);
  },
  paragraphs(): foreign.Paragraph[] {
    return foreign.paragraphs();
  },
  setTranslations(list: { last: number; text: string }[] | null): void {
    foreign.setTranslations(list);
    relayout(anchorNow(), true);
  },
  clearSelection(): void {
    marks.clearSelection();
  },
  select(start: marks.Point, end: marks.Point): void {
    marks.select(start, end);
  },
  markRect(id: string): { x: number; y: number; width: number; height: number } | null {
    return marks.markRect(id);
  },
  // Not part of the contract; handy for the demo, tests and debugging from Web Inspector.
  /** The word at a point, or (given a word) its first appearance on screen, as a click there would report it. */
  wordAt(x: number | string, y?: number): foreign.WordHit | null {
    if (typeof x === 'string') {
      const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      const re = new RegExp('\\b' + x + '\\b');
      for (let t = w.nextNode(); t; t = w.nextNode()) {
        const m = re.exec((t as Text).data);
        if (!m) continue;
        const r = document.createRange();
        r.setStart(t, m.index);
        r.setEnd(t, m.index + x.length);
        const b = Array.prototype.slice.call(r.getClientRects()).find((b: DOMRect) => b.right > 0 && b.left < window.innerWidth) as DOMRect | undefined;
        if (b) return foreign.wordAt(b.left + b.width / 2, b.top + b.height / 2);
      }
      return null;
    }
    return foreign.wordAt(x, y || 0);
  },
  anchor(): { s: number; offset: number; dy: number | null; page: number } | null {
    const a = lastAnchor || L.captureAnchor();
    return a ? { s: a.s, offset: a.offset, dy: a.dy == null ? null : a.dy, page: L.pageOfAnchor(a) } : null;
  },
  geometry,
  settings: currentSettings,
  ink: ink.inkState,
  relayout(): void {
    relayout(anchorNow(), true);
  },
};

declare global {
  interface Window {
    yy: typeof api;
  }
}

// ---------- boot ----------

/** Resolves when the web fonts the first layout asked for have loaded or failed, after 3s at most
 *  (a font that never arrives must not hold the page hostage). WebKit resolves fonts.ready only
 *  after the window load event, i.e. after every picture in the section has arrived, so the
 *  status is polled as well; it turns 'loaded' as soon as the fonts are in. */
function fontsReady(): Promise<void> {
  const fonts = (document as unknown as { fonts?: { ready?: Promise<unknown>; status?: string } }).fonts;
  if (!fonts || !fonts.ready) return Promise.resolve();
  return new Promise<void>((resolve) => {
    let done = false;
    const finish = (): void => {
      if (done) return;
      done = true;
      resolve();
    };
    fonts.ready!.then(finish, finish);
    const t0 = Date.now();
    const poll = (): void => {
      if (done) return;
      if (fonts.status === 'loaded' || Date.now() - t0 >= 3000) finish();
      else setTimeout(poll, 20);
    };
    // A task later, so loads that the first layout queued have registered.
    setTimeout(poll, 0);
  });
}

function boot(): void {
  normalizeRoot();
  const kind = content.getAttribute('data-kind');
  if (kind) root.setAttribute('data-yy-kind', kind);
  classify(content);
  L.initLayout(content);
  initTaps(content, L.animating);
  marks.initSelection();
  window.yy = api;
  // Lay out once now: it starts the web-font loads and lets early API calls work.
  measure();
  lastGeometry = JSON.stringify(geometry());

  window.addEventListener('resize', () => requestRelayout(0));
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('scrollend', onScrollEnd);
  document.addEventListener(
    'load',
    (e) => {
      const t = e.target as Element;
      if (t && (t.nodeName === 'IMG' || t.nodeName === 'image' || t.nodeName === 'VIDEO')) requestRelayout(50);
    },
    true,
  );
  document.addEventListener(
    'error',
    (e) => {
      const t = e.target as Element;
      if (t && t.nodeName === 'IMG') requestRelayout(50);
    },
    true,
  );

  fontsReady().then(() => {
    const anchor = anchorNow();
    measure();
    L.restoreAnchor(anchor);
    lastAnchor = anchor;
    settled = { x: window.pageXOffset, y: window.pageYOffset };
    postedPage = L.currentPage();
    ink.refresh();
    const g = geometry();
    lastGeometry = JSON.stringify(g);
    ready = true;
    root.setAttribute('data-yy-ready', '');
    post({ type: 'ready', ...g });
    const fonts = (document as unknown as { fonts?: EventTarget }).fonts;
    if (fonts && fonts.addEventListener) fonts.addEventListener('loadingdone', () => requestRelayout(0));
  });
}

try {
  boot();
} catch (e) {
  log('error', 'boot failed: ' + (e && (e as Error).stack ? (e as Error).stack : String(e)));
  throw e;
}
