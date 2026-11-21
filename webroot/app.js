// USB Manager WebUI - @Dev_DcS
// Talks to bin/usbctl through the KernelSU-style `ksu` bridge, which
// KernelSU, KSU Next, SukiSU, APatch, WebUI X and KsuWebUIStandalone all expose.

(() => {
  'use strict';

  const MODID = 'usbmanager_dcs';
  let modDir = `/data/adb/modules/${MODID}`;
  try {
    const info = JSON.parse(window.ksu.moduleInfo());
    if (info && info.moduleDir) modDir = info.moduleDir;
  } catch (_) { /* older hosts don't have moduleInfo */ }

  const MODES = [
    { id: 'charging', name: 'Charge only', sub: 'No data, just power', icon: 'bolt' },
    { id: 'mtp', name: 'File transfer', sub: 'MTP', icon: 'folder' },
    { id: 'ptp', name: 'Photos', sub: 'PTP', icon: 'image' },
    { id: 'rndis', name: 'USB tethering', sub: 'RNDIS', icon: 'net' },
    { id: 'midi', name: 'MIDI', sub: 'Instruments, DAWs', icon: 'music' },
    { id: 'keep', name: "Android's choice", sub: 'Cars, docks, Android Auto', icon: 'car' },
  ];

  const ICONS = {
    usb: '<path d="M12 3v13"/><path d="m9 6 3-3 3 3"/><path d="M12 13 7 10V8"/><path d="m12 15 5-3V9"/><rect x="5.5" y="6" width="3" height="2.5" rx=".5"/><circle cx="17" cy="8" r="1.4"/><circle cx="12" cy="19" r="2"/>',
    bolt: '<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>',
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    image: '<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="15.5" cy="9.5" r="1.5"/><path d="m4 17 5-5 4 4 2-2 4 4"/>',
    net: '<circle cx="12" cy="5" r="2"/><circle cx="5" cy="19" r="2"/><circle cx="19" cy="19" r="2"/><path d="M12 7v5M12 12l-5.5 5.5M12 12l5.5 5.5"/>',
    music: '<path d="M9 18V6l10-2v12"/><circle cx="7" cy="18" r="2"/><circle cx="17" cy="16" r="2"/>',
    host: '<rect x="7" y="3" width="10" height="7" rx="1.5"/><path d="M12 10v6"/><circle cx="12" cy="19" r="2.5"/>',
    off: '<path d="M7 7h10v6a5 5 0 0 1-10 0z"/><path d="M10 7V3M14 7V3M12 18v3"/>',
    car: '<path d="M5 13l1.6-4.6A2 2 0 0 1 8.5 7h7a2 2 0 0 1 1.9 1.4L19 13"/><rect x="3" y="13" width="18" height="5" rx="1.5"/><circle cx="7.5" cy="18.5" r="1.5"/><circle cx="16.5" cy="18.5" r="1.5"/>',
    swap: '<path d="M7 4v16M7 20l-3-3M7 20l3-3M17 20V4M17 4l-3 3M17 4l3 3"/>',
  };

  const svg = (name) =>
    `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">${ICONS[name] || ''}</svg>`;

  const $ = (sel) => document.querySelector(sel);
  const $$ = (sel) => Array.from(document.querySelectorAll(sel));

  const esc = (s) => String(s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // ---- bridge ---------------------------------------------------------------

  let cbSeq = 0;
  function exec(cmd) {
    return new Promise((resolve) => {
      if (!window.ksu || typeof window.ksu.exec !== 'function') {
        resolve({ errno: -1, stdout: '', stderr: 'no ksu bridge' });
        return;
      }
      const cb = `__usbmgr_cb_${Date.now()}_${cbSeq++}`;
      window[cb] = (errno, stdout, stderr) => {
        delete window[cb];
        resolve({ errno, stdout: stdout || '', stderr: stderr || '' });
      };
      try {
        window.ksu.exec(cmd, '{}', cb);
      } catch (e) {
        delete window[cb];
        resolve({ errno: -1, stdout: '', stderr: String(e) });
      }
    });
  }

  // args are always things we validated or picked from a fixed list,
  // but quote them anyway
  const q = (s) => `'${String(s).replace(/'/g, '')}'`;

  async function ctl(...args) {
    const r = await exec(`sh ${q(modDir + '/bin/usbctl')} ${args.map(q).join(' ')}`);
    return r;
  }

  async function ctlJson(...args) {
    const r = await ctl(...args);
    try {
      return JSON.parse(r.stdout.trim().split('\n').pop());
    } catch (_) {
      return { ok: false, error: (r.stderr || r.stdout || 'no output').trim() };
    }
  }

  let snackTimer;
  function toast(msg) {
    const el = $('#snack');
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(snackTimer);
    snackTimer = setTimeout(() => el.classList.remove('show'), 2400);
  }

  // small promise-based confirm, WebView's own confirm() isn't wired up in every host
  function ask(title, text, okLabel = 'OK') {
    return new Promise((resolve) => {
      $('#ask-title').textContent = title;
      $('#ask-text').textContent = text;
      $('#ask-yes').textContent = okLabel;
      $('#ask').hidden = false;
      const done = (v) => {
        $('#ask').hidden = true;
        $('#ask-yes').onclick = null;
        $('#ask-no').onclick = null;
        resolve(v);
      };
      $('#ask-yes').onclick = () => done(true);
      $('#ask-no').onclick = () => done(false);
    });
  }

  // ---- state ----------------------------------------------------------------

  let status = null;
  let config = null;
  let openedForPrompt = false;
  let chooserSid = 0;
  let ignoreSid = 0; // "Not now" on this session, don't pop it again
  let choice = { mode: 'charging', adb: false };
  let live = { mode: 'charging', adb: false, touched: false };
  let busy = false;

  const modeName = (id) => (MODES.find((m) => m.id === id) || { name: id }).name;

  // ---- status ---------------------------------------------------------------

  function renderStatus() {
    const s = status;
    if (!s || !s.ok) {
      $('#conn-title').textContent = 'Could not reach usbctl';
      $('#conn-sub').textContent = (s && s.error) || 'Is the module enabled and root granted?';
      $('#daemon-pill').className = 'pill bad';
      $('#daemon-pill').textContent = 'error';
      return;
    }

    const pill = $('#daemon-pill');
    pill.className = 'pill ' + (s.daemon ? 'ok' : 'bad');
    pill.textContent = s.daemon ? 'running' : 'stopped';

    let title, sub, icon;
    if (s.block !== 'off') {
      title = 'USB data blocked'; sub = 'Charging only'; icon = 'off';
    } else if (!s.enabled) {
      title = 'Chooser off'; sub = 'USB mode is left to Android'; icon = 'off';
    } else if (s.cable === 'pc') {
      title = 'Connected to a computer'; sub = `${modeName(s.functions)} · ADB ${s.adb ? 'on' : 'off'}`; icon = 'usb';
    } else if (s.cable === 'host') {
      title = 'USB host (OTG)'; sub = 'Left to Android, no prompt'; icon = 'host';
    } else {
      title = 'Not connected'; sub = 'Plug into a computer to get the chooser'; icon = 'usb';
    }
    $('#conn-title').textContent = title;
    $('#conn-sub').textContent = sub;
    $('#conn-icon').innerHTML = svg(icon);

    $('#st-mode').textContent = modeName(s.functions);
    $('#st-adb').textContent = s.adb ? 'On' : 'Off';
    const sessText = {
      none: '-', pending: 'Waiting for you', answered: 'Answered',
      auto: 'Default applied', dnd: 'Game mode',
      waiting: 'Remembered, waits for unlock', remembered: 'Repeated last choice',
    };
    $('#st-session').textContent = sessText[s.session.state] || s.session.state;
    const peers = s.peers || [];
    $('#st-peer').textContent = peers.length
      ? peers.map((p) => `${p.label}${p.trusted ? ' (trusted)' : ''}`).join(', ')
      : '-';

    const idle = s.idle || {};
    $('#st-idle').textContent = !idle.enabled ? 'Off'
      : idle.left < 0 ? 'Waiting for first unlock'
        : s.locked === 'true' ? `in ${dur(idle.left)}`
          : `${dur(idle.left)} after lock`;

    const g = s.guard || {};
    $('#guard-banner').hidden = !g.armed;
    if (g.armed) {
      $('#guard-banner-text').textContent = g.action === 'test'
        ? `Test mode: ${g.left}s left, nothing will restart.`
        : `The phone restarts in ${g.left}s unless it's unlocked.`;
    }
    const how = s.block_how === 'kernel' ? ' Enforced by the kernel.' : ' Userspace fallback.';
    $('#block-banner').hidden = s.block === 'off';
    const why = {
      guard: 'Cut by the USB guard until the phone is unlocked.',
      charge: 'Charge only for this connection. Unplug, or pick a mode below to use data.',
    };
    $('#block-banner-text').textContent = (why[s.block] || 'Charging only. Turn it off under Security.') + how;

    // the two switches from the dev-dcs kernel patches
    const k = s.kernel || {};
    const gadgetK = k.deny_usb_gadget && k.deny_usb_gadget !== 'absent';
    const hostK = k.deny_new_usb && k.deny_new_usb !== 'absent';
    $('#st-kgate').textContent = gadgetK && hostK ? 'both present'
      : gadgetK || hostK ? `only ${gadgetK ? 'deny_usb_gadget' : 'deny_new_usb'}` : 'not in this kernel';
    $('#kgate-hint').textContent = gadgetK && hostK
      ? 'Kernel switches found (deny_usb_gadget + deny_new_usb): the block and the guard cut-off happen '
        + 'in the kernel, so there is no gap. Devices refused while blocked need a replug afterwards.'
      : 'This kernel has no USB switches, so the block runs in userspace. If Android re-binds USB on its '
        + 'own, a computer can see the phone for up to about a second before it gets cut again.';
    $('#st-backend').textContent = s.backend;
    $('#st-root').textContent = s.root;
    $('#st-host').textContent = s.host || 'none found';
    $('#st-sdk').textContent = s.sdk;
    $('#st-ver').textContent = s.version;

    if (!live.touched) {
      live.mode = MODES.some((m) => m.id === s.functions) ? s.functions : 'charging';
      live.adb = !!s.adb;
      renderLive();
    }
  }

  function renderLive() {
    $('#live-modes').innerHTML = MODES.map((m) =>
      `<button class="chip${m.id === live.mode ? ' on' : ''}" data-mode="${m.id}">${esc(m.name)}</button>`).join('');
    $('#live-adb').checked = live.adb;
  }

  async function refreshStatus() {
    status = await ctlJson('status');
    renderStatus();
    syncChooser();
  }

  // ---- chooser --------------------------------------------------------------

  let lastState = null;
  function syncChooser() {
    if (!status || !status.ok) return;
    const st = status.session.state;
    const sid = status.session.id;
    const pending = st === 'pending';
    const shown = !$('#chooser').hidden;
    // after "Not now" the daemon may still say pending for one poll, skip that one.
    // A fresh pending (action button, new plug-in) always opens it again.
    const justDismissed = sid === ignoreSid && lastState === 'pending';
    if (pending && !shown && !justDismissed) openChooser(sid);
    if (shown && (!pending || sid !== chooserSid) && !busy) closeChooser();
    lastState = st;
  }

  const pcPeers = () => ((status && status.peers) || []).filter((p) => p.fp.startsWith('pc:'));

  function chooserStep(n) {
    $('#ch-step1').hidden = n !== 1;
    $('#ch-step2').hidden = n !== 2;
  }

  function openChooser(sid) {
    chooserSid = sid;
    choice.mode = (config && config.default_mode) || 'keep';
    // step 1 already covers "charge only", step 2 is about what data is for
    if (choice.mode === 'charging') choice.mode = 'keep';
    choice.adb = !!(config && config.default_adb);
    $('#ch-default').checked = false;
    const pc = pcPeers()[0];
    $('#ch-peer').textContent = pc ? pc.label.replace(/, data blocked$/, '') : '';
    const hours = Number((config && config.remember_hours) || 0);
    $('#ch-remember').textContent = hours
      ? `The answer is remembered for this device until it has been unplugged for ${hours} h.`
      : 'Answers aren\'t remembered (Settings → Remembered devices).';
    const unknown = pcPeers().filter((p) => !p.trusted);
    const guardOn = !!(status && status.guard && status.guard.enabled);
    $('#ch-trust').checked = false;
    $('#ch-trust-row').hidden = unknown.length === 0 || !guardOn;
    if (unknown.length) {
      $('#ch-trust-hint').textContent = unknown[0].strength === 'generic'
        ? 'This computer has no readable ID, so any computer with the same port type would count as trusted.'
        : 'Identified by its USB-PD vendor/product ID (same model = same ID).';
    }
    renderChooser();
    chooserStep(1);
    $('#chooser').hidden = false;
  }

  function closeChooser() {
    $('#chooser').hidden = true;
  }

  function renderChooser() {
    $('#ch-badge').innerHTML = svg('usb');
    $('#ch-data-icon').innerHTML = svg('swap');
    $('#ch-charge-icon').innerHTML = svg('bolt');
    $('#ch-modes').innerHTML = MODES.filter((m) => m.id !== 'charging').map((m) => `
      <button class="mode${m.id === choice.mode ? ' on' : ''}" data-mode="${m.id}">
        ${svg(m.icon)}<span><b>${esc(m.name)}</b><small>${esc(m.sub)}</small></span>
      </button>`).join('');
    $('#ch-adb').checked = choice.adb;
  }

  // leave the WebUI after answering, but only if it was opened for the prompt
  function leave() {
    if (!openedForPrompt) return;
    if (window.ksu && typeof window.ksu.exit === 'function') {
      window.ksu.exit();
    } else {
      exec('input keyevent 4');
    }
  }

  async function answer() {
    if (busy) return;
    busy = true;
    $('#ch-ok').disabled = true;
    const r = await ctlJson('choose', choice.mode, choice.adb ? '1' : '0',
      $('#ch-default').checked ? 'default' : '');
    busy = false;
    $('#ch-ok').disabled = false;
    if (!r.ok) {
      toast(r.error || 'Something went wrong');
      return;
    }
    await trustIfAsked();
    closeChooser();
    toast(`${modeName(choice.mode)}, ADB ${choice.adb ? 'on' : 'off'}`);
    if ($('#ch-default').checked) loadConfig();
    loadMem();
    setTimeout(leave, 350);
    refreshStatus();
  }

  async function trustIfAsked() {
    if (!$('#ch-trust').checked) return;
    for (const p of pcPeers().filter((x) => !x.trusted)) {
      await ctlJson('trust', p.fp, p.strength, p.label.replace(/, data blocked$/, ''));
    }
  }

  async function chargeOnly() {
    if (busy) return;
    busy = true;
    const r = await ctlJson('charge-only');
    busy = false;
    if (!r.ok) {
      toast(r.error || 'Something went wrong');
      return;
    }
    await trustIfAsked();
    closeChooser();
    toast('Charge only, data cut until unplugged');
    loadMem();
    setTimeout(leave, 350);
    refreshStatus();
  }

  async function notNow() {
    ignoreSid = chooserSid;
    closeChooser();
    await ctlJson('dismiss');
    leave();
    refreshStatus();
  }

  // ---- settings -------------------------------------------------------------

  function renderConfig() {
    if (!config || !config.ok) return;
    $$('[data-key]').forEach((el) => {
      const v = config[el.dataset.key];
      if (el.type === 'checkbox') el.checked = !!v;
      else el.value = v;
    });
    $('#ui-host').value = config.ui_host === 'auto' ? '' : config.ui_host;
    renderDnd();
  }

  async function loadConfig() {
    config = await ctlJson('config');
    renderConfig();
    loadMem();
  }

  const dur = (sec) => {
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    return h ? `${h}h ${m}m` : `${m}m`;
  };

  let remembered = [];
  async function loadMem() {
    const r = await ctl('remembered');
    try { remembered = JSON.parse(r.stdout.trim()); } catch (_) { remembered = []; }
    $('#mem-empty').hidden = remembered.length > 0;
    $('#mem-list').innerHTML = remembered.map((m) => {
      const what = m.decision === 'charge' ? 'Charge only'
        : `Data · ${modeName(m.mode)}, ADB ${m.adb ? 'on' : 'off'}`;
      const left = m.left > 0 ? tag([`${dur(m.left)} left`, 'ok']) : tag(['expired, will ask', '']);
      return `<li><span class="name">${esc(m.label || m.fp)}<small>${esc(what)}</small>
        <span class="meta">${left}</span></span>
        <button class="btn" data-forget="${esc(m.fp)}">Forget</button></li>`;
    }).join('');
  }

  async function setKey(key, value) {
    const r = await ctlJson('set', key, value);
    if (!r.ok) {
      toast(r.error || 'Not saved');
      loadConfig();
      return false;
    }
    config[key] = value === '1' ? true : value === '0' ? false : value;
    return true;
  }

  // ---- game mode apps -------------------------------------------------------

  let allApps = null; // [{pkg, label}]
  const labels = {};

  function appLabel(pkg) {
    return labels[pkg] || pkg;
  }

  function renderDnd() {
    const list = (config && config.dnd_apps) || [];
    $('#dnd-empty').hidden = list.length > 0;
    $('#dnd-list').innerHTML = list.map((p) => `
      <li><span class="name">${esc(appLabel(p))}<small>${esc(p)}</small></span>
      <button class="btn" data-del="${esc(p)}">Remove</button></li>`).join('');
    renderAppList();
  }

  function renderAppList() {
    if (!allApps) return;
    const term = $('#app-search').value.trim().toLowerCase();
    const chosen = new Set((config && config.dnd_apps) || []);
    const rows = allApps
      .filter((a) => !chosen.has(a.pkg))
      .filter((a) => !term || a.pkg.toLowerCase().includes(term) || a.label.toLowerCase().includes(term))
      .slice(0, 150);
    $('#app-list').innerHTML = rows.map((a) => `
      <li><span class="name">${esc(a.label)}<small>${esc(a.pkg)}</small></span>
      <button class="btn" data-add="${esc(a.pkg)}">Add</button></li>`).join('');
  }

  async function loadApps() {
    const btn = $('#app-load');
    btn.disabled = true;
    btn.textContent = 'Loading…';
    const r = await ctl('packages');
    let pkgs = [];
    try { pkgs = JSON.parse(r.stdout.trim()); } catch (_) { /* leave empty */ }

    // nicer names where the host can give them to us
    if (window.ksu && typeof window.ksu.getPackagesInfo === 'function' && pkgs.length) {
      try {
        const info = JSON.parse(window.ksu.getPackagesInfo(JSON.stringify(pkgs)));
        info.forEach((i) => { if (i.appLabel) labels[i.packageName] = i.appLabel; });
      } catch (_) { /* fine, package names it is */ }
    }

    allApps = pkgs.map((p) => ({ pkg: p, label: appLabel(p) }))
      .sort((a, b) => a.label.localeCompare(b.label));
    btn.hidden = true;
    renderDnd();
  }

  // ---- security -------------------------------------------------------------

  const RESULTS = {
    trusted: ['trusted', 'ok'],
    open: ['unlocked at connect', 'ok'],
    unlocked: ['unlocked in time', 'ok'],
    armed: ['counting down', 'bad'],
    rebooted: ['phone restarted', 'bad'],
    test: ['test: would restart', 'warn'],
    unplugged: ['unplugged in time', 'warn'],
    cancelled: ['guard turned off', 'warn'],
    bfu: ['before first unlock', ''],
    logged: ['guard off', ''],
    blocked: ['blocked', 'warn'],
    active: ['connected', ''],
    interrupted: ['daemon restarted', 'warn'],
  };
  const STRENGTH = {
    unique: ['unique ID', 'ok'],
    model: ['model ID', ''],
    generic: ['generic', 'warn'],
  };
  const tag = ([text, cls]) => `<span class="tag ${cls}">${esc(text)}</span>`;

  let history = [];
  let trusted = [];

  function fmtTime(t) {
    const d = new Date(t * 1000);
    const today = new Date();
    const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return d.toDateString() === today.toDateString()
      ? time
      : `${d.toLocaleDateString([], { month: 'short', day: 'numeric' })} ${time}`;
  }

  function renderSecurity() {
    $('#trust-empty').hidden = trusted.length > 0;
    $('#trust-list').innerHTML = trusted.map((t) => `
      <li><span class="name">${esc(t.label)}<small>${esc(t.fp)}</small>
        <span class="meta">${tag(STRENGTH[t.strength] || [t.strength, ''])}</span></span>
      <button class="btn" data-untrust="${esc(t.fp)}">Remove</button></li>`).join('');

    $('#hist-empty').hidden = history.length > 0;
    $('#hist-list').innerHTML = history.map((h, i) => `
      <li><span class="name">${esc(h.label)}<small>${fmtTime(h.t)} · ${esc(h.fp)}</small>
        <span class="meta">${tag(RESULTS[h.result] || [h.result, ''])}${tag(STRENGTH[h.strength] || [h.strength, ''])}</span></span>
      ${h.trusted ? '<span class="tag ok">trusted</span>'
    : `<button class="btn" data-trust="${i}">Trust</button>`}</li>`).join('');
  }

  async function loadSecurity() {
    const [h, t] = await Promise.all([ctl('history', '150'), ctl('trusted')]);
    try { history = JSON.parse(h.stdout.trim()); } catch (_) { history = []; }
    try { trusted = JSON.parse(t.stdout.trim()); } catch (_) { trusted = []; }
    renderSecurity();
  }

  async function trustEntry(h) {
    if (h.strength === 'generic') {
      const ok = await ask('Trust a generic fingerprint?',
        'This computer gave no readable ID, so the fingerprint only describes the kind of port '
        + `(${h.fp}).\n\nAny other computer with the same port type would be trusted too, `
        + 'and the guard would not restart for it.', 'Trust anyway');
      if (!ok) return;
    }
    const r = await ctlJson('trust', h.fp, h.strength, h.label);
    if (!r.ok) toast(r.error || 'Failed');
    loadSecurity();
  }

  // ---- log ------------------------------------------------------------------

  async function loadLog() {
    const r = await ctl('log', '300');
    const box = $('#log-box');
    box.textContent = r.stdout.trim() || 'Log is empty.';
    box.scrollTop = box.scrollHeight;
  }

  // ---- wiring ---------------------------------------------------------------

  function showView(name) {
    $$('.view').forEach((v) => v.classList.toggle('active', v.id === `view-${name}`));
    $$('.tabs button').forEach((b) => b.classList.toggle('on', b.dataset.view === name));
    if (name === 'log') loadLog();
    if (name === 'security') loadSecurity();
    if (name === 'settings') loadMem();
    if (name === 'status') { live.touched = false; refreshStatus(); }
  }

  function wire() {
    $$('.tabs button').forEach((b) => b.addEventListener('click', () => showView(b.dataset.view)));

    $('#ch-modes').addEventListener('click', (e) => {
      const b = e.target.closest('[data-mode]');
      if (!b) return;
      choice.mode = b.dataset.mode;
      renderChooser();
    });
    $('#ch-adb').addEventListener('change', (e) => { choice.adb = e.target.checked; });
    $('#ch-ok').addEventListener('click', answer);
    $('#ch-later').addEventListener('click', notNow);
    $('#ch-data').addEventListener('click', () => { renderChooser(); chooserStep(2); });
    $('#ch-back').addEventListener('click', () => chooserStep(1));
    $('#ch-charge').addEventListener('click', chargeOnly);
    $('#mem-list').addEventListener('click', async (e) => {
      const b = e.target.closest('[data-forget]');
      if (!b) return;
      await ctlJson('forget', b.dataset.forget);
      loadMem();
    });

    $('#live-modes').addEventListener('click', (e) => {
      const b = e.target.closest('[data-mode]');
      if (!b) return;
      live.mode = b.dataset.mode;
      live.touched = true;
      renderLive();
    });
    $('#live-adb').addEventListener('change', (e) => { live.adb = e.target.checked; live.touched = true; });
    $('#live-apply').addEventListener('click', async () => {
      const btn = $('#live-apply');
      btn.disabled = true;
      $('#live-result').textContent = 'Applying, the computer will see a quick reconnect…';
      const r = await ctlJson('apply', live.mode, live.adb ? '1' : '0');
      btn.disabled = false;
      if (!r.ok) $('#live-result').textContent = r.error || 'Failed';
      else if (r.verified) $('#live-result').textContent = 'Done, Android confirmed it.';
      else $('#live-result').textContent = `Sent, but Android still reports ${modeName(r.functions)} / ADB ${r.adb ? 'on' : 'off'}.`;
      live.touched = false;
      refreshStatus();
    });

    const CONFIRM = {
      block: ['Block all USB data?',
        'Computers won\'t see the phone at all, USB sticks, keyboards and docks stop working and ADB is '
        + 'switched off. Charging keeps working.\n\nStays on after a reboot until you switch it off here.',
        'Block'],
      idle: ['Turn on auto restart?',
        'The phone restarts on its own when it hasn\'t been unlocked for the time you pick. Unsaved work '
        + 'in open apps is lost, and until you unlock after the restart most apps can\'t run, so their '
        + 'notifications wait.\n\nCalls in progress postpone it.',
        'Turn on'],
      guard: ['Turn on the USB guard?',
        'If an unknown USB device gets connected while the phone is locked and nobody unlocks it in time, '
        + 'the phone restarts. Unsaved work in open apps is lost.\n\nTrusted devices never trigger it. '
        + 'Not sure? Pick "Test mode" first and see what it would do.',
        'Turn on'],
    };

    $$('[data-key]').forEach((el) => el.addEventListener('change', async () => {
      const key = el.dataset.key;
      const val = el.type === 'checkbox' ? (el.checked ? '1' : '0') : el.value;
      const c = CONFIRM[el.dataset.confirm];
      if (c && val === '1' && !(await ask(...c))) {
        el.checked = false;
        return;
      }
      if (await setKey(key, val)) {
        toast('Saved');
        if (['enabled', 'block', 'guard', 'idle_reboot', 'idle_minutes'].includes(key)) setTimeout(refreshStatus, 1200);
      }
    }));

    $('#ui-host-save').addEventListener('click', async () => {
      const v = $('#ui-host').value.trim() || 'auto';
      if (v !== 'auto' && !/^[A-Za-z0-9_.]+\/[A-Za-z0-9_.]+$/.test(v)) {
        toast('Use package/.Activity');
        return;
      }
      if (await setKey('ui_host', v)) toast('Saved');
    });

    $('#restart').addEventListener('click', async () => {
      const r = await ctlJson('restart');
      toast(r.ok ? `Daemon restarted (pid ${r.pid})` : (r.error || 'Restart failed'));
      refreshStatus();
    });

    $('#app-load').addEventListener('click', loadApps);
    $('#app-search').addEventListener('input', () => {
      if (!allApps) loadApps(); else renderAppList();
    });
    $('#app-list').addEventListener('click', async (e) => {
      const b = e.target.closest('[data-add]');
      if (!b) return;
      const r = await ctlJson('dnd', 'add', b.dataset.add);
      if (r.ok) loadConfig(); else toast(r.error || 'Failed');
    });
    $('#dnd-list').addEventListener('click', async (e) => {
      const b = e.target.closest('[data-del]');
      if (!b) return;
      const r = await ctlJson('dnd', 'del', b.dataset.del);
      if (r.ok) loadConfig(); else toast(r.error || 'Failed');
    });

    $('#hist-list').addEventListener('click', (e) => {
      const b = e.target.closest('[data-trust]');
      if (b) trustEntry(history[Number(b.dataset.trust)]);
    });
    $('#trust-list').addEventListener('click', async (e) => {
      const b = e.target.closest('[data-untrust]');
      if (!b) return;
      if (!(await ask('Remove from trusted?', 'The guard will treat it as unknown again.', 'Remove'))) return;
      await ctlJson('untrust', b.dataset.untrust);
      loadSecurity();
    });
    $('#hist-clear').addEventListener('click', async () => {
      if (!(await ask('Clear history?', 'Trusted devices are kept.', 'Clear'))) return;
      await ctlJson('history-clear');
      loadSecurity();
    });

    $('#log-refresh').addEventListener('click', loadLog);
    $('#log-clear').addEventListener('click', async () => {
      await ctl('log-clear');
      loadLog();
    });

    // a couple of seconds is plenty, each poll spawns a root shell
    let polls = 0;
    setInterval(() => {
      if (document.visibilityState !== 'visible') return;
      refreshStatus();
      if ($('#view-security').classList.contains('active') && ++polls % 3 === 0) loadSecurity();
    }, 2000);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') refreshStatus();
    });
  }

  async function init() {
    $('#default-mode').innerHTML = MODES.map((m) =>
      `<option value="${m.id}">${esc(m.name)}</option>`).join('');
    wire();
    renderLive();
    if (!window.ksu) {
      $('#conn-title').textContent = 'No WebUI bridge';
      $('#conn-sub').textContent = 'Open this from KernelSU, APatch, WebUI X or KsuWebUIStandalone.';
      return;
    }
    await loadConfig();
    status = await ctlJson('status');
    openedForPrompt = !!(status.ok && status.session.state === 'pending');
    renderStatus();
    syncChooser();
  }

  init();
})();
