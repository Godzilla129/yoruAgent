// UI text stays Indonesian - it is what the server owner reads. Identifiers,
// API paths and JSON fields are English; the four action verbs are not.
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g,
  c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

let DATA = null;            // the report currently on screen
let PAGE = 'dashboard';
let LOG_KID = null;         // which control's log to show, null = all of them
let SERVERS = [];           // every server that has reported to this dashboard
let PICKED = null;          // the one being looked at; null = whatever is newest
let LOCAL = null;           // the server name of THIS machine, from /api/servers

// Bumped by every render. A page function re-checks it after awaiting a fetch
// and gives up if it moved - the owner has navigated away since.
let RENDER = 0;
let LAST_SCORE = null;     // to show what the score just did, not only where it is
let liveTimer = null;

// Heroicons mini, 20px solid (MIT). Only where a word would not fit: theme, close, open.
const ICONS = {
  computer: '<path fill-rule="evenodd" d="M2 4.25A2.25 2.25 0 0 1 4.25 2h11.5A2.25 2.25 0 0 1 18 4.25v8.5A2.25 2.25 0 0 1 15.75 15h-3.105a3.501 3.501 0 0 0 1.1 1.677A.75.75 0 0 1 13.26 18H6.74a.75.75 0 0 1-.484-1.323A3.501 3.501 0 0 0 7.355 15H4.25A2.25 2.25 0 0 1 2 12.75v-8.5Zm1.5 0a.75.75 0 0 1 .75-.75h11.5a.75.75 0 0 1 .75.75v7.5a.75.75 0 0 1-.75.75H4.25a.75.75 0 0 1-.75-.75v-7.5Z"/>',
  sun: '<path d="M10 2a.75.75 0 0 1 .75.75v1.5a.75.75 0 0 1-1.5 0v-1.5A.75.75 0 0 1 10 2ZM10 15a.75.75 0 0 1 .75.75v1.5a.75.75 0 0 1-1.5 0v-1.5A.75.75 0 0 1 10 15ZM10 7a3 3 0 1 0 0 6 3 3 0 0 0 0-6ZM15.657 5.404a.75.75 0 1 0-1.06-1.06l-1.061 1.06a.75.75 0 0 0 1.06 1.06l1.06-1.06ZM6.464 14.596a.75.75 0 1 0-1.06-1.06l-1.06 1.06a.75.75 0 0 0 1.06 1.06l1.06-1.06ZM18 10a.75.75 0 0 1-.75.75h-1.5a.75.75 0 0 1 0-1.5h1.5A.75.75 0 0 1 18 10ZM5 10a.75.75 0 0 1-.75.75h-1.5a.75.75 0 0 1 0-1.5h1.5A.75.75 0 0 1 5 10ZM14.596 15.657a.75.75 0 0 0 1.06-1.06l-1.06-1.061a.75.75 0 1 0-1.06 1.06l1.06 1.06ZM5.404 6.464a.75.75 0 0 0 1.06-1.06l-1.06-1.06a.75.75 0 1 0-1.061 1.06l1.06 1.06Z"/>',
  moon: '<path fill-rule="evenodd" d="M7.455 2.004a.75.75 0 0 1 .26.77 7 7 0 0 0 9.958 7.967.75.75 0 0 1 1.067.853A8.5 8.5 0 1 1 6.647 1.921a.75.75 0 0 1 .808.083Z"/>',
  x: '<path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z"/>',
  chevron: '<path fill-rule="evenodd" d="M8.22 5.22a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L11.94 10 8.22 6.28a.75.75 0 0 1 0-1.06Z"/>',
};
const I = name => `<svg class="i" viewBox="0 0 20 20" aria-hidden="true">${ICONS[name] || ''}</svg>`;

/* theme: three states; "sistem" stores nothing and lets the OS decide. */
const THEMES = ['sistem', 'terang', 'gelap'];
const THEME_ICON = {sistem: 'computer', terang: 'sun', gelap: 'moon'};

function readTheme() {
  try { return THEMES.includes(localStorage.getItem('yoru-tema'))
    ? localStorage.getItem('yoru-tema') : 'sistem'; } catch (e) { return 'sistem'; }
}
function applyTheme(t) {
  if (t === 'sistem') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', t === 'gelap' ? 'dark' : 'light');
  document.querySelectorAll('#theme button').forEach(b =>
    b.setAttribute('aria-pressed', b.dataset.t === t ? 'true' : 'false'));
}
document.querySelectorAll('#theme button').forEach(b => {
  b.innerHTML = I(THEME_ICON[b.dataset.t]);
  b.onclick = () => {
    try { localStorage.setItem('yoru-tema', b.dataset.t); } catch (e) {}
    applyTheme(b.dataset.t);
  };
});
applyTheme(readTheme());

/* token: never asked from 127.0.0.1. From another machine it is asked once and
   forgotten when the tab closes. */
let TOKEN = (() => { try { return sessionStorage.getItem('yoru-token') || ''; } catch (e) { return ''; } })();

function askToken() {
  return new Promise(done => {
    const d = $('dlgToken');
    d.onclose = () => {
      if (d.returnValue !== 'ya') return done(false);
      TOKEN = $('tokenInput').value.trim();
      try { sessionStorage.setItem('yoru-token', TOKEN); } catch (e) {}
      done(!!TOKEN);
    };
    $('tokenInput').value = TOKEN;
    d.showModal();
  });
}

// Every API call goes through these two, so 401/403 handling lives in one place.
async function post(url, body) {
  const opts = () => ({
    method: 'POST',
    headers: Object.assign({'Content-Type': 'application/json'},
                           TOKEN ? {Authorization: 'Bearer ' + TOKEN} : {}),
    body: JSON.stringify(body)
  });
  let r = await fetch(url, opts());
  if ((r.status === 401 || r.status === 403) && await askToken()) r = await fetch(url, opts());
  return r;
}
async function get(url) {
  const opts = () => ({headers: TOKEN ? {Authorization: 'Bearer ' + TOKEN} : {}});
  let r = await fetch(url, opts());
  if ((r.status === 401 || r.status === 403) && await askToken()) r = await fetch(url, opts());
  return r;
}

// The report's status codes stay as they are; these are the words shown for them.
const TAG = {LULUS:['Aman','p'], GAGAL:['Perlu dibenahi','f'], SEBAGIAN:['Setengah jalan','n'],
             DILEWATI:['Dilewati','x'], ERROR:['Gagal dibaca','x']};

const PAGE_TITLE = {dashboard:'Beranda', history:'Riwayat', settings:'Setelan'};

// 2026-09-08T03:00:12+07:00 -> 8 Sep 2026, 03:00 WIB. Read from the string
// itself, so it shows the server's own clock, not the browser's.
const MONTHS = 'Jan Feb Mar Apr Mei Jun Jul Agu Sep Okt Nov Des'.split(' ');
const ZONES = {'+07:00': 'WIB', '+08:00': 'WITA', '+09:00': 'WIT', 'Z': 'UTC', '+00:00': 'UTC'};
const when = t => {
  const m = String(t || '').match(/^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::[\d.]+)?(Z|[+-]\d\d:\d\d)?/);
  if (!m) return String(t || '');
  const zone = m[6] ? ' ' + (ZONES[m[6]] || 'UTC' + m[6]) : '';
  return `${Number(m[3])} ${MONTHS[Number(m[2]) - 1]} ${m[1]}, ${m[4]}:${m[5]}${zone}`;
};

