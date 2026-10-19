// Decides which publisher styles the reader's settings override (contract §2: font, size, line
// height, paragraph spacing, indent, justify, paper colours).
//
// Blanket `p { … !important }` rules would flatten centred lines, poems, notes and signatures.
// Instead, with the reader's own font overrides switched off (html[data-yy-raw]), every block that
// directly holds text is compared with the section's dominant body style (weighted by text length).
// Where a block matches the dominant value the reader's setting applies (a yy-* class, see
// reader.css); where it deviates, the publisher's value is deliberate and stays. Sizes always scale:
// a block at 0.85x the body size becomes 0.85x the reader's size (--yy-fr).

const INLINE = /^(SPAN|A|EM|I|B|STRONG|RUBY|RB|RT|RP|RTC|SUP|SUB|SMALL|BIG|CODE|KBD|SAMP|VAR|MARK|Q|CITE|ABBR|ACRONYM|DFN|TIME|U|S|STRIKE|DEL|INS|FONT|BDI|BDO|WBR|BR|IMG|SVG|MATH|LABEL|TT|NOBR)$/;
const HEADING = /^H[1-6]$/;
const PARA = /^(P|DIV)$/;

interface Block {
  el: HTMLElement;
  tag: string;
  len: number;
  size: number;
  family: string;
  indent: number; // em
  mt: number; // em
  mb: number; // em
  align: 'start' | 'justify' | 'center' | 'end';
  ls: number; // em
  color: string;
}

function hasDirectText(el: Element): number {
  let n = 0;
  for (let c = el.firstChild; c; c = c.nextSibling) {
    if (c.nodeType === 3) n += (c as Text).data.replace(/\s+/g, '').length;
    else if (c.nodeType === 1 && INLINE.test(c.nodeName.toUpperCase())) {
      n += ((c as Element).textContent || '').replace(/\s+/g, '').length;
    }
  }
  return n;
}

const OWN_CLASS = /(^|\s)(s|pz-[rl]|hl|wave|yy-[\w-]+)(?=\s|$)/g;

/** Inline elements whose size the publisher may have changed: big/font, a style attribute, or a
 *  class that is not one of core's or the reader's. Sentence spans are skipped (thousands). */
function isStyledInline(el: HTMLElement, tag: string): boolean {
  if (tag === 'BIG' || tag === 'FONT' || el.hasAttribute('style')) return true;
  const c = el.getAttribute('class');
  return !!c && !!c.replace(OWN_CLASS, ' ').trim();
}

function alignOf(v: string, rtl: boolean): Block['align'] {
  switch (v) {
    case 'justify':
      return 'justify';
    case 'center':
    case '-webkit-center':
      return 'center';
    case 'right':
    case '-webkit-right':
      return rtl ? 'start' : 'end';
    case 'end':
      return 'end';
    case 'left':
    case '-webkit-left':
      return rtl ? 'end' : 'start';
    default:
      return 'start'; // start, auto, -webkit-auto, match-parent
  }
}

const px = (v: string): number => {
  const n = parseFloat(v);
  return isFinite(n) ? n : 0;
};

const round = (n: number): number => Math.round(n * 20) / 20; // 0.05em buckets

function modal<T>(blocks: Block[], key: (b: Block) => T): T | undefined {
  const w = new Map<string, { v: T; n: number }>();
  for (const b of blocks) {
    const v = key(b);
    const k = String(v);
    const e = w.get(k);
    if (e) e.n += b.len;
    else w.set(k, { v, n: b.len });
  }
  let best: { v: T; n: number } | undefined;
  w.forEach((e) => {
    if (!best || e.n > best.n) best = e;
  });
  return best && best.v;
}

