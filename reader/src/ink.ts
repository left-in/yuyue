// The ink line (墨线, contract §7): a 1.5px line under the sentence being read that grows over
// the sentence's audio duration.
//
// Each fragment's line is its own background (reader.css .s), grown with one Web Animation on
// background-size. A wrapped inline box paints its background as if its line boxes were laid end
// to end (box-decoration-break: slice), so one 0% -> 100% animation sweeps every line of the
// fragment in reading order. Fragments run back to back: fragment i starts after the share of the
// sentence's characters that precede it. Seeking is `currentTime`, pausing is `pause()`.
//
// The same proportions predict when the head of the line crosses onto another page: inside a
// fragment the head moves at constant speed along the concatenated line boxes, so the moment it
// reaches line box j is start + dur * (width of the boxes before j / total width).

import { post } from './bridge';
import { fragmentsOf, pageOfRect, state } from './layout';

interface Seg {
  el: HTMLElement;
  start: number;
  dur: number;
  anim: Animation | null;
}

let active: number | null = null;
let segs: Seg[] = [];
let total = 0;
let playing = false;
let full = false;
// The reader's own clock: `base` ms of the sentence had elapsed at performance time `at`.
let base = 0;
let at = 0;
let events: { t: number; page: number }[] = [];
let timers: number[] = [];
let postedPage = -1;

const now = (): number => (window.performance && performance.now ? performance.now() : Date.now());

export function elapsed(): number {
  const e = playing ? base + (now() - at) : base;
  return Math.max(0, Math.min(total, e));
}

export function activeSentence(): number | null {
  return active;
}

function spokenLength(el: Element): number {
  let n = 0;
  const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
  for (let t = w.nextNode(); t; t = w.nextNode()) {
    let skip = false;
    for (let p = t.parentNode as Element | null; p && p !== el.parentNode; p = p.parentNode as Element | null) {
      if (p.nodeName === 'RT' || p.nodeName === 'RP' || (p.classList && p.classList.contains('yy-noteref'))) {
        skip = true;
        break;
      }
    }
    if (!skip) n += (t as Text).data.replace(/\s+/g, ' ').length;
  }
  return n;
}

function useFull(): boolean {
  const root = document.documentElement;
  return (
    root.getAttribute('data-yy-motion') === 'reduced' ||
    root.getAttribute('data-yy-paper') === 'eink' ||
    typeof (document.documentElement as HTMLElement).animate !== 'function'
  );
}

function inkWidth(): string {
  const v = getComputedStyle(document.documentElement).getPropertyValue('--yy-ink-w').trim();
  return v || '1.5px';
}

function clearTimers(): void {
  for (const t of timers) clearTimeout(t);
  timers = [];
}

function teardown(): void {
  clearTimers();
  for (const s of segs) {
    if (s.anim) s.anim.cancel();
    s.el.classList.remove('yy-ink', 'yy-ink-full');
  }
  segs = [];
  events = [];
}

/** Page-crossing schedule for the current layout. */
function buildEvents(): void {
  events = [];
  for (const s of segs) {
    const rs = s.el.getClientRects();
    const boxes: { w: number; page: number }[] = [];
    let sum = 0;
    for (let k = 0; k < rs.length; k++) {
      if (rs[k].width <= 0) continue;
      boxes.push({ w: rs[k].width, page: pageOfRect(rs[k]) });
      sum += rs[k].width;
    }
    let before = 0;
    for (const b of boxes) {
      const t = s.start + (sum > 0 ? (s.dur * before) / sum : 0);
      const last = events[events.length - 1];
      if (!last || last.page !== b.page) events.push({ t, page: b.page });
      before += b.w;
    }
  }
}

function pageAt(e: number): number {
  let page = events.length ? events[0].page : -1;
  for (const ev of events) {
    if (ev.t <= e) page = ev.page;
    else break;
  }
  return page;
}

function emit(page: number): void {
  if (active == null || page < 0 || page === postedPage) return;
  postedPage = page;
  post({ type: 'activePage', sentence: active, page });
}

