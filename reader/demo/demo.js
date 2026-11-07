// Reader demo: plays the native side. Loads a section into a same-origin iframe the size of a
// device, calls window.yy in it and listens to the messages the reader forwards to its parent
// ({yy: msg} via postMessage, the fallback when there is no native bridge).
// State lives in the query string, so a reload keeps the book, page settings and device.
(function () {
  'use strict';

  const PRESETS = {
    iphone: { w: 393, h: 852, cols: 1, radius: 55, bezel: 12 },
    ipad: { w: 1180, h: 820, cols: 2, radius: 22, bezel: 16 },
    mac: { w: 1280, h: 800, cols: 2, radius: 10, bezel: 0 },
  };
  // Settings sent with applySettings, and baked into the document URL on load (as core does).
  const KEYS = ['paper', 'fontSize', 'font', 'mode', 'paging', 'cols', 'compress', 'motion'];
  const QUERY = { paper: 'paper', fontSize: 'fs', font: 'font', mode: 'mode', paging: 'paging', cols: 'cols', compress: 'compress', motion: 'motion' };

  const $ = (id) => document.getElementById(id);
  const frame = $('frame');
  const device = $('device');
  const fit = $('fit');
  const stage = $('stage');

  const q = new URLSearchParams(location.search);
  const state = {
    book: q.get('book') || '',
    s: q.has('s') ? parseInt(q.get('s'), 10) : -1,
    preset: PRESETS[q.get('preset')] ? q.get('preset') : 'iphone',
    paper: q.get('paper') || 'plain',
    fontSize: parseInt(q.get('fs') || '18', 10),
    font: q.get('font') || '',
    mode: q.get('mode') || 'paginated',
    paging: q.get('paging') || 'snap',
    cols: q.get('cols') || '',
    compress: q.get('compress') || '1',
    motion: q.get('motion') || 'full',
    speed: q.get('speed') || '1',
  };
  if (!state.cols) state.cols = String(PRESETS[state.preset].cols);

  let books = []; // [{book, sections: [{n, title}]}]
  let geom = null; // last ready/layout message
  let pending = null; // what to do when the next section is ready: {page|anchor|play}
  let navStart = 0;
  const player = { playing: false, s: null, timer: 0 };

  const yy = () => (frame.contentWindow && frame.contentWindow.yy) || null;

  // ---------- message log ----------

  const logEl = $('log');
  function show(text, cls) {
    const d = document.createElement('div');
    d.textContent = text;
    if (cls) d.className = cls;
    logEl.insertBefore(d, logEl.firstChild);
    while (logEl.childNodes.length > 200) logEl.removeChild(logEl.lastChild);
  }
  function describe(m) {
    const parts = [m.type];
    for (const k in m) {
      if (k === 'type') continue;
      const v = m[k];
      if (Array.isArray(v)) parts.push(k + '[' + v.length + ']');
      else if (v && typeof v === 'object') parts.push(k + '=' + JSON.stringify(v));
      else parts.push(k + '=' + v);
    }
    return parts.join(' ');
  }

  // ---------- settings ----------

  function persist() {
    const p = new URLSearchParams();
    p.set('book', state.book);
    p.set('s', String(state.s));
    p.set('preset', state.preset);
    for (const k of KEYS) if (state[k] !== '') p.set(QUERY[k], String(state[k]));
    if (state.speed !== '1') p.set('speed', state.speed);
    history.replaceState(null, '', '?' + p.toString());
  }

  function settingsFor(keys) {
    const out = {};
    for (const k of keys) {
      const v = state[k];
      if (k === 'fontSize' || k === 'cols') out[k] = Number(v);
      else if (k === 'compress') out[k] = v === '1';
      else if (k === 'font') out[k] = v || null;
      else out[k] = v;
    }
    return out;
  }

  function set(changes) {
    Object.assign(state, changes);
    syncControls();
    persist();
    const keys = Object.keys(changes).filter((k) => KEYS.indexOf(k) >= 0);
    const r = yy();
    if (r && keys.length) {
      const t0 = performance.now();
      r.applySettings(settingsFor(keys));
      show('applySettings ' + JSON.stringify(settingsFor(keys)) + ' ' + Math.round(performance.now() - t0) + 'ms');
    }
  }

  function syncControls() {
    document.querySelectorAll('[data-key]').forEach((g) => {
      const v = String(state[g.getAttribute('data-key')]);
      g.querySelectorAll('button').forEach((b) => b.setAttribute('aria-pressed', String(b.getAttribute('data-v') === v)));
    });
    $('fontSize').value = String(state.fontSize);
    $('fontSizeOut').textContent = state.fontSize + 'px';
    $('font').value = state.font;
    $('speed').value = state.speed;
  }

  // ---------- device frame ----------

  function layoutDevice() {
    const p = PRESETS[state.preset];
    const bar = state.preset === 'mac' ? 28 : 0;
    frame.style.width = p.w + 'px';
    frame.style.height = p.h + 'px';
    frame.style.borderRadius = p.bezel ? p.radius - p.bezel + 'px' : '0 0 ' + p.radius + 'px ' + p.radius + 'px';
    device.setAttribute('data-preset', state.preset);
    device.style.padding = p.bezel + 'px';
    device.style.borderRadius = p.radius + 'px';
    device.style.overflow = 'hidden';
    const W = p.w + 2 * p.bezel;
    const H = p.h + 2 * p.bezel + bar;
    const cs = getComputedStyle(stage);
    const aw = stage.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
    const ah = stage.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom);
    const k = Math.min(1, aw / W, ah / H);
    device.style.width = W + 'px';
    device.style.height = H + 'px';
    device.style.transform = 'scale(' + k + ')';
    fit.style.width = W * k + 'px';
    fit.style.height = H * k + 'px';
  }

  // ---------- sections ----------

  function flat() {
    const out = [];
    for (const b of books) for (const s of b.sections) out.push({ book: b.book, n: s.n, title: s.title });
    return out;
  }
  function position() {
    const list = flat();
    for (let i = 0; i < list.length; i++) if (list[i].book === state.book && list[i].n === state.s) return { list, i };
    return { list, i: -1 };
  }

  function load(book, n, then) {
    stop();
    state.book = book;
    state.s = n;
    pending = then || null;
    geom = null;
    persist();
    $('section').value = book + '/' + n;
    const p = new URLSearchParams();
    for (const k of KEYS) if (state[k] !== '') p.set(QUERY[k], String(state[k]));
    navStart = performance.now();
    frame.src = '/book/' + encodeURIComponent(book) + '/s/' + n + '.html?' + p.toString();
    updatePageInfo();
  }

  /** Neighbouring section in the same book, or null. */
  function neighbour(step) {
    const { list, i } = position();
    const t = list[i + step];
    return i >= 0 && t && t.book === state.book ? t : null;
  }

  // ---------- navigation ----------

  function next() {
    const r = yy();
    if (!r) return;
    if (r.nextPage(true)) return;
    const t = neighbour(1);
    if (t) load(t.book, t.n, { page: 0 });
    else show('end of book');
  }
  function prev() {
    const r = yy();
    if (!r) return;
    if (r.prevPage(true)) return;
    const t = neighbour(-1);
    if (t) load(t.book, t.n, { page: 'last' });
    else show('start of book');
  }

  function updatePageInfo() {
    const r = yy();
    if (!r || !geom) {
      $('pageinfo').textContent = '–';
      return;
    }
    $('pageinfo').textContent = r.currentPage() + 1 + ' / ' + geom.pageCount;
  }

  function follow(target) {
    // "3#note-1" or "3"
    const i = target.indexOf('#');
    const n = parseInt(i < 0 ? target : target.slice(0, i), 10);
    const anchor = i < 0 ? '' : target.slice(i + 1);
    if (n === state.s) {
      if (anchor) yy().scrollToAnchor(anchor, true);
      return;
    }
    const b = books.find((x) => x.book === state.book);
    if (!b || !b.sections.some((s) => s.n === n)) {
      show('link to section ' + n + ' (not in this export)', 'warn');
      return;
    }
    load(state.book, n, anchor ? { anchor } : { page: 0 });
  }

  // ---------- playback ----------
  // The demo is the audio clock: each sentence "plays" for 120ms per spoken character (at least
  // 1.8s), the reader's own default, divided by the speed.

  function sentenceCount() {
    return geom ? geom.sentencePages.length : 0;
  }

  function durationOf(s) {
    let n = 0;
    frame.contentDocument.querySelectorAll('.s[data-s="' + s + '"]').forEach((el) => {
      const c = el.cloneNode(true);
      c.querySelectorAll('rt, rp, .yy-noteref').forEach((x) => x.remove());
      n += c.textContent.replace(/\s+/g, ' ').length;
    });
    return Math.max(1800, n * 120) / Number(state.speed);
  }

  function firstSentenceInView() {
    const r = yy();
    if (!geom || !r) return 0;
    if (state.mode === 'scrolled') {
      // The first sentence whose box is below the top inset.
      const els = frame.contentDocument.querySelectorAll('.s');
      for (let i = 0; i < els.length; i++) {
        const b = els[i].getBoundingClientRect();
        if (b.height && b.bottom > 0) return parseInt(els[i].getAttribute('data-s'), 10);
      }
      return 0;
    }
    for (let p = r.currentPage(); p < geom.pageCount; p++) if (geom.pageFirstSentence[p] >= 0) return geom.pageFirstSentence[p];
    return 0;
  }

  function playFrom(s) {
    const r = yy();
    if (!r) return;
    clearTimeout(player.timer);
    if (s >= sentenceCount()) {
      const t = neighbour(1);
      if (t && player.playing) load(t.book, t.n, { play: 0 });
      else stop();
      return;
    }
    const dur = durationOf(s);
    player.playing = true;
    player.s = s;
    r.setActive(s, { durationMs: dur, elapsedMs: 0, playing: true });
    player.timer = setTimeout(() => playFrom(s + 1), dur);
    $('play').textContent = 'Pause';
  }

  function pause() {
    const r = yy();
    clearTimeout(player.timer);
    player.playing = false;
    if (r) r.setPlaying(false);
    $('play').textContent = 'Play';
  }

  function resume() {
    const r = yy();
    if (!r) return;
    const ink = r.ink();
    if (player.s == null || ink.sentence !== player.s) {
      playFrom(firstSentenceInView());
      return;
    }
    player.playing = true;
    r.setPlaying(true);
    // The reader keeps its own clock; finish the sentence on it.
    player.timer = setTimeout(() => playFrom(player.s + 1), Math.max(0, ink.duration - ink.elapsed));
    $('play').textContent = 'Pause';
  }

  function stop() {
    clearTimeout(player.timer);
    player.playing = false;
    player.s = null;
    const r = yy();
    if (r) r.setActive(null);
    $('play').textContent = 'Play';
  }

  function onActivePage(m) {
    const r = yy();
    if (!r || !player.playing || !$('follow').checked) return;
    if (state.mode === 'paginated') {
      if (m.page !== r.currentPage()) r.scrollToPage(m.page, true);
      return;
    }
    // Scrolled: bring the sentence up when it starts below the top two thirds.
    const el = frame.contentDocument.querySelector('.s[data-s="' + m.sentence + '"]');
    if (!el) return;
    const b = el.getBoundingClientRect();
    const h = frame.contentWindow.innerHeight;
    if (b.top < 0 || b.top > h * 0.66) r.scrollToSentence(m.sentence, true);
  }

  // ---------- messages from the reader ----------

  window.addEventListener('message', (e) => {
    if (e.source !== frame.contentWindow || !e.data || !e.data.yy) return;
    const m = e.data.yy;
    const r = yy();
    if (m.type === 'ready') {
      show(describe(m) + '  ' + Math.round(performance.now() - navStart) + 'ms', 'ready');
      $('version').textContent = r ? 'v' + r.version : '';
    } else if (m.type === 'log') {
      show('log ' + m.level + ': ' + m.message, m.level);
    } else {
      show(describe(m));
    }
    switch (m.type) {
      case 'ready':
        geom = m;
        if (pending && pending.page === 'last') r.scrollToPage(m.pageCount - 1, false);
        else if (pending && pending.anchor) r.scrollToAnchor(pending.anchor, false);
        if (pending && pending.play != null) {
          if (sentenceCount()) {
            player.playing = true;
            playFrom(pending.play);
          } else stop();
        }
        pending = null;
        break;
      case 'layout':
        geom = m;
        break;
      case 'activePage':
        onActivePage(m);
        break;
      case 'tap':
        onTap(m);
        break;
    }
    updatePageInfo();
  });

  // Left third = previous page, right third = next page, middle = menu. The demo has
  // no menu, so a tap on a sentence in the middle starts playback there.
  function onTap(m) {
    const r = yy();
    if (!r) return;
    if (m.link) {
      if (m.link.target != null) follow(m.link.target);
      else show('external link: ' + m.link.external);
      return;
    }
    if (state.mode === 'paginated') {
      if (m.x < m.width / 3) return prev();
      if (m.x > (m.width * 2) / 3) return next();
    }
    if (m.sentence != null) {
      player.playing = true;
      playFrom(m.sentence);
    }
  }

  // ---------- controls ----------

  document.querySelectorAll('[data-key]').forEach((g) => {
    const key = g.getAttribute('data-key');
    g.addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b) return;
      const v = b.getAttribute('data-v');
      if (key === 'preset') {
        state.preset = v;
        layoutDevice();
        // The iframe has its new size on the next frame; then the column count follows the device.
        requestAnimationFrame(() => set({ cols: String(PRESETS[v].cols) }));
        return;
      }
      set({ [key]: v });
    });
  });
  $('fontSize').addEventListener('input', (e) => set({ fontSize: parseInt(e.target.value, 10) }));
  $('font').addEventListener('change', (e) => set({ font: e.target.value }));
  $('speed').addEventListener('change', (e) => {
    state.speed = e.target.value;
    persist();
  });
  $('section').addEventListener('change', (e) => {
    const [book, n] = e.target.value.split('/');
    load(book, parseInt(n, 10), { page: 0 });
  });
  $('prev').addEventListener('click', prev);
  $('next').addEventListener('click', next);
  $('play').addEventListener('click', () => (player.playing ? pause() : resume()));

  function onKey(e) {
    if (e.target && /^(INPUT|SELECT|TEXTAREA)$/.test(e.target.nodeName) && e.key !== ' ') return;
    if (e.key === 'ArrowRight' || e.key === 'PageDown') next();
    else if (e.key === 'ArrowLeft' || e.key === 'PageUp') prev();
    else if (e.key === ' ') player.playing ? pause() : resume();
    else return;
    e.preventDefault();
  }
  document.addEventListener('keydown', onKey);

  frame.addEventListener('load', () => {
    const w = frame.contentWindow;
    w.addEventListener('keydown', onKey);
    let raf = 0;
    w.addEventListener('scroll', () => {
      if (!raf) raf = requestAnimationFrame(() => ((raf = 0), updatePageInfo()));
    }, { passive: true });
  });

  window.addEventListener('resize', layoutDevice);

  // ---------- start ----------

  syncControls();
  layoutDevice();
  fetch('/api/sections')
    .then((r) => r.json())
    .then((list) => {
      books = list;
      const sel = $('section');
      for (const b of books) {
        const g = document.createElement('optgroup');
        g.label = b.book;
        for (const s of b.sections) {
          const o = document.createElement('option');
          o.value = b.book + '/' + s.n;
          o.textContent = s.n + (s.title ? ' · ' + s.title : '');
          g.appendChild(o);
        }
        sel.appendChild(g);
      }
      const all = flat();
      let start = all.find((x) => x.book === state.book && x.n === state.s);
      if (!start) start = all.find((x) => x.book === 'beiying') || all[0];
      if (start) load(start.book, start.n, { page: 0 });
      else show('no books found', 'error');
    });
})();