export function classify(content: HTMLElement): void {
  const root = document.documentElement;
  root.setAttribute('data-yy-raw', '');
  const blocks: Block[] = [];
  const styled: HTMLElement[] = [];
  const all = content.getElementsByTagName('*');
  for (let i = 0; i < all.length; i++) {
    const el = all[i] as HTMLElement;
    const tag = el.nodeName.toUpperCase();
    if (INLINE.test(tag)) {
      if (isStyledInline(el, tag)) styled.push(el);
      continue;
    }
    if (tag === 'YY-PAGES' || el.classList.contains('yy-meta')) continue;
    if (el.closest('.yy-meta, .yy-footnote')) continue;
    const len = hasDirectText(el);
    if (!len) continue;
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.display.indexOf('inline') === 0) continue;
    const size = px(cs.fontSize) || 16;
    blocks.push({
      el,
      tag,
      len,
      size,
      family: cs.fontFamily,
      indent: round(px(cs.textIndent) / size),
      mt: round(px(cs.marginTop) / size),
      mb: round(px(cs.marginBottom) / size),
      align: alignOf(cs.textAlign, cs.direction === 'rtl'),
      ls: round((cs.letterSpacing === 'normal' ? 0 : px(cs.letterSpacing)) / size),
      color: cs.color,
    });
  }
  // Raised initials and other inline runs set much larger than their paragraph (Gutenberg's
  // `.letra { font-size: 250% }`) inherit the paragraph's tall unitless line height and would push
  // their line far down; they get line-height 1 (.yy-lh1).
  const blockOf = new Map<Element, Block>();
  for (const b of blocks) blockOf.set(b.el, b);
  for (const el of styled) {
    let p = el.parentElement;
    while (p && p !== content && !blockOf.has(p)) p = p.parentElement;
    const b = p && blockOf.get(p);
    if (!b) continue;
    const cs = getComputedStyle(el);
    if (px(cs.fontSize) > b.size * 1.3 && cs.cssFloat === 'none' && cs.display.indexOf('inline') === 0) {
      el.classList.add('yy-lh1');
    }
  }
  root.removeAttribute('data-yy-raw');
  if (!blocks.length) return;

  // Dominant body style: paragraphs that are not headings, preformatted or table cells.
  let body = blocks.filter((b) => PARA.test(b.tag));
  const bodyLen = body.reduce((n, b) => n + b.len, 0);
  const allLen = blocks.reduce((n, b) => n + b.len, 0);
  if (bodyLen < allLen * 0.2) body = blocks.filter((b) => !HEADING.test(b.tag) && b.tag !== 'PRE');
  if (!body.length) body = blocks;
  const flow = body.filter((b) => b.align === 'start' || b.align === 'justify');
  const ref = flow.length ? flow : body;

  const mSize = modal(body, (b) => Math.round(b.size * 2) / 2) || 16;
  const mFamily = modal(body, (b) => b.family);
  const mIndent = modal(ref, (b) => b.indent);
  const mMargins = modal(ref, (b) => b.mt + '/' + b.mb);
  const mLs = modal(body, (b) => b.ls);
  const mColor = modal(body, (b) => b.color);

  const title = findTitle(content, blocks);

  for (const b of blocks) {
    const c = b.el.classList;
    if (b.el === title) {
      c.add('yy-t');
      hideLeadingBreaks(b.el);
      if (b.align === 'center' || b.align === 'end') c.add('yy-a');
      const next = b.el.nextElementSibling;
      if (next && next.classList.contains('yy-meta')) {
        c.add('yy-t-m');
        if (c.contains('yy-a')) next.classList.add('yy-a');
      }
      continue;
    }
    const ratio = b.size / mSize;
    const heading = HEADING.test(b.tag) || c.contains('yy-title');
    if (heading) {
      c.add('yy-h');
      b.el.style.setProperty('--yy-fr', String(Math.round(ratio * 1000) / 1000));
    } else if (Math.abs(ratio - 1) < 0.03) {
      c.add('yy-b');
    } else {
      c.add('yy-r');
      b.el.style.setProperty('--yy-fr', String(Math.round(ratio * 1000) / 1000));
    }
    if (b.family === mFamily && b.tag !== 'PRE') c.add('yy-f');
    if (b.color === mColor) c.add('yy-c');
    if (heading) continue;
    if (b.ls === mLs) c.add('yy-l');
    const flowing = b.align === 'start' || b.align === 'justify';
    if (!flowing) continue;
    if (/^(P|DIV|LI|DD|BLOCKQUOTE)$/.test(b.tag)) c.add('yy-j');
    if (PARA.test(b.tag)) {
      if (b.indent === mIndent) c.add('yy-i');
      if (b.mt + '/' + b.mb === mMargins) c.add('yy-m');
    }
  }
  decorateMeta(content);
}

/** The section title: the heading the meta line follows, else a heading that opens the section. */
function findTitle(content: HTMLElement, blocks: Block[]): HTMLElement | null {
  const meta = content.querySelector('.yy-meta');
  if (meta) {
    const prev = meta.previousElementSibling as HTMLElement | null;
    if (prev) {
      for (const b of blocks) if (b.el === prev || prev.contains(b.el)) return b.el;
    }
  }
  const first = blocks[0];
  if (first && (HEADING.test(first.tag) || first.el.classList.contains('yy-title'))) return first.el;
  return null;
}

/** Line breaks before the first words of a title (left behind where an EPUB had a heading
 *  picture above the text) would push the title down by empty lines. */
function hideLeadingBreaks(el: HTMLElement): void {
  for (let n = el.firstChild; n; n = n.nextSibling) {
    if (n.nodeType === 3) {
      if (/\S/.test((n as Text).data)) return;
      continue;
    }
    if (n.nodeType !== 1) continue;
    const e = n as HTMLElement;
    if (e.nodeName === 'BR') e.classList.add('yy-hide');
    else if ((e.textContent || '').trim() || e.querySelector('img,svg,video')) return;
  }
}

/** "朱自清 · 读 8 分钟 · 听 12 分钟" -> spans with reading/listening icons (prototype .r-meta). */
function decorateMeta(content: HTMLElement): void {
  const metas = content.querySelectorAll('.yy-meta');
  for (let i = 0; i < metas.length; i++) {
    const m = metas[i] as HTMLElement;
    const kind = (t: string): string | null =>
      /^(读|讀|read)/i.test(t) ? 'yy-rd' : /^(听|聽|listen)/i.test(t) ? 'yy-ls' : null;
    if (m.children.length) {
      for (let k = 0; k < m.children.length; k++) {
        const ch = m.children[k];
        const cls = kind((ch.textContent || '').trim());
        if (cls) ch.classList.add(cls);
      }
      continue;
    }
    const parts = (m.textContent || '').split(/\s*[·・•]\s*/).filter((p) => p.trim());
    if (parts.length < 1) continue;
    m.textContent = '';
    parts.forEach((p, k) => {
      if (k) {
        const dot = document.createElement('span');
        dot.textContent = '·';
        m.appendChild(dot);
      }
      const span = document.createElement('span');
      span.textContent = p.trim();
      const cls = kind(p.trim());
      if (cls) span.className = cls;
      m.appendChild(span);
    });
  }
}