// Is the report on screen from this very machine? Only then do the
// Audit/Hardening/Rollback buttons mean anything - they run yoructl HERE.
const isLocal = () => !LOCAL || !DATA || (DATA.server && DATA.server.name === LOCAL);

/* loading */
async function loadServers() {
  try {
    const r = await get('/api/servers');
    if (!r.ok) return;
    const j = await r.json();
    SERVERS = j.servers || [];
    LOCAL = j.local || null;
  } catch (e) { /* the picker simply does not appear */ }
}

// The 30-second refresh redraws only when the report really changed, so an
// open "Kenapa?" or a half-read card does not jump shut under the owner.
let LAST_RAW = null;
async function load(force) {
  const q = PICKED ? `?server=${encodeURIComponent(PICKED)}` : '';
  let raw = null;
  try {
    const r = await get('/api/report' + q);
    raw = (r.status === 404 || !r.ok) ? null : await r.text();
    pulse(true);
  } catch (e) {
    // A network blip keeps the last report on screen instead of blanking it.
    pulse(false);
    if (DATA) return;
  }
  if (!force && raw === LAST_RAW && PAGE === 'dashboard' && DATA) return tickTimes();
  LAST_RAW = raw;
  try { DATA = raw ? JSON.parse(raw) : null; } catch (e) { DATA = null; }
  render();
}

// Top right: is this page still talking to the dashboard?
function pulse(ok) {
  const now = new Date();
  $('conn').className = 'conn' + (ok ? '' : ' off');
  $('conn').textContent = ok
    ? `Diperbarui ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`
    : 'Nggak tersambung ke dashboard';
}

function drawPicker() {
  // Shown only when there is more than one server to pick from. Not on
  // Setelan: those settings belong to this machine whatever is picked.
  if (SERVERS.length < 2 || PAGE === 'settings') { $('serverPicker').hidden = true; return; }
  $('serverPicker').hidden = false;
  const current = (DATA && DATA.server && DATA.server.name) || PICKED || '';
  $('serverSelect').innerHTML = SERVERS.map(s =>
    `<option value="${esc(s.name)}" ${s.name === current ? 'selected' : ''}>${esc(s.name)}</option>`
  ).join('');
  $('localTag').hidden = !(current && current === LOCAL);
}
// Another server's score is not a change of this one's, so the +/- starts over.
$('serverSelect').onchange = e => { PICKED = e.target.value; LAST_SCORE = null; load(true); };

/* render */
let SHOWN = PAGE;
function render() {
  const gen = ++RENDER;
  // Another page starts at its top; a refresh of the same page keeps the scroll.
  if (PAGE !== SHOWN) { window.scrollTo(0, 0); SHOWN = PAGE; }
  $('pageTitle').textContent = PAGE_TITLE[PAGE];
  // Beranda carries its own headline in the hero.
  $('pageHead').hidden = PAGE === 'dashboard';
  document.querySelectorAll('#nav [data-h]').forEach(a => {
    const on = a.dataset.h === PAGE;
    a.classList.toggle('on', on);
    if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  });
  drawPicker();
  markBadge();

  if (PAGE !== 'dashboard') clearInterval(liveTimer);
  if (PAGE === 'settings') return settingsPage(gen);
  if (PAGE === 'history')  return historyPage(gen);

  if (!DATA) return emptyState();

  $('content').innerHTML = hero() + askPanel() + controlList();
  wireButtons();
  watchLive();
}

// Everything the owner has to answer: approvals, changed settings, open ports.
function waitingCount() {
  if (!DATA) return 0;
  return (DATA.pending_decisions || []).length + (DATA.drift || []).length
         + pendingPorts().ports.length;
}

// The red number beside "Beranda": how many things wait on the owner.
function markBadge() {
  const waiting = waitingCount();
  const a = document.querySelector('#nav [data-h="dashboard"]');
  const old = a.querySelector('.count');
  if (old) old.remove();
  if (waiting > 0) {
    const pill = document.createElement('span');
    pill.className = 'count';
    pill.textContent = waiting;
    pill.setAttribute('aria-label', `${waiting} nunggu jawabanmu`);
    a.appendChild(pill);
  }
}

// Grey blocks in the shape of what is coming, instead of the word "memuat".
function skeleton(...heights) {
  return heights.map(h => `<div class="sk" style="height:${h}px;margin-bottom:16px"></div>`).join('');
}

function emptyState() {
  $('content').innerHTML = `<section class="empty">
    <h2>Belum ada laporan yang masuk.</h2>
    <p>Laporan pertama muncul setelah Yoru mengecek server. Mau sekarang? Jalankan:</p>
    <code>sudo -u yoru-agent /opt/yoru/bin/yoru-agent --siklus perbaikan</code></section>`;
}

/* words for values. yoructl reports what it read (no, 3/30, aturan=12...);
   these say it in plain words. Anything not listed is shown as it came. */
const PLAIN = {
  K01: {'no': 'root nggak bisa login lewat SSH', 'yes': 'root bisa login pakai password',
        'without-password': 'root masih bisa login pakai kunci SSH',
        'prohibit-password': 'root masih bisa login pakai kunci SSH',
        'forced-commands-only': 'root cuma boleh menjalankan perintah tertentu'},
  K02: {'no': 'login pakai password mati', 'yes': 'login pakai password masih nyala'},
  K04: {'mac_sha1=0': 'tanpa algoritma lemah (sha1)', 'mac_sha1=1': 'masih ada algoritma lemah (sha1)'},
  K05: {'active': 'firewall nyala', 'inactive': 'firewall mati', 'tidak-aktif': 'firewall mati'},
  K07: {'enabled': 'pembaruan otomatis nyala', 'disabled': 'pembaruan otomatis mati',
        'tidak-terpasang': 'belum terpasang'},
  K10: {'1/0/0': '3 dari 3 setelan sesuai', '1/0/na': 'setelan sesuai (tanpa IPv6)'},
};
function plain(kid, value) {
  const v = String(value ?? '').trim();
  if (!v) return '-';
  if (v === 'tidak-terbaca') return 'nggak kebaca';
  const map = PLAIN[kid] || {};
  if (map[v]) return map[v];
  let m;
  if (kid === 'K05' && (m = v.match(/^(active|inactive)\b(.*)$/))) return map[m[1]] + m[2];
  if (kid === 'K03' && (m = v.match(/^(\d+)\/(\d+)$/)))
    return `boleh salah ${m[1]} kali, waktu login ${m[2]} detik`;
  if (kid === 'K08' && (m = v.match(/^aturan(>=|=)(\d+)$/)))
    return `${m[1] === '>=' ? 'minimal ' : ''}${m[2]} aturan audit aktif`;
  if (kid === 'K09' && (m = v.match(/^max ([\d.]+)([KMGT])$/)))
    return `log disimpan, batas ${Number(m[1])} ${m[2]}B`;
  if (kid === 'K10' && (m = v.match(/^(\S)\/(\S)\/(\S+)$/))) {
    // log_martians must be 1, secure_redirects 0, accept_ra 0 (or absent: no IPv6)
    const off = [m[1] !== '1', m[2] !== '0', !['0', 'na'].includes(m[3])].filter(Boolean).length;
    return `${3 - off} dari 3 setelan sesuai`;
  }
  if ((m = v.match(/^(?:0\.0\.0\.0|\*|\[::\]):(\d+)$/))) return `port ${m[1]} terbuka ke semua jaringan`;
  if ((m = v.match(/^(?:127\.0\.0\.1|localhost|\[::1\]):(\d+)$/))) return `port ${m[1]} cuma untuk server ini`;
  return v;
}

