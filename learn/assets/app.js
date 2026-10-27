/* K8s Learn Lab — a dependency-light reader for learn/docs/*.md.
 *
 * Lessons stay plain GitHub Markdown. This file adds what GitHub cannot:
 * checkable tasks with saved progress, callouts, a repo file viewer, search,
 * per-module notes. Progress lives in this browser's localStorage only —
 * export it from the dashboard if you switch machines.
 */
(() => {
  'use strict';

  const APP_BASE = location.pathname.replace(/[^/]*$/, '');      // "/learn/"
  // Served by learn/serve.py from the repo root, every file in the repo is
  // reachable and opens in the viewer. Published on its own (a claude.ai
  // Artifact), only learn/ is there, next to the page; the rest opens on GitHub.
  const LOCAL_REPO = /\/learn\/$/.test(APP_BASE);
  const REPO_BASE = LOCAL_REPO ? APP_BASE.replace(/learn\/$/, '') : null;
  const GITHUB = 'https://github.com/meroxdotdev/infrastructure/';
  const KEYS = { progress: 'learn.progress.v1', notes: 'learn.notes.v1', theme: 'learn.theme', last: 'learn.last' };

  // Where a repo-relative path can be fetched from this page, or null.
  function fileUrl(path) {
    if (LOCAL_REPO) return REPO_BASE + path;
    if (path.startsWith('learn/')) return APP_BASE + path.slice('learn/'.length);
    return null;
  }

  function githubUrl(path) {
    return `${GITHUB}${path.endsWith('/') ? 'tree' : 'blob'}/main/${path.replace(/\/$/, '')}`;
  }

  const store = {
    get(key, fallback) {
      try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; } catch { return fallback; }
    },
    set(key, value) {
      try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* private mode: progress is session-only */ }
    },
  };

  const state = {
    curriculum: null,
    docs: {},          // id -> markdown
    tasks: {},         // id -> [{id, text}]
    index: [],         // search sections
    byFile: {},        // "learn/docs/x.md" -> id
    progress: store.get(KEYS.progress, {}),
    notes: store.get(KEYS.notes, {}),
    sync: 'local',     // 'local' | 'account': whether progress also lives in the viewer's account
  };

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // ---------- text helpers ----------

  function fnv(str) {
    let h = 0x811c9dc5;
    for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 0x01000193); }
    return (h >>> 0).toString(36);
  }

  // One output char per input char, so match positions map back onto the original.
  function fold(s) {
    return Array.from(s).map((c) => Array.from(c.normalize('NFD'))[0] || c).join('').toLowerCase();
  }

  function stripInline(s) {
    return s
      .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
      .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
      .replace(/<[^>]+>/g, '')
      .replace(/[`*_~]/g, '')
      .trim();
  }

  function slugify(text) {
    return fold(text).replace(/[^a-z0-9\s-]/g, '').trim().replace(/\s+/g, '-').replace(/-+/g, '-') || 'sec';
  }

  // Walks markdown lines outside fenced code, calling fn(line).
  function eachProseLine(md, fn) {
    let fence = null;
    for (const line of md.split(/\r?\n/)) {
      const m = line.match(/^\s*(`{3,}|~{3,})/);
      if (m) {
        if (!fence) fence = m[1][0];
        else if (m[1][0] === fence) fence = null;
        fn(line, true);
        continue;
      }
      fn(line, !!fence);
    }
  }

  function parseTasks(moduleId, md) {
    const seen = {};
    const out = [];
    eachProseLine(md, (line, inCode) => {
      if (inCode) return;
      const m = line.match(/^\s*[-*+] \[( |x|X)\] (.+)$/);
      if (!m) return;
      const text = stripInline(m[2]).replace(/\s+/g, ' ');
      let id = `${moduleId}:${fnv(text)}`;
      seen[id] = (seen[id] || 0) + 1;
      if (seen[id] > 1) id += `-${seen[id]}`;
      out.push({ id, text });
    });
    return out;
  }

  function buildIndex(id, title, md) {
    const sections = [];
    const slugs = {};
    let cur = { id, title, heading: title, anchor: '', text: [] };
    eachProseLine(md, (line, inCode) => {
      const h = !inCode && line.match(/^(#{1,4})\s+(.+?)\s*#*$/);
      if (h) {
        sections.push(cur);
        const text = stripInline(h[2]);
        let slug = slugify(text);
        slugs[slug] = (slugs[slug] || 0) + 1;
        if (slugs[slug] > 1) slug += `-${slugs[slug]}`;
        cur = { id, title, heading: text, anchor: h[1].length === 1 ? '' : slug, text: [] };
      } else {
        cur.text.push(inCode ? line : stripInline(line.replace(/^>\s?(\[!\w+\])?/, '').replace(/^\s*[-*+] (\[.\] )?/, '')));
      }
    });
    sections.push(cur);
    for (const s of sections) {
      s.body = s.text.join(' ').replace(/\s+/g, ' ').trim();
      s.folded = fold(`${s.heading} ${s.body}`);
      delete s.text;
    }
    return sections.filter((s) => s.body || s.anchor);
  }

  // ---------- progress ----------

  function stats(id) {
    const list = state.tasks[id] || [];
    const done = list.filter((t) => state.progress[t.id]).length;
    return { done, total: list.length, pct: list.length ? Math.round((done / list.length) * 100) : 0 };
  }

  function overall() {
    let done = 0, total = 0;
    for (const m of state.curriculum.modules) { const s = stats(m.id); done += s.done; total += s.total; }
    return { done, total, pct: total ? Math.round((done / total) * 100) : 0 };
  }

  function status(id) {
    const s = stats(id);
    if (!s.total || !s.done) return '';
    return s.done === s.total ? 'done' : 'partial';
  }

  function saveProgress() { store.set(KEYS.progress, state.progress); scheduleSync(); }

  // ---------- account sync (claude.ai Artifact only) ----------
  //
  // On claude.ai the page may hold a private per-viewer document in the
  // artifact's store, so ticks and notes follow the viewer across devices.
  // localStorage stays the first copy: the page works the same without it.

  const remote = { ref: null, timer: null, chain: Promise.resolve() };

  async function connectSync() {
    if (!window.claude || typeof window.claude.use !== 'function') return;
    try {
      const [db, user] = await Promise.all([window.claude.use('db'), window.claude.use('user')]);
      if (!db || !user) return;
      const id = await user.id();
      if (!id) return;
      const ref = db.collection(`data/users/${id}`).doc('progress');
      const snap = await ref.get();
      let changed = false;
      if (snap.exists) {
        const data = snap.data() || {};
        for (const [k, v] of Object.entries(data.progress || {})) {
          if (!state.progress[k]) { state.progress[k] = v; changed = true; }
        }
        for (const [k, v] of Object.entries(data.notes || {})) {
          if (v && v !== state.notes[k]) { state.notes[k] = v; changed = true; }
        }
        store.set(KEYS.progress, state.progress);
        store.set(KEYS.notes, state.notes);
      }
      remote.ref = ref;
      state.sync = 'account';
      scheduleSync();
      if (changed || !$('.notes textarea:focus')) route(true);
    } catch (err) {
      console.warn('progress sync unavailable', err);
    }
  }

  // One write at a time, after a pause: a burst of ticks is one write.
  function scheduleSync() {
    if (!remote.ref) return;
    clearTimeout(remote.timer);
    remote.timer = setTimeout(() => {
      const body = { progress: { ...state.progress }, notes: { ...state.notes }, updatedAt: new Date().toISOString() };
      remote.chain = remote.chain.then(() => remote.ref.set(body)).catch((err) => console.warn('progress sync failed', err));
    }, 1200);
  }

  // ---------- theme ----------

  function effectiveTheme() {
    const t = document.documentElement.dataset.theme;
    if (t) return t;
    return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  // Only ever sets the theme: when nothing was chosen here, a data-theme the
  // host already put on the page (claude.ai does) must stay.
  function applyTheme() {
    const saved = store.get(KEYS.theme, null);
    if (saved) document.documentElement.dataset.theme = saved;
  }

  // ---------- markdown rendering ----------

  const CALLOUTS = {
    NOTE: { cls: 'note', title: 'În producție (repo-ul tău)', icon: '🏠' },
    TIP: { cls: 'tip', title: 'Analogie', icon: '🧠' },
    IMPORTANT: { cls: 'important', title: 'De ce?', icon: '❓' },
    WARNING: { cls: 'warning', title: 'Capcană', icon: '⚠️' },
    CAUTION: { cls: 'caution', title: 'Atenție — distructiv', icon: '💥' },
  };

  function toHtml(md) {
    if (!window.marked) return `<pre>${esc(md)}</pre>`;
    const html = marked.parse(md, { gfm: true, breaks: false });
    return window.DOMPurify ? DOMPurify.sanitize(html, { ADD_ATTR: ['target'] }) : html;
  }

  function enhanceCallouts(root) {
    for (const bq of $$('blockquote', root)) {
      const first = bq.firstElementChild;
      if (!first || first.tagName !== 'P') continue;
      const m = first.innerHTML.match(/^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(<br>)?\s*/);
      if (!m) continue;
      const kind = CALLOUTS[m[1]];
      first.innerHTML = first.innerHTML.slice(m[0].length);
      let title = `${kind.icon} ${kind.title}`;
      const lead = first.firstChild;
      if (lead && lead.nodeType === 1 && lead.tagName === 'STRONG') {
        title = lead.textContent;
        lead.remove();
        first.innerHTML = first.innerHTML.replace(/^\s*(<br>)?\s*/, '');
      }
      if (!first.textContent.trim() && !first.querySelector('img,code')) first.remove();
      const box = document.createElement('div');
      box.className = `callout ${kind.cls}`;
      box.innerHTML = `<div class="callout-title">${esc(title)}</div>`;
      while (bq.firstChild) box.appendChild(bq.firstChild);
      bq.replaceWith(box);
    }
  }

  function enhanceHeadings(root) {
    const toc = [];
    const slugs = {};
    for (const h of $$('h1, h2, h3, h4', root)) {
      let slug = slugify(h.textContent);
      slugs[slug] = (slugs[slug] || 0) + 1;
      if (slugs[slug] > 1) slug += `-${slugs[slug]}`;
      h.id = slug;
      if (h.tagName === 'H2' || h.tagName === 'H3') {
        toc.push({ level: h.tagName === 'H2' ? 2 : 3, text: h.textContent, slug });
        const a = document.createElement('a');
        a.className = 'anchor'; a.textContent = '#'; a.dataset.anchor = slug; a.href = '#';
        h.appendChild(a);
      }
    }
    return toc;
  }

  function enhanceTasks(root, moduleId) {
    const boxes = $$('input[type="checkbox"]', root);
    const list = moduleId ? state.tasks[moduleId] || [] : [];
    boxes.forEach((box, i) => {
      const li = box.closest('li');
      if (li) li.classList.add('task');
      const task = list[i];
      if (!task) { box.disabled = true; return; }
      box.disabled = false;
      box.checked = !!state.progress[task.id];
      box.setAttribute('aria-label', task.text);
      if (li) { li.id = `t-${task.id.replace(/[^a-z0-9-]/gi, '-')}`; li.classList.toggle('done', box.checked); }
      box.addEventListener('change', () => {
        if (box.checked) state.progress[task.id] = Date.now();
        else delete state.progress[task.id];
        saveProgress();
        if (li) li.classList.toggle('done', box.checked);
        renderSidebar(moduleId);
        updateModuleProgress(moduleId);
      });
    });
  }

  function enhanceCode(root) {
    for (const code of $$('pre > code', root)) {
      const pre = code.parentElement;
      const lang = (code.className.match(/language-([\w-]+)/) || [])[1] || '';
      if (lang === 'mermaid') {
        // <pre class="mermaid">: mermaid.js renders it locally, and claude.ai
        // renders that same element natively when the page is an Artifact.
        const wrap = document.createElement('div');
        wrap.className = 'mermaid-wrap';
        const diagram = document.createElement('pre');
        diagram.className = 'mermaid';
        diagram.textContent = code.textContent;
        wrap.appendChild(diagram);
        pre.replaceWith(wrap);
        continue;
      }
      if (window.hljs) {
        const known = lang && hljs.getLanguage(lang);
        if (known) hljs.highlightElement(code);
        else if (!lang) code.classList.add('hljs');
        else { code.classList.add('hljs'); }
      }
      const tools = document.createElement('div');
      tools.className = 'code-tools';
      tools.innerHTML = `${lang ? `<span class="code-lang">${esc(lang)}</span>` : ''}<button class="copy-btn" type="button">copiază</button>`;
      tools.querySelector('button').addEventListener('click', (e) => {
        const btn = e.currentTarget;
        copyText(code.textContent, code).then((copied) => {
          btn.textContent = copied ? 'copiat' : 'selectat';
          btn.classList.add('ok');
          setTimeout(() => { btn.textContent = 'copiază'; btn.classList.remove('ok'); }, 1400);
        });
      });
      pre.appendChild(tools);
    }
  }

  // Clipboard, or — where the frame refuses it — select the text so Ctrl+C works.
  function copyText(text, el) {
    const select = () => {
      if (!el) return false;
      const range = document.createRange();
      range.selectNodeContents(el);
      const sel = getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      return false;
    };
    try {
      return navigator.clipboard.writeText(text).then(() => true, select);
    } catch {
      return Promise.resolve(select());
    }
  }

  function enhanceTables(root) {
    for (const t of $$('table', root)) {
      if (t.parentElement.classList.contains('table-wrap')) continue;
      const wrap = document.createElement('div');
      wrap.className = 'table-wrap';
      t.replaceWith(wrap);
      wrap.appendChild(t);
    }
  }

  function enhanceLinks(root, docPath, routeId) {
    for (const a of $$('a[href]', root)) {
      if (a.classList.contains('anchor')) {
        a.href = routeId ? `#/${routeId}/${a.dataset.anchor}` : `#${a.dataset.anchor}`;
        continue;
      }
      const href = a.getAttribute('href');
      if (/^(https?:|mailto:)/i.test(href)) { a.target = '_blank'; a.rel = 'noopener'; continue; }
      if (href.startsWith('#')) {
        if (routeId && !href.startsWith('#/')) a.href = `#/${routeId}/${href.slice(1)}`;
        continue;
      }
      let url;
      try { url = new URL(href, `http://repo/${docPath}`); } catch { continue; }
      const path = decodeURIComponent(url.pathname.replace(/^\//, ''));
      const anchor = url.hash ? url.hash.slice(1) : '';
      const target = state.byFile[path];
      if (target) {
        a.href = `#/${target}${anchor ? `/${anchor}` : ''}`;
        a.classList.add('mod-link');
        continue;
      }
      a.classList.add('repo-link');
      const src = fileUrl(path);
      const isDir = path.endsWith('/') || !/\.[\w]+$|Dockerfile$|Makefile$/.test(path);
      if (!src) { a.href = githubUrl(path); a.target = '_blank'; a.rel = 'noopener'; continue; }
      a.href = src;
      if (isDir) { a.target = '_blank'; a.rel = 'noopener'; continue; }
      a.addEventListener('click', (e) => {
        if (e.ctrlKey || e.metaKey || e.shiftKey) return;
        e.preventDefault();
        openFile(path);
      });
    }
  }

  async function runMermaid(root) {
    const nodes = $$('.mermaid', root);
    if (!nodes.length || !window.mermaid) return;
    try {
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: effectiveTheme() === 'dark' ? 'dark' : 'neutral', fontFamily: 'inherit' });
      await mermaid.run({ nodes });
    } catch (err) {
      console.warn('mermaid', err);
    }
  }

  function renderMarkdown(container, md, { docPath, moduleId = null, routeId = null }) {
    container.innerHTML = toHtml(md);
    enhanceCallouts(container);
    const toc = enhanceHeadings(container);
    enhanceTasks(container, moduleId);
    enhanceCode(container);
    enhanceTables(container);
    enhanceLinks(container, docPath, routeId);
    runMermaid(container);
    return toc;
  }

  // ---------- views ----------

  const main = () => $('#main');

  function renderSidebar(activeId) {
    const c = state.curriculum;
    const o = overall();
    let html = `<div class="side-overall"><div class="label"><span>Progres total</span><span>${o.done}/${o.total}</span></div><div class="bar"><span style="width:${o.pct}%"></span></div></div>`;
    for (const phase of c.phases) {
      html += `<div class="phase-title">${esc(phase.title)}</div>`;
      for (const m of c.modules.filter((x) => x.phase === phase.id)) {
        const s = stats(m.id);
        html += `<a class="side-link${m.id === activeId ? ' active' : ''}" href="#/m/${m.id}" title="${esc(m.title)}">
          <span class="num">${esc(m.id)}</span><span>${esc(m.short || m.title)}</span>
          <span class="dot ${status(m.id)}" title="${s.done}/${s.total}"></span></a>`;
      }
    }
    html += '<div class="side-extra">';
    for (const x of c.extras) html += `<a class="side-link${x.id === activeId ? ' active' : ''}" href="#/x/${x.id}"><span class="num">·</span><span>${esc(x.title)}</span><span></span></a>`;
    html += `<a class="side-link" href="${fileUrl('learn/lab/README.md')}" data-file="learn/lab/README.md"><span class="num">·</span><span>Fișierele laboratorului</span><span></span></a>`;
    html += '</div>';
    const sb = $('#sidebar');
    sb.innerHTML = html;
    for (const a of $$('[data-file]', sb)) a.addEventListener('click', (e) => { e.preventDefault(); openFile(a.dataset.file); });
  }

  function nextTask() {
    const last = store.get(KEYS.last, null);
    const order = state.curriculum.modules;
    const startAt = Math.max(0, order.findIndex((m) => m.id === last));
    const sequence = [...order.slice(startAt), ...order.slice(0, startAt)];
    for (const m of sequence) {
      const t = (state.tasks[m.id] || []).find((x) => !state.progress[x.id]);
      if (t) return { module: m, task: t };
    }
    return null;
  }

  function renderDashboard() {
    const c = state.curriculum;
    const o = overall();
    const next = nextTask();
    const hours = c.modules.reduce((n, m) => n + (m.hours || 0), 0);
    let html = `<section class="hero">
        <div><h1>${esc(c.title)}</h1><p>${esc(c.tagline)}</p></div>
        <div class="ring" style="--p:${o.pct}"><div><b>${o.pct}%</b><small>${o.done}/${o.total} taskuri</small></div></div>
      </section>`;
    if (next) {
      const anchor = `t-${next.task.id.replace(/[^a-z0-9-]/gi, '-')}`;
      html += `<div class="continue"><div class="what"><small>Continuă de aici · modulul ${esc(next.module.id)}</small>
        <span>${esc(next.task.text.length > 140 ? `${next.task.text.slice(0, 140)}…` : next.task.text)}</span></div>
        <a class="btn" href="#/m/${next.module.id}/${anchor}">Deschide →</a></div>`;
    } else if (o.total) {
      html += '<div class="continue"><div class="what"><small>Gata</small><span>Ai bifat tot. Acum reconstruiește clusterul din Git fără notițe — modulul 19.</span></div></div>';
    }
    for (const phase of c.phases) {
      html += `<section class="phase"><h2>${esc(phase.title)}</h2><p>${esc(phase.description)}</p><div class="cards">`;
      for (const m of c.modules.filter((x) => x.phase === phase.id)) {
        const s = stats(m.id);
        const st = status(m.id);
        const label = st === 'done' ? 'gata' : st === 'partial' ? 'în lucru' : 'neînceput';
        html += `<a class="card" href="#/m/${m.id}">
          <div class="top"><span>MODUL ${esc(m.id)}</span><span class="badge ${st}">${label}</span></div>
          <h3>${esc(m.title)}</h3><p>${esc(m.summary)}</p>
          <div class="bar ${st === 'done' ? 'ok' : ''}"><span style="width:${s.pct}%"></span></div>
          <div class="meta"><span>~${m.hours} h</span><span>${s.done}/${s.total} taskuri</span></div></a>`;
      }
      html += '</div></section>';
    }
    const where = state.sync === 'account'
      ? 'Progresul și notițele se salvează în contul tău claude.ai și în acest browser'
      : 'Progresul și notițele stau în acest browser — transferă-le dacă schimbi mașina';
    html += `<div class="tools">
        <span class="hint">${where}. Cursul are ~${hours} ore de lucru.</span>
        <button class="btn ghost small" id="transferBtn" type="button" aria-expanded="false">Transferă progresul</button>
        <button class="btn ghost small" id="resetBtn" type="button">Resetează</button>
        <span class="tool-status" id="toolStatus" role="status"></span>
        <div class="transfer" id="transfer" hidden>
          <label for="progressJson">Copiază textul pe celălalt dispozitiv, sau lipește aici un export și încarcă-l.</label>
          <textarea id="progressJson" spellcheck="false"></textarea>
          <div class="transfer-actions">
            <button class="btn small" id="copyJson" type="button">Copiază</button>
            <button class="btn ghost small" id="loadJson" type="button">Încarcă textul</button>
            <label class="btn ghost small" for="importFile">Încarcă un fișier…</label>
            <input id="importFile" type="file" accept="application/json" hidden>
          </div>
        </div>
      </div>`;
    main().innerHTML = html;
    $('#toc').innerHTML = '';
    wireTools();
    renderSidebar(null);
    document.title = c.title;
  }

  function updateModuleProgress(id) {
    const el = $('#modProgress');
    if (!el) return;
    const s = stats(id);
    el.innerHTML = `<div class="bar ${s.done === s.total && s.total ? 'ok' : ''}"><span style="width:${s.pct}%"></span></div><span>${s.done}/${s.total} taskuri</span>`;
  }

  function renderToc(toc) {
    const el = $('#toc');
    if (toc.length < 2) { el.innerHTML = ''; return; }
    const routeBase = location.hash.split('/').slice(0, 3).join('/');
    el.innerHTML = `<div class="toc-title">Pe pagină</div>${toc.map((t) => `<a class="l${t.level}" href="${routeBase}/${t.slug}" data-slug="${t.slug}">${esc(t.text.replace(/#$/, ''))}</a>`).join('')}`;
    const links = new Map($$('a', el).map((a) => [a.dataset.slug, a]));
    if (state.spy) state.spy.disconnect();
    state.spy = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        $$('a.active', el).forEach((a) => a.classList.remove('active'));
        const a = links.get(e.target.id);
        if (a) a.classList.add('active');
      }
    }, { rootMargin: '-70px 0px -70% 0px' });
    for (const t of toc) { const h = document.getElementById(t.slug); if (h) state.spy.observe(h); }
  }

  function renderPage(kind, id, anchor) {
    const c = state.curriculum;
    const list = kind === 'm' ? c.modules : c.extras;
    const idx = list.findIndex((x) => x.id === id);
    const item = list[idx];
    if (!item) { main().innerHTML = '<p>Modulul nu există.</p>'; return; }
    const md = state.docs[id];
    const isModule = kind === 'm';
    let head = '';
    if (isModule) {
      store.set(KEYS.last, id);
      const phase = c.phases.find((p) => p.id === item.phase);
      const prereqs = (item.prereqs || []).map((p) => `<a href="#/m/${p}">${esc(p)}</a>`).join(', ');
      head = `<header class="mod-head">
          <div class="crumbs"><a href="#/">Acasă</a> · ${esc(phase ? phase.title : '')} · Modul ${esc(item.id)}</div>
          <h1>${esc(item.title)}</h1>
          <p class="summary">${esc(item.summary)}</p>
          <div class="mod-meta"><span>⏱ ~${item.hours} ore</span>${prereqs ? `<span>Înainte: ${prereqs}</span>` : ''}${item.tags ? `<span>${item.tags.map(esc).join(' · ')}</span>` : ''}</div>
          ${item.objectives ? `<div class="objectives"><h4>La final vei putea</h4><ul>${item.objectives.map((o) => `<li>${esc(o)}</li>`).join('')}</ul></div>` : ''}
          <div class="mod-progress" id="modProgress"></div>
        </header>`;
    } else {
      head = `<header class="mod-head"><div class="crumbs"><a href="#/">Acasă</a> · Anexe</div><h1>${esc(item.title)}</h1><p class="summary">${esc(item.summary || '')}</p></header>`;
    }
    const prev = isModule ? c.modules[idx - 1] : null;
    const next = isModule ? c.modules[idx + 1] : null;
    main().innerHTML = `${head}<article class="prose" id="prose"></article>
      ${isModule ? `<section class="notes"><h3>Notițele tale</h3><p>Explică cu cuvintele tale ce ai înțeles — dacă nu poți scrie simplu, încă nu ai înțeles. Se salvează automat.</p><textarea id="notes" placeholder="Ex: etcd e singurul loc cu stare; restul control plane-ului e stateless și poate fi refăcut…"></textarea><div class="saved" id="notesSaved"></div></section>` : ''}
      <nav class="pager">${prev ? `<a href="#/m/${prev.id}"><small>← Modul ${esc(prev.id)}</small>${esc(prev.title)}</a>` : ''}${next ? `<a class="next" href="#/m/${next.id}"><small>Modul ${esc(next.id)} →</small>${esc(next.title)}</a>` : ''}</nav>`;
    const prose = $('#prose');
    if (md == null) {
      prose.innerHTML = `<p class="err">Nu am putut încărca <code>${esc(item.file)}</code>.</p>`;
    } else {
      const toc = renderMarkdown(prose, md, { docPath: `learn/${item.file}`, moduleId: isModule ? id : null, routeId: `${kind}/${id}` });
      renderToc(toc);
    }
    if (isModule) {
      updateModuleProgress(id);
      const ta = $('#notes');
      ta.value = state.notes[id] || '';
      let t;
      ta.addEventListener('input', () => {
        clearTimeout(t);
        t = setTimeout(() => {
          state.notes[id] = ta.value; store.set(KEYS.notes, state.notes); scheduleSync();
          $('#notesSaved').textContent = 'Salvat';
          setTimeout(() => { $('#notesSaved').textContent = ''; }, 1200);
        }, 400);
      });
    }
    renderSidebar(id);
    document.title = `${item.title} · ${c.title}`;
    requestAnimationFrame(() => {
      const target = anchor && document.getElementById(anchor);
      if (target) target.scrollIntoView({ block: 'start' });
      else window.scrollTo(0, 0);
    });
  }

  function highlight(text, terms) {
    const f = fold(text);
    const marks = new Array(text.length).fill(false);
    const chars = Array.from(text);
    const fchars = Array.from(f);
    const joined = fchars.join('');
    for (const term of terms) {
      let i = joined.indexOf(term);
      while (i !== -1) {
        // Convert UTF-16 index of the folded string back to a char index.
        const start = Array.from(joined.slice(0, i)).length;
        for (let k = 0; k < Array.from(term).length; k++) marks[start + k] = true;
        i = joined.indexOf(term, i + term.length);
      }
    }
    let out = '', open = false;
    chars.forEach((ch, i) => {
      if (marks[i] && !open) { out += '<mark>'; open = true; }
      if (!marks[i] && open) { out += '</mark>'; open = false; }
      out += esc(ch);
    });
    return open ? `${out}</mark>` : out;
  }

  function renderSearch(q) {
    const terms = fold(q).split(/\s+/).filter((t) => t.length > 1);
    $('#toc').innerHTML = '';
    if (!terms.length) { main().innerHTML = '<div class="results"><h1>Caută</h1><p>Scrie cel puțin două litere.</p></div>'; return; }
    const hits = [];
    for (const s of state.index) {
      if (!terms.every((t) => s.folded.includes(t))) continue;
      const fh = fold(s.heading);
      // A term in the heading weighs most; then how often it appears, capped,
      // so one long section cannot outrank every focused one.
      const score = terms.reduce((n, t) => n + (fh.includes(t) ? 8 : 0) + Math.min(s.folded.split(t).length - 1, 5), 0);
      hits.push({ s, score });
    }
    hits.sort((a, b) => b.score - a.score);
    let html = `<div class="results"><h1>${hits.length} rezultate pentru „${esc(q)}”</h1>`;
    for (const { s } of hits.slice(0, 60)) {
      const fb = fold(s.body);
      const at = Math.max(0, fb.indexOf(terms[0]) - 70);
      const snippet = (at > 0 ? '…' : '') + s.body.slice(at, at + 220) + (s.body.length > at + 220 ? '…' : '');
      const kind = state.curriculum.modules.some((m) => m.id === s.id) ? 'm' : 'x';
      html += `<a class="result" href="#/${kind}/${s.id}${s.anchor ? `/${s.anchor}` : ''}"><small>${kind === 'm' ? `Modul ${esc(s.id)} · ` : ''}${esc(s.title)}</small><b>${highlight(s.heading, terms)}</b><p>${highlight(snippet, terms)}</p></a>`;
    }
    main().innerHTML = `${html}</div>`;
    renderSidebar(null);
  }

  // ---------- file viewer ----------

  const LANG = {
    yaml: 'yaml', yml: 'yaml', json: 'json', json5: 'json', jsonc: 'json', sh: 'bash', bash: 'bash', env: 'bash',
    tf: 'ini', hcl: 'ini', toml: 'ini', conf: 'ini', ini: 'ini', cfg: 'ini', service: 'ini', timer: 'ini',
    go: 'go', py: 'python', lua: 'lua', txt: 'plaintext', mod: 'go', mk: 'makefile',
  };

  function langFor(path) {
    const name = path.split('/').pop();
    if (/^Dockerfile/.test(name)) return 'dockerfile';
    if (/^Makefile$/.test(name)) return 'makefile';
    const parts = name.split('.');
    let ext = parts.pop().toLowerCase();
    if (ext === 'j2' && parts.length > 1) ext = parts.pop().toLowerCase();
    if (ext === 'md') return 'md';
    return LANG[ext] || 'plaintext';
  }

  async function openFile(path) {
    const modal = $('#modal');
    const body = $('#modalBody');
    const url = fileUrl(path);
    $('#modalTitle').textContent = path;
    $('#modalRaw').href = url || githubUrl(path);
    modal.hidden = false;
    $('#modalClose').focus();
    if (!url) {
      body.innerHTML = `<div class="err">Fișierul nu e publicat aici. <a href="${esc(githubUrl(path))}" target="_blank" rel="noopener">Deschide-l pe GitHub</a>.</div>`;
      return;
    }
    body.innerHTML = '<div class="err" style="color:var(--muted)">Se încarcă…</div>';
    try {
      const res = await fetch(url, { cache: 'no-store' });
      if (!res.ok) {
        const why = res.status === 403
          ? 'Blocat de learn/serve.py — calea poate conține un secret.'
          : res.status === 404 && LOCAL_REPO
            ? 'Nu există. Dacă ai pornit serverul din learn/, pornește-l din rădăcina repo-ului: <code>python learn/serve.py</code>.'
            : res.status === 404
              ? `Nu e publicat aici. <a href="${esc(githubUrl(path))}" target="_blank" rel="noopener">Încearcă pe GitHub</a>.`
              : `HTTP ${res.status}`;
        body.innerHTML = `<div class="err">${why}</div>`;
        return;
      }
      const text = await res.text();
      const lang = langFor(path);
      if (lang === 'md') {
        body.innerHTML = '<div class="prose"></div>';
        renderMarkdown(body.firstElementChild, text, { docPath: path });
        for (const a of $$('a.mod-link', body)) a.addEventListener('click', closeModal);
      } else {
        const pre = document.createElement('pre');
        const code = document.createElement('code');
        code.textContent = text;
        code.className = `language-${lang}`;
        pre.appendChild(code);
        body.innerHTML = '';
        body.appendChild(pre);
        if (window.hljs && hljs.getLanguage(lang)) hljs.highlightElement(code);
      }
    } catch (err) {
      body.innerHTML = `<div class="err">${esc(err.message)}</div>`;
    }
  }

  function closeModal() { $('#modal').hidden = true; }

  // ---------- import / export ----------

  // Plain text in a box, not a download: an Artifact's frame blocks downloads,
  // and copy-paste works everywhere, phone included.
  function wireTools() {
    const status = (msg) => { $('#toolStatus').textContent = msg; };
    const box = $('#progressJson');
    const exportText = () => JSON.stringify({ exportedAt: new Date().toISOString(), progress: state.progress, notes: state.notes }, null, 2);
    const load = (txt) => {
      let data;
      try { data = JSON.parse(txt); } catch (err) { status(`Textul nu e un export valid (${err.message}).`); return; }
      if (!data || typeof data !== 'object' || (!data.progress && !data.notes)) { status('Textul nu conține progres sau notițe.'); return; }
      Object.assign(state.progress, data.progress || {});
      Object.assign(state.notes, data.notes || {});
      store.set(KEYS.notes, state.notes);
      saveProgress();
      route(true);
      $('#toolStatus').textContent = 'Progres încărcat.';
    };

    $('#transferBtn').addEventListener('click', (e) => {
      const panel = $('#transfer');
      panel.hidden = !panel.hidden;
      e.currentTarget.setAttribute('aria-expanded', String(!panel.hidden));
      if (!panel.hidden) box.value = exportText();
    });
    $('#copyJson').addEventListener('click', () => {
      copyText(box.value, null).then((ok) => {
        if (!ok) { box.focus(); box.select(); }
        status(ok ? 'Copiat.' : 'Selectat — apasă Ctrl+C.');
      });
    });
    $('#loadJson').addEventListener('click', () => load(box.value));
    $('#importFile').addEventListener('change', (e) => {
      const file = e.target.files[0];
      if (file) file.text().then(load, (err) => status(`Nu pot citi fișierul: ${err.message}`));
    });

    // Two clicks, because a confirm() dialog never shows inside an Artifact.
    let armed = null;
    $('#resetBtn').addEventListener('click', (e) => {
      const btn = e.currentTarget;
      if (!armed) {
        btn.textContent = 'Apasă din nou: șterge tot';
        btn.classList.add('danger');
        armed = setTimeout(() => { armed = null; btn.textContent = 'Resetează'; btn.classList.remove('danger'); }, 4000);
        return;
      }
      clearTimeout(armed);
      state.progress = {}; state.notes = {};
      store.set(KEYS.notes, {});
      saveProgress();
      route(true);
      $('#toolStatus').textContent = 'Progresul a fost șters.';
    });
  }

  // ---------- routing ----------

  function route(force = false) {
    document.body.classList.remove('nav-open');
    $('#scrim').hidden = true;
    const raw = location.hash.replace(/^#\/?/, '');
    const parts = raw.split('/');
    if (parts[0] === 'm' || parts[0] === 'x') {
      const key = `${parts[0]}/${parts[1]}`;
      const anchor = parts.slice(2).join('/');
      // Same page, new anchor (TOC click, heading link): scroll, do not re-render.
      if (!force && state.current === key) {
        const el = anchor && document.getElementById(anchor);
        if (el) el.scrollIntoView({ block: 'start' }); else window.scrollTo(0, 0);
        return;
      }
      state.current = key;
      return renderPage(parts[0], parts[1], anchor);
    }
    state.current = null;
    if (parts[0] === 'search') {
      const q = decodeURIComponent(parts.slice(1).join('/'));
      if ($('#searchInput').value !== q) $('#searchInput').value = q;
      return renderSearch(q);
    }
    if (raw && !raw.includes('/')) {
      // Plain in-page anchor (e.g. a TOC click before routing): keep the current page.
      const el = document.getElementById(raw);
      if (el) { el.scrollIntoView(); return; }
    }
    return renderDashboard();
  }

  function wireChrome() {
    $('#themeBtn').addEventListener('click', () => {
      const next = effectiveTheme() === 'dark' ? 'light' : 'dark';
      store.set(KEYS.theme, next);
      applyTheme();
      route(true);
    });
    $('#menuBtn').addEventListener('click', () => {
      const open = document.body.classList.toggle('nav-open');
      $('#scrim').hidden = !open;
    });
    $('#scrim').addEventListener('click', () => { document.body.classList.remove('nav-open'); $('#scrim').hidden = true; });
    $('#modalClose').addEventListener('click', closeModal);
    $('#modal').addEventListener('click', (e) => { if (e.target.id === 'modal') closeModal(); });
    let t;
    $('#searchInput').addEventListener('input', (e) => {
      clearTimeout(t);
      const q = e.target.value.trim();
      t = setTimeout(() => {
        if (q.length < 2) return;
        const target = `#/search/${encodeURIComponent(q)}`;
        // One history entry per search, not one per keystroke.
        if (location.hash.startsWith('#/search/')) location.replace(target); else location.hash = target;
      }, 220);
    });
    $('#searchInput').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') location.hash = `#/search/${encodeURIComponent(e.target.value.trim())}`;
      if (e.key === 'Escape') { e.target.value = ''; e.target.blur(); }
    });
    document.addEventListener('keydown', (e) => {
      const typing = /INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName);
      if (e.key === '/' && !typing) { e.preventDefault(); $('#searchInput').focus(); }
      if (e.key === 'Escape') { closeModal(); document.body.classList.remove('nav-open'); $('#scrim').hidden = true; }
    });
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (!store.get(KEYS.theme, null)) route(true); });
    window.addEventListener('hashchange', () => route());
  }

  async function init() {
    applyTheme();
    wireChrome();
    if (location.protocol === 'file:') {
      main().innerHTML = `<div class="callout warning"><div class="callout-title">⚠️ Deschis direct din disc</div>
        <p>Browserul nu lasă o pagină <code>file://</code> să citească lecțiile. Din rădăcina repo-ului rulează:</p>
        <pre><code>python learn/serve.py</code></pre><p>și deschide <code>http://127.0.0.1:8080/learn/</code>.</p></div>`;
      return;
    }
    try {
      const res = await fetch(`${APP_BASE}curriculum.json`, { cache: 'no-store' });
      state.curriculum = await res.json();
    } catch (err) {
      main().innerHTML = `<p class="err">Nu pot citi curriculum.json: ${esc(err.message)}</p>`;
      return;
    }
    const all = [...state.curriculum.modules.map((m) => ({ ...m, kind: 'm' })), ...state.curriculum.extras.map((x) => ({ ...x, kind: 'x' }))];
    for (const item of all) state.byFile[`learn/${item.file}`] = `${item.kind}/${item.id}`;
    await Promise.all(all.map(async (item) => {
      try {
        const r = await fetch(APP_BASE + item.file, { cache: 'no-store' });
        if (!r.ok) throw new Error(r.status);
        const md = await r.text();
        state.docs[item.id] = md;
        if (item.kind === 'm') state.tasks[item.id] = parseTasks(item.id, md);
        state.index.push(...buildIndex(item.id, item.title, md));
      } catch {
        state.docs[item.id] = null;
      }
    }));
    if (!window.marked) console.warn('marked did not load (offline?) — showing raw Markdown');
    route(true);
    connectSync();
  }

  init();
})();
