// 气泡模式: a book's dialogue as a chat. Narration
// stays a paragraph; each quote becomes a bubble with whoever says it. Short narration that only
// says who speaks (“宝钗因笑道：”) goes into the line above the bubble instead of a paragraph of
// its own. A line nobody is sure of is a grey bubble with “?”.
//
// Only the boxes change: every sentence keeps its `.s[data-s]` fragments, split where a quote
// starts or ends (the contract allows a sentence in several fragments), so the ink line, marks,
// selection and taps work as before. Names and avatars are outside the fragments and never count
// as text. setBubbles(null) puts the section back as it came.

import { sentenceText, textNodes } from './marks';

export interface BubbleLine {
  first: number;
  last: number;
  /** Characters (Unicode scalars) into the first sentence: where the quote's text starts and ends. */
  start: number;
  end: number;
  who: string | null;
  avatar: string;
  color: string;
  right: boolean;
}

let original: string | null = null;

const OPEN = '“"「『';
const CLOSE = '”"」』';
const BLOCKS = ['P', 'DIV', 'LI', 'BLOCKQUOTE', 'DD'];

function content(): HTMLElement {
  return (document.getElementById('yy-content') || document.body) as HTMLElement;
}

/** A character index (scalars, as core counts) as a UTF-16 offset into the sentence's text. */
function utf16(text: string, chars: number): number {
  let n = 0;
  let k = 0;
  for (const ch of text) {
    if (k >= chars) break;
    n += ch.length;
    k++;
  }
  return n;
}

/** The DOM place `o` UTF-16 units into sentence `s`. */
function place(s: number, o: number): { node: Text; offset: number } | null {
  const nodes = textNodes(s);
  let left = o;
  for (const t of nodes) {
    if (left <= t.data.length) return { node: t, offset: left };
    left -= t.data.length;
  }
  const last = nodes[nodes.length - 1];
  return last ? { node: last, offset: last.data.length } : null;
}

function blockOf(n: Node): HTMLElement | null {
  const root = content();
  for (let el = n.parentElement; el && el !== root; el = el.parentElement) {
    if (BLOCKS.indexOf(el.nodeName) >= 0) return el;
  }
  return null;
}

/** Where a line's quote starts and ends, quote marks included. */
function quoteRange(l: BubbleLine): { a: { node: Text; offset: number }; b: { node: Text; offset: number } } | null {
  const first = sentenceText(l.first);
  let from = utf16(first, Math.max(0, l.start - 1));
  if (!OPEN.includes(first.charAt(from))) from = utf16(first, l.start);
  let to: number;
  let endS = l.first;
  if (l.last === l.first) {
    to = utf16(first, l.end);
    if (CLOSE.includes(first.charAt(to))) to += 1;
  } else {
    endS = l.last;
    const last = sentenceText(l.last);
    // The first close: what's after it is narration, or the next line (core's `lines` goes on there).
    let k = -1;
    for (const c of CLOSE) {
      const i = last.indexOf(c);
      if (i >= 0 && (k < 0 || i < k)) k = i;
    }
    to = k >= 0 ? k + 1 : last.length;
  }
  const a = place(l.first, from);
  const b = place(endS, to);
  return a && b ? { a, b } : null;
}

/** The range's contents with the inline elements around them kept (the sentence's `.s`, an
 *  `<em>`): cloneContents drops whatever wraps the range's common ancestor. */
function cut(r: Range, block: HTMLElement): DocumentFragment {
  let f = r.cloneContents();
  let n: Node | null = r.commonAncestorContainer;
  if (n.nodeType !== Node.ELEMENT_NODE) n = n.parentNode;
  for (; n && n !== block; n = n.parentNode) {
    const wrap = (n as Element).cloneNode(false);
    wrap.appendChild(f);
    f = document.createDocumentFragment();
    f.appendChild(wrap);
  }
  return f;
}

function textOf(f: DocumentFragment): string {
  return (f.textContent || '').replace(/\s+/g, '');
}

/** Narration that only says who's speaking, short enough for the line above the bubble. */
function isTag(text: string): boolean {
  return text.length > 0 && text.length <= 14 && /[：:，,]$/.test(text) && !/[。！？.!?]/.test(text);
}

/** Bold the speaker's name where the narration writes it. */
function boldName(f: DocumentFragment, who: string): boolean {
  const w = document.createTreeWalker(f, NodeFilter.SHOW_TEXT, null);
  for (let t = w.nextNode() as Text | null; t; t = w.nextNode() as Text | null) {
    const i = t.data.indexOf(who);
    if (i < 0) continue;
    const r = document.createRange();
    r.setStart(t, i);
    r.setEnd(t, i + who.length);
    r.surroundContents(document.createElement('b'));
    return true;
  }
  return false;
}