const CATEGORY = {ssh: 'Akses SSH', firewall: 'Firewall', jaringan: 'Jaringan',
                  audit: 'Jejak audit', log: 'Log', pembaruan: 'Pembaruan'};
const firstSentence = t => (String(t || '').match(/^.*?[.!?](?=\s|$)/) || [String(t || '')])[0];

// "20 hari lalu". Kept in data-ago, so tickTimes() can refresh it without a redraw.
function ago(t) {
  const ms = Date.now() - new Date(t).getTime();
  if (!isFinite(ms)) return '';
  const min = Math.round(ms / 60000);
  if (min < 1) return 'baru saja';
  if (min < 60) return `${min} menit lalu`;
  if (min < 60 * 24) return `${Math.round(min / 60)} jam lalu`;
  return `${Math.round(min / 1440)} hari lalu`;
}
function tickTimes() {
  document.querySelectorAll('[data-ago]').forEach(el => el.textContent = ago(el.dataset.ago));
}

/* hero: one sentence first, numbers after */
function hero() {
  const s = DATA.summary || {};
  const srv = DATA.server || {};
  const score = s.score ?? 0;
  const waiting = waitingCount();
  const failed = (s.failed ?? 0) + (s.partial ?? 0);
  const band = score >= 80 ? 'good' : score >= 50 ? 'mid' : 'bad';
  const title = failed === 0 && waiting === 0 ? 'Server kamu aman.'
              : band === 'good' ? 'Server kamu cukup aman.'
              : band === 'mid' ? 'Server kamu masih ada celah.' : 'Server kamu masih rawan.';
  const line = [waiting ? `${waiting} hal nunggu jawabanmu` : '',
                failed ? `${failed} pemeriksaan masih perlu dibenahi` : ''].filter(Boolean).join(', ');

  const diff = (LAST_SCORE === null || LAST_SCORE === score) ? 0 : score - LAST_SCORE;
  LAST_SCORE = score;
  const delta = diff ? `<span class="delta ${diff > 0 ? 'up' : 'down'}">${diff > 0 ? 'naik' : 'turun'} ${Math.abs(diff)}</span>` : '';

  const host = [`<b>${esc(srv.name || '')}</b>`, esc(srv.os || ''), esc(srv.primary_ip || ''),
                esc(srv.detected_panel || '')].filter(x => x && x !== '<b></b>').join(' · ');

  const go = waiting
    ? `<button class="btn primary lg" data-jump="ask">Jawab ${waiting} pertanyaan</button>`
    : failed ? `<button class="btn lg" data-jump="checks">Lihat yang perlu dibenahi</button>` : '';

  const local = isLocal();
  const facts = [
    `<div><dt>Dicek</dt><dd>${esc(when(DATA.time))} · <span data-ago="${esc(DATA.time)}">${ago(DATA.time)}</span></dd></div>`,
    local && SCHEDULE ? `<div><dt>Cek harian</dt><dd>jam ${esc(SCHEDULE)}</dd></div>` : '',
    local ? `<div id="lastAct" hidden><dt>Tindakan terakhir</dt><dd></dd></div>` : '',
  ].join('');

  const remote = local ? '' : `<p class="remote">Ini laporan dari
    <b>${esc(srv.name || 'server lain')}</b>. Menyetujui dan menjawab port tetap bisa.
    Tombol Cek ulang, Amankan dan Kembalikan cuma jalan di server tempat dashboard ini dipasang.</p>`;

  return `<section class="hero">
    <p class="host">${host}</p>
    <p class="score ${band}">Skor keamanan <b class="num">${score}</b> dari 100${delta}</p>
    <h1>${title}</h1>
    <p class="lead">${line ? esc(line) + '.' : 'Semua pemeriksaan sudah aman.'}</p>
    ${go ? `<div class="go">${go}</div>` : ''}
    ${remote}
    <dl class="facts">${facts}</dl>
  </section>`;
}

/* ports: K05 will not switch the firewall on while an open port is unanswered;
   the ports ride along in K05's blockers. */
function pendingPorts() {
  const k05 = ((DATA && DATA.controls) || []).find(k => k.id === 'K05');
  const raw = (k05 && (k05.blockers || [])[0]) || '';
  const out = [];
  // Shape written by yoructl: "port terbuka belum dijawab pemilik: 8888(python3) 3306(mariadbd)"
  for (const m of raw.matchAll(/(\d{1,5})\(([^)]*)\)/g)) out.push({port: m[1], proc: m[2]});
  return {ports: out, note: (k05 && k05.ai_note) || ''};
}

/* "Perlu jawabanmu": changed settings, open ports and approvals, one row each */
function askPanel() {
  const drift = DATA.drift || [];
  const {ports, note} = pendingPorts();
  const asking = DATA.pending_decisions || [];
  const total = waitingCount();
  if (!total) return '';
  const byId = {};
  (DATA.controls || []).forEach(k => byId[k.id] = k);
  const rows = [];

  // drift: the heart of the watch cycle
  for (const d of drift) {
    const bits = [];
    if (d.who)        bits.push(`diubah oleh <b>${esc(d.who)}</b>`);
    if (d.changed_at) bits.push(esc(when(d.changed_at)));
    if (d.command)    bits.push(`lewat <code>${esc(d.command)}</code>`);
    const evidence = bits.length ? bits.join(' · ')
      : 'Siapa yang mengubah nggak tercatat, karena jejak audit (auditd) belum aktif di server ini. Yoru nggak menebak.';
    rows.push(`<li class="item" data-kid="${esc(d.id)}">
      <div class="body">
        <div class="t">${esc(d.name)} berubah</div>
        <div class="d">Dulu <span class="badge p" title="${esc(d.changed_from)}">${esc(plain(d.id, d.changed_from))}</span>,
          sekarang <span class="badge f" title="${esc(d.changed_to)}">${esc(plain(d.id, d.changed_to))}</span>.
          Ini kamu yang ubah?</div>
        <div class="evidence">${evidence}</div>
        <span class="result" data-slot></span>
      </div>
      <div class="acts">
        <button class="btn" data-drift="sah">Iya, saya</button>
        <button class="btn danger" data-drift="kembalikan">Kembalikan</button>
      </div></li>`);
  }

  if (ports.length) {
    rows.push(`<li class="item">
      <div class="body">
        <div class="t">Port ini terbuka ke internet. Punya kamu?</div>
        <div class="d">Firewall baru bisa dinyalakan setelah semua port ini kamu jawab.</div>
        ${note ? `<details class="why"><summary>Kata Yoru soal port ini</summary><p>${esc(note)}</p></details>` : ''}
        <ul class="ports">${ports.map(p => `
          <li data-port="${esc(p.port)}">
            <span class="n num">${esc(p.port)}</span>
            <span class="proc">${esc(p.proc || 'program tak dikenal')}</span>
            <button class="btn" data-portok="${esc(p.port)}">Punya saya</button>
          </li>`).join('')}</ul>
        <span class="result" data-slot-port></span>
      </div></li>`);
  }

  for (const kid of asking) {
    const k = byId[kid] || {id: kid, name: kid};
    const rest = String(k.why || '').slice(firstSentence(k.why).length).trim();
    rows.push(`<li class="item" data-kid="${esc(kid)}">
      <div class="body">
        <div class="t">Boleh Yoru amankan: ${esc(k.name || kid)}?</div>
        <div class="d">${esc(firstSentence(k.why))}</div>
        ${rest || k.breaks_if_applied ? `<details class="why"><summary>Kenapa, dan apa yang ikut berubah?</summary>
          ${rest ? `<p>${esc(rest)}</p>` : ''}
          ${k.breaks_if_applied ? `<p><b>Yang ikut berubah:</b> ${esc(k.breaks_if_applied)}</p>` : ''}</details>` : ''}
        <span class="result" data-slot></span>
      </div>
      <div class="acts">
        <button class="btn primary" data-decide="setuju">Setujui</button>
        <button class="btn ghost" data-decide="tolak">Jangan</button>
      </div></li>`);
  }

  const remote = isLocal() ? '' : ' Jawabanmu dikerjakan di server itu pada pemeriksaan berikutnya.';
  return `<section class="sec" id="ask">
    <div class="sec-head"><div>
      <h2>Perlu jawabanmu <span class="count">${total}</span></h2>
      <p>Yoru nunggu kamu sebelum lanjut.${remote}</p></div></div>
    <ul class="list">${rows.join('')}</ul></section>`;
}

