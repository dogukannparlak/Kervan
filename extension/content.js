// IDM benzeri video üstü düğme: sayfadaki her görünür <video>'nun sağ üst köşesinde "İndir" düğmesi.
// Tıklanınca arka plandan seçenekler (yakalanan akışlar + "sayfadan indir") istenir; tek seçenek varsa
// doğrudan kuyruğa eklenir. Sayfa CSS'inden etkilenmemek için kapalı Shadow DOM kullanılır.
(() => {
  if (globalThis.__kervanOverlay) return;

  const MIN_WIDTH = 240;
  const MIN_HEIGHT = 135;
  const tracked = new Map(); // video → { button, dismissed }
  let enabled = true;
  let openMenu = null;

  const host = document.createElement('kervan-overlay');
  host.style.cssText = 'all:initial;position:fixed;top:0;left:0;width:0;height:0;z-index:2147483647;pointer-events:none;';
  const shadow = host.attachShadow({ mode: 'closed' });
  shadow.innerHTML = `<style>
    :host { all: initial; }
    * { box-sizing: border-box; font: 12px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    .button {
      position: fixed; top: 0; left: 0; display: none; align-items: center; gap: 6px;
      padding: 5px 8px 5px 6px; border-radius: 7px; border: 0; cursor: pointer; pointer-events: auto;
      background: rgba(20, 20, 22, .78); color: #fff; box-shadow: 0 2px 10px rgba(0,0,0,.35);
      backdrop-filter: blur(6px); opacity: .9; transition: opacity .15s ease, background-color .15s ease;
      white-space: nowrap;
    }
    .button:hover { opacity: 1; background: rgba(20, 20, 22, .92); }
    .logo { width: 16px; height: 16px; border-radius: 4px; background: #e8833a; color: #fff;
      display: grid; place-items: center; font-weight: 700; font-size: 11px; }
    .close { margin-left: 2px; padding: 0 3px; border-radius: 4px; color: rgba(255,255,255,.6); }
    .close:hover { color: #fff; background: rgba(255,255,255,.15); }
    .menu {
      position: fixed; min-width: 240px; max-width: 360px; pointer-events: auto; padding: 4px;
      background: #fff; color: #1d1d1f; border-radius: 9px; box-shadow: 0 8px 28px rgba(0,0,0,.3);
    }
    .menu .head { padding: 6px 8px 4px; color: #6e6e73; font-size: 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .menu { max-height: 70vh; overflow-y: auto; }
    .menu button { all: unset; display: block; width: 100%; padding: 7px 8px; border-radius: 6px; cursor: pointer; box-sizing: border-box; }
    .menu button:hover, .menu button:focus-visible { background: #f2f2f5; }
    .menu .label { font-weight: 600; }
    .menu .detail { color: #6e6e73; font-size: 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .menu .status { padding: 7px 8px; }
    .menu .error { color: #c4352b; }
    @media (prefers-color-scheme: dark) {
      .menu { background: #2c2c2e; color: #f5f5f7; }
      .menu button:hover, .menu button:focus-visible { background: #3a3a3c; }
      .menu .head, .menu .detail { color: #98989d; }
      .menu .error { color: #ff6b5e; }
    }
  </style>`;

  function mountHost() {
    const parent = document.fullscreenElement || document.documentElement;
    if (parent && host.parentNode !== parent) parent.appendChild(host);
  }

  function track(video) {
    if (tracked.has(video)) return;
    const button = document.createElement('button');
    button.className = 'button';
    button.title = 'Kervan ile indir';
    button.innerHTML = '<span class="logo">K</span><span class="text">İndir</span><span class="close" title="Bu video için gizle">×</span>';
    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (event.target.classList.contains('close')) {
        tracked.get(video).dismissed = true;
        closeMenu();
        layout();
        return;
      }
      openMenu?.anchor === button ? closeMenu() : showMenu(video, button);
    });
    shadow.appendChild(button);
    tracked.set(video, { button, dismissed: false });
    layout();
  }

  function scan() {
    document.querySelectorAll('video').forEach(track);
  }

  function layout() {
    mountHost();
    for (const [video, entry] of tracked) {
      if (!video.isConnected) {
        entry.button.remove();
        tracked.delete(video);
        continue;
      }
      const rect = video.getBoundingClientRect();
      const visible = enabled && !entry.dismissed && rect.width >= MIN_WIDTH && rect.height >= MIN_HEIGHT
        && rect.bottom > 40 && rect.top < innerHeight - 40 && rect.right > 0 && rect.left < innerWidth
        && getComputedStyle(video).visibility !== 'hidden';
      entry.button.style.display = visible ? 'flex' : 'none';
      if (!visible) continue;
      entry.button.querySelector('.text').textContent = rect.width >= 360 ? 'Bu videoyu indir' : 'İndir';
      const top = Math.max(rect.top, 0) + 10;
      const right = Math.min(rect.right, innerWidth) - 10;
      entry.button.style.transform = `translate(${Math.round(right)}px, ${Math.round(top)}px) translateX(-100%)`;
    }
    if (openMenu) positionMenu();
  }

  // --- Menü ---

  function closeMenu() {
    openMenu?.element.remove();
    openMenu = null;
  }

  function positionMenu() {
    const rect = openMenu.anchor.getBoundingClientRect();
    if (openMenu.anchor.style.display === 'none') return closeMenu();
    const menu = openMenu.element;
    const left = Math.max(8, Math.min(rect.right - menu.offsetWidth, innerWidth - menu.offsetWidth - 8));
    menu.style.transform = `translate(${Math.round(left)}px, ${Math.round(rect.bottom + 6)}px)`;
  }

  function menuShell(button, head) {
    closeMenu();
    const element = document.createElement('div');
    element.className = 'menu';
    element.setAttribute('role', 'menu');
    const header = document.createElement('div');
    header.className = 'head';
    header.textContent = head;
    element.append(header);
    shadow.appendChild(element);
    openMenu = { element, anchor: button };
    positionMenu();
    return element;
  }

  function status(menu, text, isError = false) {
    menu.querySelectorAll('.status, button').forEach((node) => node.remove());
    const line = document.createElement('div');
    line.className = isError ? 'status error' : 'status';
    line.textContent = text;
    menu.append(line);
    positionMenu();
  }

  function option(menu, label, detail, onClick) {
    const button = document.createElement('button');
    button.setAttribute('role', 'menuitem');
    const title = document.createElement('div');
    title.className = 'label';
    title.textContent = label;
    button.append(title);
    if (detail) {
      const sub = document.createElement('div');
      sub.className = 'detail';
      sub.textContent = detail;
      button.append(sub);
    }
    button.addEventListener('click', (event) => {
      event.stopPropagation();
      onClick();
    });
    menu.append(button);
  }

  async function showMenu(video, button) {
    const menu = menuShell(button, 'Kervan');
    status(menu, 'Seçenekler hazırlanıyor…');
    const reply = await chrome.runtime.sendMessage({
      type: 'candidates', frameUrl: location.href, srcUrl: video.currentSrc || video.src || '',
    });
    if (!openMenu || openMenu.element !== menu) return;
    const options = reply?.options || [];
    const choose = (candidate) => (candidate.kind === 'file' ? send(menu, candidate.request) : showQualities(menu, candidate.request));
    if (options.length === 1) return choose(options[0]);
    menu.querySelector('.head').textContent = 'Kervan ile indir';
    menu.querySelector('.status')?.remove();
    for (const candidate of options) option(menu, candidate.label, candidate.detail, () => choose(candidate));
    positionMenu();
  }

  /** Akış ya da sayfa için kalite listesi (yt-dlp formatları); alınamazsa varsayılan kaliteyle indirme seçeneği. */
  async function showQualities(menu, request) {
    menu.querySelector('.head').textContent = 'Kalite seç';
    status(menu, 'Kaliteler alınıyor…');
    const reply = await chrome.runtime.sendMessage({ type: 'qualities', request });
    if (!openMenu || openMenu.element !== menu) return;
    menu.querySelector('.status')?.remove();
    if (reply?.title) menu.querySelector('.head').textContent = `Kalite seç · ${reply.title}`;
    const rows = reply?.ok ? reply.rows : [];
    for (const row of rows) option(menu, row.label, row.detail, () => send(menu, { ...request, preset: row.preset }));
    if (!rows.length) {
      if (!reply?.ok) {
        const line = document.createElement('div');
        line.className = 'status error';
        line.textContent = reply?.error || 'Kalite bilgisi alınamadı.';
        menu.append(line);
      }
      option(menu, 'Varsayılan kaliteyle indir', '', () => send(menu, request));
    }
    positionMenu();
  }

  async function send(menu, request) {
    status(menu, 'Kuyruğa ekleniyor…');
    const response = await chrome.runtime.sendMessage({ type: 'add', request });
    if (!response?.ok) return status(menu, response?.error || 'Eklenemedi.', true);
    if (response.entries) {
      status(menu, `Bu sayfada ${response.entries.length} video var.`);
      option(menu, 'Hepsini ekle', response.title || '', () => send(menu, { ...request, items: 'all' }));
      positionMenu();
      return;
    }
    status(menu, `✓ Kuyrukta: ${response.items?.[0]?.title || 'eklendi'}`);
    setTimeout(() => openMenu?.element === menu && closeMenu(), 2500);
  }

  // --- Olaylar ---

  let scheduled = false;
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      layout();
    });
  }

  // Medya olayları kabarcıklanmaz ama yakalama aşamasında document'a ulaşır.
  for (const type of ['loadedmetadata', 'play', 'playing']) {
    document.addEventListener(type, (event) => {
      if (event.target instanceof HTMLVideoElement) track(event.target);
    }, true);
  }
  new MutationObserver(() => {
    scan();
    schedule();
  }).observe(document.documentElement, { childList: true, subtree: true });
  addEventListener('scroll', schedule, { capture: true, passive: true });
  addEventListener('resize', schedule, { passive: true });
  document.addEventListener('fullscreenchange', schedule);
  document.addEventListener('click', (event) => {
    if (openMenu && !event.composedPath().includes(host)) closeMenu();
  }, true);
  addEventListener('keydown', (event) => event.key === 'Escape' && closeMenu());
  setInterval(layout, 700);

  chrome.storage.local.get('overlay').then(({ overlay = true }) => {
    enabled = overlay;
    layout();
  });
  chrome.storage.onChanged.addListener((changes) => {
    if (changes.overlay) {
      enabled = changes.overlay.newValue !== false;
      if (!enabled) closeMenu();
      layout();
    }
  });

  scan();
  globalThis.__kervanOverlay = { tracked, layout, shadow };
})();
