// Taps (contract §5 `tap`). Only real taps are reported: no movement beyond a small slop, no long
// press, no scroll in between, and no text selection at either end, so selecting text, dragging
// and swiping pages never produce one. Nothing here calls preventDefault on pointer events, so
// the engines' own selection gestures keep working.

import { post, Link } from './bridge';
import { sentenceOf } from './layout';
import { markAt } from './marks';
import { wordAt } from './foreign';

interface Down {
  id: number;
  x: number;
  y: number;
  t: number;
  sx: number;
  sy: number;
  type: string;
  moved: boolean;
}

const LONG_PRESS_MS = 500;
// A mouse tap waits this long so a double click (word selection) does not also count as a tap.
const DOUBLE_CLICK_MS = 280;

let content: HTMLElement;
let down: Down | null = null;
let pending: number | null = null;
let isScrollAnimating: () => boolean = () => false;

const now = (): number => (window.performance && performance.now ? performance.now() : Date.now());

function hasSelection(): boolean {
  const s = window.getSelection ? window.getSelection() : null;
  return !!s && !s.isCollapsed && s.toString().length > 0;
}

function linkOf(el: Element | null): Link | null {
  const a = el && el.closest ? el.closest('a') : null;
  if (!a) return null;
  const target = a.getAttribute('data-yy-target');
  if (target != null) {
    if (!a.classList.contains('yy-noteref')) return { target };
    return { target, note: { label: (a.textContent || '').trim(), before: wordsBefore(a) } };
  }
  const ext = a.getAttribute('data-yy-external');
  if (ext != null) return { external: ext };
  return null;
}

/** The words before a note marker back to the last punctuation in its paragraph, at most 16
 *  characters: "都是当街一个曲尺形的大柜台¹" → "都是当街一个曲尺形的大柜台". */
function wordsBefore(a: Element): string {
  const block = a.closest('p, li, div, blockquote, td, h1, h2, h3, h4, h5, h6');
  if (!block) return '';
  const range = document.createRange();
  range.setStart(block, 0);
  range.setEndBefore(a.closest('sup') || a);
  const text = range.toString().replace(/\s+/g, ' ').replace(/ $/, '');
  const cut = Math.max(...['，', '。', '；', '：', '！', '？', '、', ',', '.', ';', ':', '!', '?', '“', '”', '"'].map((p) => text.lastIndexOf(p)));
  const words = text.slice(cut + 1).trim();
  return words.length > 16 ? '…' + words.slice(-16) : words;
}

interface CaretDoc {
  caretPositionFromPoint?(x: number, y: number): { offsetNode: Node } | null;
  caretRangeFromPoint?(x: number, y: number): Range | null;
}

function caretNode(x: number, y: number): Node | null {
  const d = document as unknown as CaretDoc;
  if (d.caretRangeFromPoint) {
    const r = d.caretRangeFromPoint(x, y);
    return r ? r.startContainer : null;
  }
  if (d.caretPositionFromPoint) {
    const p = d.caretPositionFromPoint(x, y);
    return p ? p.offsetNode : null;
  }
  return null;
}

/** Sentence under the point. Taps between the lines or on the indent of a paragraph resolve to
 *  the nearest sentence of that paragraph; taps in the margins resolve to null. */
function sentenceAt(target: Element | null, x: number, y: number): number | null {
  const direct = sentenceOf(target);
  if (direct != null) return direct;
  if (!target || target === content || !content.contains(target)) return null;
  const n = caretNode(x, y);
  const el = n ? (n.nodeType === 1 ? (n as Element) : n.parentElement) : null;
  if (!el || !target.contains(el)) return null;
  return sentenceOf(el);
}

function onDown(e: PointerEvent): void {
  if (pending != null) {
    // Second press of a double click: drop the first tap. In a book read in another language
    // a double click translates the sentence (双击一句只翻这一句).
    clearTimeout(pending);
    pending = null;
    const target = e.target as Element | null;
    post({ type: 'doubleTap', sentence: sentenceAt(target, e.clientX, e.clientY), x: Math.round(e.clientX), y: Math.round(e.clientY) });
  }
  if (down) {
    down = null; // a second finger: a pinch or two-finger gesture, not a tap
    return;
  }
  if (!e.isPrimary || e.button > 0 || hasSelection()) return;
  down = {
    id: e.pointerId,
    x: e.clientX,
    y: e.clientY,
    t: now(),
    sx: window.pageXOffset,
    sy: window.pageYOffset,
    type: e.pointerType || 'mouse',
    moved: false,
  };
}

function slop(d: Down): number {
  return d.type === 'mouse' ? 6 : 10;
}

function onMove(e: PointerEvent): void {
  const d = down;
  if (!d || e.pointerId !== d.id || d.moved) return;
  if (Math.abs(e.clientX - d.x) > slop(d) || Math.abs(e.clientY - d.y) > slop(d)) d.moved = true;
}

function onUp(e: PointerEvent): void {
  const d = down;
  down = null;
  if (!d || e.pointerId !== d.id) return;
  if (d.moved || now() - d.t > LONG_PRESS_MS || hasSelection()) return;
  if (Math.abs(e.clientX - d.x) > slop(d) || Math.abs(e.clientY - d.y) > slop(d)) return;
  // The page moved under the finger (a swipe the scroll view took over) unless it was our own
  // smooth page turn still running from an earlier tap.
  const scrolled = Math.abs(window.pageXOffset - d.sx) > 1 || Math.abs(window.pageYOffset - d.sy) > 1;
  if (scrolled && !isScrollAnimating()) return;

  const target = e.target as Element | null;
  const link = linkOf(target);
  const msg = {
    type: 'tap' as const,
    x: Math.round(e.clientX),
    y: Math.round(e.clientY),
    width: window.innerWidth,
    height: window.innerHeight,
    sentence: link ? sentenceOf(target) : sentenceAt(target, e.clientX, e.clientY),
    link,
    mark: link ? null : markAt(e.clientX, e.clientY),
    word: link ? null : wordAt(e.clientX, e.clientY),
  };
  if (d.type === 'mouse' && !link) {
    pending = window.setTimeout(() => {
      pending = null;
      if (!hasSelection()) post(msg);
    }, DOUBLE_CLICK_MS);
  } else {
    post(msg);
  }
}

function onCancel(e: PointerEvent): void {
  if (down && e.pointerId === down.id) down = null;
}

function stopLink(e: Event): void {
  const t = e.target as Element | null;
  // Links never navigate inside the WebView; native decides what a link tap does.
  if (t && t.closest && t.closest('a')) e.preventDefault();
}

export function initTaps(c: HTMLElement, animating: () => boolean): void {
  content = c;
  isScrollAnimating = animating;
  document.addEventListener('pointerdown', onDown, true);
  document.addEventListener('pointermove', onMove, true);
  document.addEventListener('pointerup', onUp, true);
  document.addEventListener('pointercancel', onCancel, true);
  document.addEventListener('click', stopLink, true);
  document.addEventListener('auxclick', stopLink, true);
  // A drag (of a link, a picture or selected text) is never a tap.
  document.addEventListener('dragstart', () => (down = null), true);
}