/* the ten checks: worst first, one line each, the rest in the detail panel */
function controlList() {
  const local = isLocal();
  const all = DATA.controls || [];
  const groups = [
    ['Perlu dibenahi', all.filter(k => ['GAGAL', 'SEBAGIAN', 'ERROR'].includes(k.status))],
    ['Sudah aman', all.filter(k => k.status === 'LULUS')],
    ['Dilewati', all.filter(k => k.status === 'DILEWATI')],
  ].filter(([, list]) => list.length);

  const row = k => {
    const [label, cls] = TAG[k.status] || ['?', 'x'];
    const blocker = (k.blockers || [])[0];
    const sub = blocker && k.status !== 'LULUS'
      ? `<span class="sub warn">Belum bisa: ${esc(blocker)}</span>`
      : `<span class="sub">${k.status === 'LULUS' ? '' : 'Sekarang: '}${esc(plain(k.id, k.observed))}</span>`;
    return `<li><button class="ctl" data-open="${esc(k.id)}">
      <span><span class="nm">${esc(k.name)}</span>${sub}</span>
      <span class="badge ${cls}">${label}</span>
      <span class="chev">${I('chevron')}</span></button></li>`;
  };

  const bulk = local ? `<div class="bulk">
      <button class="btn" data-bulk="periksa">Cek ulang semua</button>
      <button class="btn" data-bulk="terapkan">Amankan semua</button>
      <button class="btn danger" data-bulk="kembalikan">Kembalikan semua</button></div>` : '';
  return `<section class="sec" id="checks">
    <div class="sec-head"><div><h2>Pemeriksaan keamanan</h2></div>${bulk}</div>
    ${groups.map(([title, list]) =>
      `<h3 class="grp">${title} · ${list.length}</h3><ul class="list">${list.map(row).join('')}</ul>`).join('')}
  </section>`;
}

/* detail panel for one check */
function openControl(kid) {
  const k = (DATA.controls || []).find(x => x.id === kid);
  if (!k) return;
  const [label, cls] = TAG[k.status] || ['?', 'x'];
  const local = isLocal();
  const blocked = (k.blockers || []).length > 0;
  const needsApproval = (DATA.pending_decisions || []).includes(kid);
  const off = local ? '' : ' disabled';
  // The value as yoructl read it, under the plain words, only when it is a
  // code-like token (no, 3/30, 0.0.0.0:3306) that the words replaced.
  const raw = (v, p) => v && p !== String(v) && !/\s/.test(String(v)) ? `<code>${esc(v)}</code>` : '';
  const cis = String(k.cis_code || '').startsWith('TIDAK_ADA') ? 'di luar CIS Level 1' : (k.cis_code || '-');
  const pNow = plain(kid, k.observed), pWant = plain(kid, k.target);

  $('ctlBody').innerHTML = `<div data-kid="${esc(kid)}">
    <div class="top">
      <h3>${esc(k.name)}</h3>
      <button class="close" value="tutup" aria-label="Tutup">${I('x')}</button>
    </div>
    <div class="tags">
      <span class="badge ${cls}">${label}</span>
      ${CATEGORY[k.category] ? `<span class="badge x">${CATEGORY[k.category]}</span>` : ''}
      <span class="badge ${k.risk === 'BERISIKO' ? 'n' : 'x'}">${k.risk === 'BERISIKO'
        ? 'Butuh izinmu dulu' : 'Aman dijalankan otomatis'}</span>
    </div>
    <dl class="kv">
      <div><dt>Sekarang</dt><dd>${esc(pNow)}${raw(k.observed, pNow)}</dd></div>
      <div><dt>Harusnya</dt><dd>${esc(pWant)}${raw(k.target, pWant)}</dd></div>
    </dl>
    ${blocked ? `<div class="box warn"><b>Belum bisa diamankan</b>${k.blockers.map(esc).join('<br>')}</div>` : ''}
    ${k.ai_note ? `<div class="box info"><b>Catatan Yoru</b>${esc(k.ai_note)}</div>` : ''}
    ${k.why ? `<h4>Kenapa penting</h4><p>${esc(k.why)}</p>` : ''}
    ${k.breaks_if_applied ? `<h4>Kalau diamankan, ini yang ikut berubah</h4><p>${esc(k.breaks_if_applied)}</p>` : ''}
    <div class="acts">
      <button type="button" class="btn primary" data-a="terapkan"${off || (blocked ? ' disabled' : '')}
        ${blocked ? 'title="prasyarat belum terpenuhi"' : ''}
        data-approval="${needsApproval ? 1 : 0}">Amankan</button>
      <button type="button" class="btn" data-a="periksa"${off}>Cek ulang</button>
      <button type="button" class="btn danger" data-a="kembalikan"${off}>Kembalikan</button>
      <button type="button" class="btn ghost" data-a="log">Lihat log</button>
    </div>
    ${local ? '' : '<div class="result wait">Tombolnya mati karena ini laporan dari server lain.</div>'}
    <span class="result" data-slot></span>
    <div class="ref">Kode pemeriksaan ${esc(kid)} · CIS Ubuntu 24.04: ${esc(cis)}</div>
  </div>`;

  $('ctlBody').querySelectorAll('button[data-a]').forEach(b => {
    b.onclick = () => {
      if (b.dataset.a === 'log') {
        $('dlgCtl').close();
        PAGE = 'history'; LOG_KID = kid; render(); return;
      }
      if (b.dataset.a === 'terapkan' && b.dataset.approval === '1') return confirmApply(kid, b);
      run(kid, b.dataset.a, b);
    };
  });
  const d = $('dlgCtl');
  if (!d.open) d.showModal();
}
// A click on the dimmed backdrop closes the panel, as on a phone sheet.
$('dlgCtl').addEventListener('click', e => { if (e.target === $('dlgCtl')) $('dlgCtl').close(); });