function schedule(): void {
  clearTimers();
  if (!playing || active == null) return;
  const e = elapsed();
  for (const ev of events) {
    if (ev.t <= e) continue;
    const page = ev.page;
    timers.push(window.setTimeout(() => emit(page), ev.t - e));
  }
}

function sync(s: Seg, e: number): void {
  const a = s.anim;
  if (!a) return;
  const end = s.start + s.dur;
  a.currentTime = Math.max(0, Math.min(end, e));
  // play() on a finished animation rewinds it to the start, so only resume unfinished ones.
  if (playing && e < end) {
    if (a.playState !== 'running') a.play();
  } else if (a.playState !== 'paused') {
    a.pause();
  }
}

export interface ActiveOptions {
  durationMs?: number | null;
  elapsedMs?: number | null;
  playing?: boolean | null;
}

export function setActive(s: number | null, opts?: ActiveOptions | null): void {
  const o = opts || {};
  if (s == null || !(s >= 0) || !fragmentsOf(s).length) {
    teardown();
    active = null;
    total = 0;
    base = 0;
    postedPage = -1;
    return;
  }
  const e = o.elapsedMs != null && o.elapsedMs >= 0 ? o.elapsedMs : 0;
  const play = o.playing != null ? !!o.playing : true;
  const frags = fragmentsOf(s);
  const lens = frags.map(spokenLength);
  const chars = lens.reduce((a, b) => a + b, 0);
  const dur = o.durationMs != null && o.durationMs > 0 ? o.durationMs : Math.max(1800, chars * 120);

  if (s === active && dur === total && full === useFull()) {
    // Same sentence: just seek / pause / resume.
    base = Math.min(dur, e);
    at = now();
    playing = play;
    for (const g of segs) sync(g, base);
    schedule();
    emit(pageAt(base));
    return;
  }
  if (s !== active) postedPage = -1;
  build(s, dur, e, play);
}

function build(s: number, dur: number, e: number, play: boolean): void {
  teardown();
  const frags = fragmentsOf(s);
  const lens = frags.map(spokenLength);
  const chars = lens.reduce((a, b) => a + b, 0);
  active = s;
  total = dur;
  base = Math.min(dur, e);
  at = now();
  playing = play;
  full = useFull();
  let acc = 0;
  const w = inkWidth();
  frags.forEach((el, i) => {
    const share = chars > 0 ? lens[i] / chars : 1 / frags.length;
    const seg: Seg = { el, start: dur * acc, dur: Math.max(1, dur * share), anim: null };
    acc += share;
    el.classList.add('yy-ink');
    if (full) {
      el.classList.add('yy-ink-full');
    } else {
      seg.anim = el.animate([{ backgroundSize: '0% ' + w }, { backgroundSize: '100% ' + w }], {
        duration: seg.dur,
        delay: seg.start,
        fill: 'both',
        easing: 'linear',
      });
    }
    segs.push(seg);
  });
  for (const g of segs) sync(g, base);
  buildEvents();
  schedule();
  emit(pageAt(base));
}

export function setPlaying(p: boolean): void {
  if (active == null) {
    playing = !!p;
    return;
  }
  if (!!p === playing) return;
  base = elapsed();
  at = now();
  playing = !!p;
  for (const g of segs) sync(g, base);
  schedule();
}

/** After a relayout or a paper/motion change: same sentence and timing, new geometry. */
/** Builds the line again on the sentence's new fragments, after the content was rebuilt (气泡). */
export function rebuild(): void {
  if (active != null) build(active, total, elapsed(), playing);
}

export function refresh(): void {
  if (active == null) return;
  const e = elapsed();
  if (useFull() !== full) {
    build(active, total, e, playing);
    return;
  }
  base = e;
  at = now();
  buildEvents();
  schedule();
  emit(pageAt(e));
}

/** Debug/test view of the ink state. */
export function inkState(): {
  sentence: number | null;
  elapsed: number;
  duration: number;
  playing: boolean;
  full: boolean;
  events: { t: number; page: number }[];
  pageCount: number;
} {
  return { sentence: active, elapsed: elapsed(), duration: total, playing, full, events: events.slice(), pageCount: state.pageCount };
}