function el(tag: string, cls: string): HTMLElement {
  const e = document.createElement(tag);
  e.className = cls;
  return e;
}

function bubble(l: BubbleLine, quote: DocumentFragment, tag: DocumentFragment | null, cont: boolean): HTMLElement {
  const q = el('div', 'yy-bq' + (l.right ? ' yy-bq-r' : '') + (l.who ? '' : ' yy-bq-unk') + (cont ? ' yy-bq-cont' : ''));
  q.style.setProperty('--yy-c', l.color);
  const av = el('span', 'yy-bq-av');
  av.setAttribute('aria-hidden', 'true');
  av.textContent = l.who ? l.avatar : '?';
  const bx = el('div', 'yy-bq-bx');
  if (!cont || tag) {
    const nm = el('div', 'yy-bq-nm');
    if (tag) {
      if (!(l.who && boldName(tag, l.who)) && l.who) {
        const b = el('b', 'yy-bq-who');
        b.textContent = l.who;
        nm.appendChild(b);
      }
      nm.appendChild(tag);
    } else {
      const b = el('b', 'yy-bq-who');
      b.textContent = l.who || '谁说的？';
      nm.appendChild(b);
    }
    bx.appendChild(nm);
  }
  const bu = el('div', 'yy-bq-bu');
  bu.appendChild(quote);
  bx.appendChild(bu);
  q.appendChild(av);
  q.appendChild(bx);
  return q;
}

function rebuild(block: HTMLElement, lines: BubbleLine[]): void {
  const out: HTMLElement[] = [];
  const cursor = document.createRange();
  cursor.setStart(block, 0);
  let lastWho: string | null | undefined;
  const narration = (f: DocumentFragment) => {
    if (!textOf(f)) return;
    const p = block.cloneNode(false) as HTMLElement;
    p.removeAttribute('id');
    p.classList.add('yy-bn');
    p.appendChild(f);
    out.push(p);
    lastWho = undefined;
  };
  for (const l of lines) {
    const q = quoteRange(l);
    if (!q) continue;
    const before = document.createRange();
    before.setStart(cursor.startContainer, cursor.startOffset);
    before.setEnd(q.a.node, q.a.offset);
    const pre = cut(before, block);
    const preText = textOf(pre);
    let tag: DocumentFragment | null = null;
    if (preText && l.who && isTag(preText)) tag = pre;
    else narration(pre);
    const qr = document.createRange();
    qr.setStart(q.a.node, q.a.offset);
    qr.setEnd(q.b.node, q.b.offset);
    const cont = !tag && lastWho !== undefined && lastWho === l.who && !!l.who;
    out.push(bubble(l, cut(qr, block), tag, cont));
    lastWho = l.who;
    cursor.setStart(q.b.node, q.b.offset);
  }
  const after = document.createRange();
  after.setStart(cursor.startContainer, cursor.startOffset);
  after.setEnd(block, block.childNodes.length);
  narration(cut(after, block));
  if (!out.length) return;
  if (block.id) out[0].id = block.id;
  block.replaceWith(...out);
}

/** Lays the section out as bubbles for `lines`, or (null) puts it back as it came. Returns
 *  whether anything changed. */
export function setBubbles(lines: BubbleLine[] | null): boolean {
  const root = content();
  if (original != null) {
    root.innerHTML = original;
    original = null;
    document.documentElement.removeAttribute('data-yy-bubbles');
    if (!lines) return true;
  }
  if (!lines || !lines.length) return false;
  original = root.innerHTML;
  document.documentElement.setAttribute('data-yy-bubbles', '1');
  // Lines by the paragraph they're in; a quote running out of its paragraph stays as text.
  const byBlock = new Map<HTMLElement, BubbleLine[]>();
  for (const l of lines.slice().sort((x, y) => x.first - y.first || x.start - y.start)) {
    const q = quoteRange(l);
    if (!q) continue;
    const b = blockOf(q.a.node);
    if (!b || b !== blockOf(q.b.node)) continue;
    if (!byBlock.has(b)) byBlock.set(b, []);
    byBlock.get(b)!.push(l);
  }
  // Every range is worked out before any paragraph is replaced: replacing one leaves the
  // others' text nodes where they were.
  byBlock.forEach((ls, b) => rebuild(b, ls));
  return true;
}