/* history */
// One page answers one question: what has happened here. The score line and
// the action trail are two views of the same answer, so they share a page.
async function historyPage(gen) {
  $('meta').textContent = PICKED || (DATA && DATA.server && DATA.server.name) || '';
  $('content').innerHTML = skeleton(240, 320);

  const q = PICKED ? `?server=${encodeURIComponent(PICKED)}&limit=60` : '?limit=60';
  let rows = [];
  try {
    const r = await get('/api/history' + q);
    if (r.ok) rows = (await r.json()).history || [];
  } catch (e) { /* drawn as empty below */ }
  if (gen !== RENDER) return;

  const logHtml = await logPanel(LOG_KID, gen);
  if (gen !== RENDER) return;

  $('content').innerHTML = chartPanel(rows) + logHtml;
  const all = $('allLogs'); if (all) all.onclick = () => { LOG_KID = null; render(); };
}

function chartPanel(rows) {
  if (!rows.length) {
    return `<section class="sec"><div class="empty">
      <h2>Belum ada riwayat.</h2><p>Riwayat terisi sendiri setiap kali Yoru mengecek server.</p></div></section>`;
  }

  const data = rows.slice().reverse();
  const W = 780, H = 170, pad = 26, n = data.length;
  const bw = Math.max(3, Math.min(34, (W - pad * 2) / n - 5));
  const step = (W - pad * 2) / n;
  const bars = data.map((r, i) => {
    const h = Math.max(2, (r.score / 100) * (H - pad - 12));
    const x = pad + i * step + (step - bw) / 2;
    return `<rect class="bar${i === n - 1 ? ' last' : ''}" x="${x.toFixed(1)}" y="${(H - pad - h).toFixed(1)}"
      width="${bw.toFixed(1)}" height="${h.toFixed(1)}" rx="2"><title>${esc(when(r.time))} · skor ${r.score} (${esc(r.cycle)})</title></rect>`;
  }).join('');
  const gridlines = [0, 25, 50, 75, 100].map(v => {
    const y = H - pad - (v / 100) * (H - pad - 12);
    return `<line class="grid" x1="${pad}" y1="${y.toFixed(1)}" x2="${W - 6}" y2="${y.toFixed(1)}"/>
            <text class="lbl" x="2" y="${(y + 3).toFixed(1)}">${v}</text>`;
  }).join('');

  const first = data[0], last = data[n - 1];
  const delta = last.score - first.score;
  const colour = delta > 0 ? 'var(--ok)' : delta < 0 ? 'var(--bad)' : 'var(--text-3)';
  const change = delta > 0 ? `naik ${delta} poin` : delta < 0 ? `turun ${-delta} poin` : 'tidak berubah';

  return `<section class="sec">
    <div class="sec-head"><div><h2>Skor tiap laporan</h2>
      <p>${n} laporan terakhir. Arahkan kursor ke batang untuk melihat tanggalnya.</p></div></div>
    <svg class="chart" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img"
         aria-label="Grafik skor keamanan dari waktu ke waktu">
      ${gridlines}${bars}
    </svg>
    <div class="legend">
      <span>Paling lama: <b>${esc(when(first.time))}</b>, skor ${first.score}</span>
      <span>Terbaru: <b>${esc(when(last.time))}</b>, skor ${last.score}</span>
      <span style="color:${colour}">Skor ${change}</span>
    </div></section>`;
}

/* logs */
const LOG_TONE = {LULUS:'p', DIKEMBALIKAN:'p', DISIMPAN:'p', GAGAL:'f', ERROR:'f', DITOLAK:'n', PERINGATAN:'n'};

// yoructl writes the trail in UTC. It is shown in the report's own zone, so the
// trail and the report read the same clock. The trail is this machine's, so
// only a report from this machine can lend its zone; otherwise UTC stays.
function reportZone(t) {
  const off = isLocal() && String((DATA && DATA.time) || '').match(/([+-])(\d\d):(\d\d)$/);
  const ms = new Date(t).getTime();
  if (!off || !isFinite(ms)) return t;
  const shift = (off[1] === '-' ? -1 : 1) * (Number(off[2]) * 60 + Number(off[3])) * 60000;
  return new Date(ms + shift).toISOString().slice(0, 19) + off[0];
}
const nameOf = kid => (((DATA && DATA.controls) || []).find(k => k.id === kid) || {}).name || kid;

async function logPanel(kid, gen) {
  const q = kid ? `?control=${encodeURIComponent(kid)}` : '';
  let d;
  try {
    const r = await get('/api/log' + q);
    d = r.ok ? await r.json() : {lines: [], message: 'perlu token untuk membaca jejak tindakan'};
  } catch (e) { d = {lines: []}; }
  if (gen !== undefined && gen !== RENDER) return '';

  const body = (d.lines || []).length
    ? `<ul class="list log">${d.lines.map(b => {
        const value = b.value ? plain(b.id, b.value) : '';
        const said = [value, b.message !== value ? b.message : ''].filter(Boolean).join(' · ');
        return `<li>
        <span class="w num">${esc(when(reportZone(b.time)))}</span>
        <span class="badge ${LOG_TONE[b.status] || 'x'}">${esc(statusLabel(b.status))}</span>
        <span class="what">${esc(ACTION_LABEL[b.action] || b.action)}: ${esc(nameOf(b.id))}</span>
        <span class="msg">${esc(said)}</span></li>`;
      }).join('')}</ul>`
    : `<div class="empty"><h2>Belum ada catatan.</h2><p>${esc(d.message || 'Jejak tindakan ditulis ke /var/log/yoru/ setiap kali sebuah kontrol dijalankan.')}</p></div>`;

  return `<section class="sec">
    <div class="sec-head"><div><h2>Jejak tindakan${kid ? ' · ' + esc(nameOf(kid)) : ''}</h2>
      <p>Catatan ini nggak bisa diubah Yoru sendiri.</p></div>
      <div class="bulk">${kid ? '<button class="btn" id="allLogs">Lihat semua</button>' : ''}</div></div>
    ${body}</section>`;
}

