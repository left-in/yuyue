// Reader -> native messages (contract §5).
// Apple: window.webkit.messageHandlers.yy.postMessage(obj)
// Android: window.yyNative.postMessage(JSON.stringify(obj))
// Neither (tests, demo): queued on window.yyOutbox and, inside an iframe, forwarded to the parent.

import type { WordHit } from './foreign';

export interface Geometry {
  section: number;
  pageCount: number;
  pageWidth: number;
  pageHeight: number;
  sentencePages: number[];
  pageFirstSentence: number[];
}

/** A link in the book. A note marker (`.yy-noteref`) also says what it shows ("1") and the
 *  words just before it, for the card native opens in place. */
export type Link = { target: string; note?: { label: string; before: string } } | { external: string };

export type Message =
  | ({ type: 'ready' | 'layout' } & Geometry)
  | {
      type: 'tap';
      x: number;
      y: number;
      width: number;
      height: number;
      sentence: number | null;
      link: Link | null;
      mark: string | null;
      /** 点词: the word clicked, in a book read in another language. */
      word: WordHit | null;
    }
  | { type: 'doubleTap'; sentence: number | null; x: number; y: number }
  | {
      type: 'selection';
      start: { s: number; o: number } | null;
      end: { s: number; o: number } | null;
      text: string | null;
      rect: { x: number; y: number; width: number; height: number } | null;
    }
  | { type: 'activePage'; sentence: number; page: number }
  | { type: 'page'; page: number }
  | { type: 'scroll'; sentence: number | null; progress: number }
  | { type: 'log'; level: 'debug' | 'info' | 'warn' | 'error'; message: string };

interface BridgeWindow {
  webkit?: { messageHandlers?: { yy?: { postMessage(m: unknown): void } } };
  yyNative?: { postMessage(s: string): void };
  yyOutbox?: Message[];
}

export function post(msg: Message): void {
  const w = window as unknown as BridgeWindow;
  try {
    const apple = w.webkit && w.webkit.messageHandlers && w.webkit.messageHandlers.yy;
    if (apple) {
      apple.postMessage(msg);
      return;
    }
    if (w.yyNative && typeof w.yyNative.postMessage === 'function') {
      w.yyNative.postMessage(JSON.stringify(msg));
      return;
    }
  } catch (e) {
    // fall through to the queue so nothing is lost while debugging
  }
  (w.yyOutbox || (w.yyOutbox = [])).push(msg);
  if (window.parent !== window) {
    try {
      window.parent.postMessage({ yy: msg }, '*');
    } catch (e) {
      /* cross-origin parent without a listener: ignore */
    }
  }
}

export function log(level: 'debug' | 'info' | 'warn' | 'error', message: string): void {
  post({ type: 'log', level, message });
}