/* settings */
// Three groups on one page, one Save each, so the config is loaded once.
const SETTINGS = [
  {id: 'telegram', title: 'Bot Telegram',
   intro: 'Yoru cuma mengirim kabar kalau ada yang berubah atau ada yang perlu kamu jawab. Selain itu kamu bisa tanya apa aja lewat chat.',
   fields: [
     {key:'TELEGRAM_TOKEN', label:'Token bot', secret:true,
      hint:'Dari @BotFather: /newbot, lalu salin utuh barisnya. Bentuknya angka, titik dua, lalu huruf-angka.'},
     {key:'TELEGRAM_CHAT_ID', label:'Chat ID (boleh dikosongkan)',
      hint:'Biasanya terisi sendiri begitu kamu kirim /start beserta kode sambung ke botmu. Isi manual cuma kalau botnya yang meminta.'}]},

  {id: 'model', title: 'Model AI',
   intro: 'Otak AI Yoru (Hermes) jalan di server ini. Dia yang menjawab chat Telegram dan menulis catatan di laporan. Kunci API-nya nggak disimpan di sini. Kosong = Yoru tetap jalan, cuma tanpa AI.',
   fields: [
     {key:'HERMES_URL', label:'Alamat server model',
      hint:'Diisi installer, biasanya http://127.0.0.1:8642. Ganti model atau kunci lewat: sudo bash install.sh --hermes'},
     {key:'AI_MODEL', label:'Nama model (boleh dikosongkan)',
      hint:'Untuk Hermes isinya hermes-agent. Model Gemini-nya dipilih di installer.'},
     {key:'HERMES_TOKEN', label:'Token server model (boleh dikosongkan)', secret:true,
      hint:'Diisi installer. Ini kunci antara Yoru dan Hermes di server ini, bukan kunci API berbayar.'}]},

  {id: 'sistem', title: 'Sistem',
   intro: 'Setelan server ini. Disimpan di /etc/yoru/yoru.conf.',
   fields: [
     {key:'NAMA_SERVER', label:'Nama server',
      hint:'Nama yang muncul di dashboard dan bot. Kosong = pakai hostname.'},
     {key:'PORT_DIIZINKAN', label:'Port yang boleh terbuka',
      hint:'Dipisah spasi, contoh: 80 443 8000. Port SSH nggak perlu ditulis. Firewall baru dinyalakan kalau semua port yang terbuka sudah ada di sini.'},
     {key:'LEWATI_KONTROL', label:'Kontrol yang dilewati',
      hint:'Kode pemeriksaan dipisah koma, contoh: K05,K06. Kodenya ada di detail tiap pemeriksaan. Kosongkan kalau semua boleh.'},
     {key:'JAM_PENJAGAAN', label:'Jam pemindaian harian',
      hint:'Bentuk HH:MM. Langsung berlaku begitu disimpan. Pilih jam sepi.'},
     {key:'ZONA_WAKTU', label:'Zona waktu',
      hint:'Contoh: Asia/Jakarta. Dipakai untuk jam pemindaian dan semua jam di laporan.'}]},
];

// The bot points an unpaired owner at this page for the code, so it must be
// shown here - not only on an installer screen that has long scrolled away.
function telegramStatus(config) {
  if (!(config.TELEGRAM_TOKEN || {}).set) return '';
  const chat = (config.TELEGRAM_CHAT_ID || {}).value || '';
  const code = config._kode_sambung || '';
  if (chat) return `<div class="note ok status">Tersambung ke chat <code>${esc(chat)}</code>.</div>`;
  if (code) return `<div class="note wait status">Belum tersambung. Buka bot kamu di Telegram, lalu kirim sekali:
    <code>/start ${esc(code)}</code></div>`;
  return `<div class="note wait status">Belum tersambung. Kirim <code>/start</code> ke bot kamu.
    Dia akan membalas dengan chat ID yang perlu diisi di bawah.</div>`;
}

async function settingsPage(gen) {
  $('meta').textContent = 'Berlaku untuk server tempat dashboard ini dipasang.';
  $('content').innerHTML = skeleton(260, 380);

  let config = {}, failure = null;
  try {
    const r = await get('/api/config');
    if (!r.ok) throw new Error('refused');
    config = await r.json();
  } catch (e) { failure = e; }

  if (gen !== RENDER) return;   // the owner has already gone somewhere else
  if (failure) {
    $('content').innerHTML = `<div class="note bad">Setelan tidak bisa dibaca. Kalau dashboard dibuka dari
      komputer lain, muat ulang halaman ini supaya tokennya diminta.</div>`;
    return;
  }

  $('content').innerHTML = SETTINGS.map(sec => `
    <section class="set">
      <div><h2>${esc(sec.title)}</h2><p class="intro">${esc(sec.intro)}</p></div>
      <div>
        ${sec.id === 'telegram' ? telegramStatus(config) : ''}
        ${sec.fields.map(f => fieldHtml(f, config[f.key] || {})).join('')}
        <div class="form-actions"><button class="btn primary" data-save="${sec.id}">Simpan</button></div>
        <div class="note" id="note_${sec.id}"></div>
      </div>
    </section>`).join('') +
    `<div class="footnote">Berkasnya: <code>${esc(config._berkas || '')}</code>
      (root:yoru-agent 640). Kunci dashboard dan kunci model sengaja tidak bisa diubah dari sini.</div>`;

  $('content').querySelectorAll('[data-save]').forEach(btn => {
    btn.onclick = () => saveSection(SETTINGS.find(s => s.id === btn.dataset.save), btn);
  });
}

function fieldHtml(f, cur) {
  const val = f.secret ? '' : (cur.value || '');
  const mark = f.secret && cur.set ? ' · sudah terisi, kosongkan kalau tidak mau diganti' : '';
  return `<div class="field">
    <label for="f_${f.key}">${esc(f.label)}<span class="mark">${esc(mark)}</span></label>
    <input id="f_${f.key}" ${f.secret ? 'type="password" autocomplete="off"' : 'type="text"'}
           value="${esc(val)}" placeholder="${f.secret && cur.set ? '••••••••••••' : ''}">
    <div class="hint">${esc(f.hint)}</div>
  </div>`;
}

async function saveSection(sec, btn) {
  const note = $('note_' + sec.id);
  btn.disabled = true; note.className = 'note busy'; note.textContent = 'menyimpan…';
  const failed = [];
  let saved = 0, said = '';
  for (const f of sec.fields) {
    const el = $('f_' + f.key);
    const val = el.value.trim();
    // Empty secret field means "do not change", not "clear it" - otherwise
    // opening this page and pressing Save would wipe a stored token.
    if (f.secret && val === '') continue;
    const r = await post('/api/config', {key: f.key, value: val});
    let d; try { d = await r.json(); } catch (e) { d = {}; }
    if (r.ok && d.ok === true) {
      saved++;
      if (f.secret) el.value = '';
      // Schedule keys change a systemd timer too, so report what yoructl did.
      if (d.message && !/^tersimpan di /.test(d.message)) said = d.message;
    } else failed.push(`${f.label}: ${d.message || d.detail || 'ditolak'}`);
  }
  btn.disabled = false;
  if (failed.length) { note.className = 'note bad'; note.textContent = failed.join(' · '); }
  else { note.className = 'note ok';
         note.textContent = `${saved} setelan tersimpan.${said ? ' ' + said + '.' : ''}`; }
}

/* actions */
function slotSay(slot, cls, text) {
  if (!slot) return;
  slot.className = 'result ' + cls;
  slot.textContent = text;
}

// Stored, not executed here: the agent on that server collects them, so these
// work for every server in the picker.
async function decide(control, value, slot, buttons) {
  const server = (DATA.server || {}).name;
  if (!server) return;
  buttons.forEach(b => b.disabled = true);
  slotSay(slot, 'busy', 'menyimpan…');
  try {
    const r = await post('/api/decision', {server, control, value});
    const d = await r.json();
    if (r.ok && d.ok) {
      slotSay(slot, 'ok', value === 'kembalikan'
        ? 'dicatat, dikembalikan pada pemeriksaan berikutnya'
        : value === 'sah'
        ? 'dicatat sebagai perubahan yang kamu sengaja'
        : value === 'setuju'
        ? (isLocal() ? 'disetujui, tinggal jalankan' : 'disetujui, dikerjakan di server itu')
        : 'dicatat, kontrol ini tidak akan diterapkan');
      toast(value === 'setuju' ? 'Disetujui' : value === 'tolak' ? 'Dicatat, nggak akan diterapkan'
            : value === 'sah' ? 'Dicatat sebagai perubahanmu' : 'Dicatat, akan dikembalikan');
      if (value === 'setuju' && isLocal()) offerApply(control, slot);
    } else {
      slotSay(slot, 'bad', d.detail || `gagal disimpan (HTTP ${r.status})`);
      buttons.forEach(b => b.disabled = false);
    }
  } catch (e) {
    slotSay(slot, 'bad', 'API tidak bisa dihubungi');
    buttons.forEach(b => b.disabled = false);
  }
}

// An approval that leads nowhere feels like nothing happened. On this machine
// the button that finishes the job appears right where the answer was given.
function offerApply(control, slot) {
  const box = slot.closest('[data-kid]');
  const acts = box && box.querySelector('.acts');
  if (!acts || acts.querySelector('[data-a="terapkan"]')) return;
  acts.innerHTML = '';
  const go = document.createElement('button');
  go.className = 'btn primary now';
  go.dataset.a = 'terapkan';
  go.textContent = 'Amankan sekarang';
  go.onclick = () => confirmApply(control, go);
  acts.appendChild(go);
}

async function vouchPort(port, btn, slot) {
  const server = (DATA.server || {}).name;
  if (!server) return;
  btn.disabled = true;
  slotSay(slot, 'busy', `menyimpan port ${port}…`);
  try {
    const r = await post('/api/port', {server, port: [Number(port)], note: 'dijawab lewat dashboard'});
    const d = await r.json();
    if (r.ok && d.ok) {
      btn.textContent = 'sudah dicatat';
      toast(`Port ${port} dicatat sebagai milikmu`);
      slotSay(slot, 'ok', `Port ${port} dicatat sebagai milikmu. Begitu semua port terjawab, `
        + `firewall boleh dinyalakan.`);
    } else {
      slotSay(slot, 'bad', d.detail || `gagal disimpan (HTTP ${r.status})`);
      btn.disabled = false;
    }
  } catch (e) {
    slotSay(slot, 'bad', 'API tidak bisa dihubungi');
    btn.disabled = false;
  }
}

// Short confirmation at the bottom of the screen.
let toastTimer = null;
function toast(text) {
  const t = $('toast');
  t.textContent = text;
  t.classList.add('on');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('on'), 3200);
}

function wireButtons() {
  // one row per check opens its detail panel
  document.querySelectorAll('[data-open]').forEach(b => b.onclick = () => openControl(b.dataset.open));
  // the button under the headline jumps to the answers or to the checks
  document.querySelectorAll('[data-jump]').forEach(b => b.onclick = () =>
    $(b.dataset.jump).scrollIntoView({behavior: 'smooth', block: 'start'}));
  // bulk: the same dialog as one check, ten lines filling in one by one.
  document.querySelectorAll('button[data-bulk]').forEach(b => {
    b.onclick = async () => {
      const action = b.dataset.bulk;
      if (action !== 'periksa' &&
          !confirm(`${ACTION_LABEL[action]} semua pemeriksaan?\n\nYang berisiko tetap nunggu persetujuanmu.`)) return;
      b.disabled = true;
      openBulk(action);
      const asking = new Set(DATA.pending_decisions || []);
      let done = 0, held = 0, broke = 0;
      for (const k of DATA.controls || []) {
        if (action === 'terapkan' && asking.has(k.id)) {
          bulkMark(k.id, 'hold', 'butuh persetujuanmu'); held++; continue;
        }
        if (action === 'terapkan' && (k.blockers || []).length) {
          bulkMark(k.id, 'hold', 'dilewati, prasyarat belum terpenuhi'); held++; continue;
        }
        bulkMark(k.id, 'on', 'berjalan…');
        const d = await run(k.id, action, null, true);
        const ok = d && d.ok === true;
        const waiting = d && (d.status === 'DITOLAK' || d.status === 'MENUNGGU');
        bulkMark(k.id, ok ? 'done' : waiting ? 'hold' : 'fail',
                 `${statusLabel((d || {}).status || 'ERROR')}${d && d.value ? ' · ' + plain(k.id, d.value) : ''}`);
        if (ok) done++; else if (waiting) held++; else broke++;
      }
      closeBulk(done, held, broke);
      b.disabled = false;
      load(true);
    };
  });
  // drift answers and approval queue
  document.querySelectorAll('[data-drift], [data-decide]').forEach(b => {
    b.onclick = () => {
      const box = b.closest('[data-kid]');
      const kid = box.dataset.kid;
      const value = b.dataset.drift || b.dataset.decide;
      decide(kid, value, box.querySelector('[data-slot]'),
             [...box.querySelectorAll('button')]);
    };
  });
  // port vouching
  document.querySelectorAll('[data-portok]').forEach(b => {
    b.onclick = () => vouchPort(b.dataset.portok, b,
                                document.querySelector('[data-slot-port]'));
  });
}

function confirmApply(kid, btn) {
  const k = (DATA.controls || []).find(x => x.id === kid) || {};
  $('confirmTitle').textContent = k.name || kid;
  $('confirmKid').textContent = `Sekarang: ${plain(kid, k.observed)} · Harusnya: ${plain(kid, k.target)}`;
  $('confirmWhy').textContent = k.why || '';
  $('confirmRisk').textContent = k.breaks_if_applied || '(katalog belum mencantumkan konsekuensinya)';
  const d = $('dlgConfirm');
  d.onclose = () => { if (d.returnValue === 'ya') run(kid, 'terapkan', btn); };
  d.showModal();
}

// The real sequence yoructl runs for each action, in plain words.
const STEPS = {
  periksa: ['Membaca setelan yang benar-benar berlaku sekarang',
            'Membandingkan dengan yang seharusnya'],
  terapkan: ['Menyimpan cadangan setelan lama',
             'Menulis setelan baru',
             'Memuat ulang layanannya',
             'Mengecek ulang hasilnya',
             'Kalau hasilnya tidak sesuai, langsung dikembalikan'],
  kembalikan: ['Menghapus setelan buatan Yoru',
               'Memuat ulang layanannya',
               'Mengecek ulang hasilnya']
};
const ACTION_LABEL = {periksa: 'Cek ulang', terapkan: 'Amankan', kembalikan: 'Kembalikan',
                      verifikasi: 'Cek hasil'};
// What yoructl answered, in the owner's words.
const RESULT_LABEL = {LULUS: 'Aman', GAGAL: 'Belum aman', SEBAGIAN: 'Setengah jalan',
                      DILEWATI: 'Dilewati', DIKEMBALIKAN: 'Dikembalikan', DISIMPAN: 'Tersimpan',
                      DITOLAK: 'Belum bisa', MENUNGGU: 'Masih jalan', ERROR: 'Error'};
const statusLabel = s => RESULT_LABEL[s] || s;

let runTimer = null;

function openBulk(action) {
  $('runTitle').textContent = `${ACTION_LABEL[action]} semua`;
  $('runKid').textContent = 'Satu per satu. Yang berisiko tetap nunggu persetujuanmu.';
  $('runCmd').textContent = '';
  $('runCmd').hidden = true;
  $('runReply').hidden = true;
  $('runLog').hidden = true;
  $('runClose').textContent = 'Batal tampilkan';
  $('runSteps').innerHTML = (DATA.controls || []).map(k =>
    `<li data-bulk="${esc(k.id)}">${esc(k.name)} <span class="r"></span></li>`).join('');

  const started = Date.now();
  clearInterval(runTimer);
  $('runClock').textContent = 'berjalan… 0 detik';
  runTimer = setInterval(() => {
    $('runClock').textContent = `berjalan… ${Math.round((Date.now() - started) / 1000)} detik`;
  }, 1000);
  const d = $('dlgRun');
  d.onclose = null;
  if (!d.open) d.showModal();
}

function bulkMark(kid, cls, text) {
  const li = $('runSteps').querySelector(`[data-bulk="${CSS.escape(kid)}"]`);
  if (!li) return;
  li.className = cls;
  li.querySelector('.r').textContent = text ? '· ' + text : '';
  li.scrollIntoView({block: 'nearest'});
}

function closeBulk(done, held, broke) {
  clearInterval(runTimer);
  $('runClock').textContent = 'selesai';
  const box = $('runReply');
  box.className = 'reply ' + (broke ? 'bad' : held ? 'wait' : 'ok');
  box.textContent = `${done} beres` + (held ? `, ${held} nunggu atau dilewati` : '')
                                    + (broke ? `, ${broke} gagal` : '') + '.';
  box.hidden = false;
  $('runCmd').hidden = false;
  $('runClose').textContent = 'Tutup';
}

function openRun(kid, action) {
  const k = (DATA?.controls || []).find(x => x.id === kid) || {};
  $('runTitle').textContent = `${ACTION_LABEL[action] || action}: ${k.name || kid}`;
  $('runKid').textContent = k.name ? kid : '';
  $('runSteps').innerHTML = (STEPS[action] || []).map((s, i) =>
    `<li class="${i === 0 ? 'on' : ''}">${esc(s)}</li>`).join('');
  $('runCmd').textContent = `sudo yoructl ${kid} ${action}`;
  $('runCmd').hidden = false;
  $('runReply').hidden = true;
  $('runLog').hidden = true;
  $('runClose').textContent = 'Batal tampilkan';

  const started = Date.now();
  $('runClock').textContent = 'berjalan… 0 detik';
  clearInterval(runTimer);
  runTimer = setInterval(() => {
    $('runClock').textContent = `berjalan… ${Math.round((Date.now() - started) / 1000)} detik`;
  }, 1000);

  const d = $('dlgRun');
  if (!d.open) d.showModal();
}

function closeRun(kid, d) {
  clearInterval(runTimer);
  const box = $('runReply');
  const ok = d.ok === true;
  const waiting = d.status === 'DITOLAK' || d.status === 'MENUNGGU';
  box.className = 'reply ' + (ok ? 'ok' : waiting ? 'wait' : 'bad');
  box.innerHTML = `<b>${esc(statusLabel(d.status))}</b>${d.value ? ' · ' + esc(plain(kid, d.value)) : ''}` +
    (d.message ? `<br>${esc(d.message)}` : '');
  box.hidden = false;
  $('runClock').textContent = 'selesai';
  $('runSteps').querySelectorAll('li').forEach(li => li.classList.remove('on'));
  $('runClose').textContent = 'Tutup';
  $('runLog').hidden = false;
  $('dlgRun').onclose = () => {
    if ($('dlgRun').returnValue === 'log') {
      if ($('dlgCtl').open) $('dlgCtl').close();
      PAGE = 'history'; LOG_KID = kid; render();
    }
  };
}

// Works from the detail panel and from the approval cards alike: the scope is
// whatever element carries data-kid. The bulk run passes no button at all.
async function run(kid, action, btn, quiet) {
  const scope = btn ? (btn.closest('[data-kid]') || btn.parentElement) : null;
  const slot = scope && scope.querySelector('[data-slot]');
  if (scope) scope.querySelectorAll('button[data-a], button[data-decide], button[data-drift]')
    .forEach(b => b.disabled = true);
  slotSay(slot, 'busy', 'menjalankan…');
  if (!quiet) openRun(kid, action);
  let d;
  try {
    const r = await post('/api/run', {control: kid, action: action});
    d = await r.json();
    if (!r.ok) d = {status: 'DITOLAK', ok: false, message: d.detail || `HTTP ${r.status}`};
  } catch (e) { d = {status: 'ERROR', message: 'API tidak bisa dihubungi'}; }
  if (!quiet) closeRun(kid, d);

  // Three states, not two: "refused" is Yoru stopping on purpose, "error" is
  // something broken. Painting both red makes a healthy server look sick.
  const ok = d.ok === true;
  const waiting = d.status === 'DITOLAK' || d.status === 'MENUNGGU';
  slotSay(slot, ok ? 'ok' : waiting ? 'wait' : 'bad',
    `${statusLabel(d.status)}${d.value ? ' · ' + plain(kid, d.value) : ''}${d.message ? ' · ' + d.message : ''}`);
  if (scope && isLocal()) scope.querySelectorAll('button[data-a], button[data-decide], button[data-drift]')
    .forEach(b => { if (!(b.dataset.a === 'terapkan' && b.title)) b.disabled = false; });
  // After Cek ulang too, so a check that now passes moves the score.
  if (ok && !quiet) setTimeout(() => load(true), 600);
  return d;
}

/* boot */
$('nav').onclick = e => {
  const a = e.target.closest('[data-h]'); if (!a) return;
  PAGE = a.dataset.h;
  if (PAGE === 'history') LOG_KID = null;   // the menu means "all controls"
  render();
};

// The daily check time, shown in the hero. Read quietly: a page opened from
// another machine without a token simply leaves it out, it never asks for one.
let SCHEDULE = '';
async function loadSchedule() {
  try {
    const r = await fetch('/api/config', {headers: TOKEN ? {Authorization: 'Bearer ' + TOKEN} : {}});
    if (r.ok) SCHEDULE = (((await r.json()).JAM_PENJAGAAN || {}).value || '').trim();
  } catch (e) { /* no schedule line, nothing else changes */ }
}

$('pageHead').hidden = true;
$('content').innerHTML = skeleton(220, 160, 420);
(async () => { await loadServers(); await loadSchedule(); await load(true); })();

// The newest line of the action trail, under the headline, so the page shows
// what Yoru did last. One line, one request - a full log on a loop would be noise.
async function beat() {
  const el = $('lastAct'); if (!el) return;
  try {
    const r = await get('/api/log?limit=1');
    if (!r.ok) return;
    const b = ((await r.json()).lines || [])[0];
    if (!b) return;
    const k = ((DATA && DATA.controls) || []).find(x => x.id === b.id);
    el.querySelector('dd').innerHTML = `${esc(ACTION_LABEL[b.action] || b.action || '')}
      ${esc(k ? k.name : b.id || '')} · ${esc(statusLabel(b.status || ''))} ·
      <span data-ago="${esc(b.time)}">${ago(b.time)}</span>`;
    el.hidden = false;
  } catch (e) { /* the line stays hidden; nothing else depends on it */ }
}

function watchLive() {
  clearInterval(liveTimer);
  if (PAGE !== 'dashboard') return;
  beat();
  liveTimer = setInterval(() => { beat(); tickTimes(); }, 15000);
}

// Only live-state pages auto-refresh; reloading a form would discard typing.
setInterval(() => {
  if (PAGE === 'dashboard') load();
}, 30000);
