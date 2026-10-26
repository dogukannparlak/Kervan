import {
  addMedia, buildCandidates, classifyResponse, downloadableUrl, emptyTab, hideVariants, parseMasterPlaylist, qualityRows,
  visibleMedia,
} from './detect.js';

const HOST = 'com.dogukan.kervan';
const tabs = new Map();
const queues = new Map();

// --- Sekme durumu (service worker uykuya geçince storage.session'dan geri yüklenir) ---

async function loadTab(tabId) {
  if (!tabs.has(tabId)) {
    const key = `tab:${tabId}`;
    const stored = (await chrome.storage.session.get(key))[key];
    if (!tabs.has(tabId)) tabs.set(tabId, stored || emptyTab());
  }
  return tabs.get(tabId);
}

/** Aynı sekmeye yapılan değişiklikleri sırayla uygular. */
function withTab(tabId, change) {
  const previous = queues.get(tabId) || Promise.resolve();
  const next = previous.then(async () => {
    const state = await loadTab(tabId);
    if ((await change(state)) !== false) {
      await chrome.storage.session.set({ [`tab:${tabId}`]: state });
      updateBadge(tabId, state);
    }
  }).catch((error) => console.warn('Kervan:', error));
  queues.set(tabId, next);
  return next;
}

function updateBadge(tabId, state) {
  const count = visibleMedia(state).length;
  chrome.action.setBadgeBackgroundColor({ tabId, color: '#E8833A' }).catch(() => {});
  chrome.action.setBadgeText({ tabId, text: count ? String(count) : '' }).catch(() => {});
}

// --- Ağ dinleme ---

chrome.webRequest.onHeadersReceived.addListener((details) => {
  if (details.tabId < 0) return;
  const media = classifyResponse(details);
  if (!media) return;
  withTab(details.tabId, async (state) => {
    if (!addMedia(state, media)) return false;
    if (media.kind === 'hls') await inspectHls(state, media.url);
  });
}, { urls: ['<all_urls>'] }, ['responseHeaders']);

/** HLS ana listesini okuyup alt listeleri gizler. */
async function inspectHls(state, url) {
  try {
    // Önbellekten: oynatıcı listeyi zaten indirdi; tek kullanımlık token'lı adreste ikinci istek token'ı harcamasın.
    const response = await fetch(url, { credentials: 'include', cache: 'force-cache' });
    const { isMaster, variants } = parseMasterPlaylist(await response.text(), url);
    if (isMaster) hideVariants(state, variants);
  } catch (error) {
    console.warn('Kervan: m3u8 okunamadı', url, error);
  }
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'loading' && changeInfo.url) {
    withTab(tabId, (state) => Object.assign(state, emptyTab(changeInfo.url, tab.title || '')));
  } else if (changeInfo.title || changeInfo.url) {
    withTab(tabId, (state) => {
      state.title = tab.title || state.title;
      state.pageUrl = tab.url || state.pageUrl;
    });
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  tabs.delete(tabId);
  queues.delete(tabId);
  chrome.storage.session.remove(`tab:${tabId}`);
});

// --- Kervan'a gönderme ---

async function preferences() {
  const { preset = '1080p' } = await chrome.storage.local.get('preset');
  return { preset };
}

/** kervand'a native host üzerinden istek. Hata da yanıt nesnesi olarak döner. */
async function send(message) {
  try {
    return await chrome.runtime.sendNativeMessage(HOST, message);
  } catch (error) {
    return { ok: false, error: `Kervan köprüsü yok (${error.message}). Terminalde: kervan extension install` };
  }
}

function referer(url, pageUrl) {
  return pageUrl && pageUrl !== url ? pageUrl : undefined;
}

/** Tarayıcı çerezi yalnız kullanıcı "tarayıcı çerezleriyle dene" dediyse kullanılır (site giriş istediğinde). */
function cookieChoice(value) {
  return value === 'fallback' ? 'fallback' : 'none';
}

/** `request.preset` (kalite menüsünden) yoksa popup'taki varsayılan kalite. */
async function addToKervan({ url, pageUrl, title, items, preset: chosen, cookies, force, size }) {
  const preset = chosen || (await preferences()).preset;
  return send({
    cmd: 'add', url, preset, items, cookies: cookieChoice(cookies), force: force === true || undefined,
    size: Number.isFinite(size) && size > 0 ? Math.round(size) : undefined,
    referer: referer(url, pageUrl),
    userAgent: navigator.userAgent,
    title: title || undefined,
  });
}

async function qualitiesFor({ url, pageUrl, cookies }) {
  const response = await send({
    cmd: 'formats', url, cookies: cookieChoice(cookies), referer: referer(url, pageUrl), userAgent: navigator.userAgent,
  });
  if (!response?.ok) return { ok: false, error: response?.error, loginRequired: response?.loginRequired === true };
  return { ok: true, title: response.qualities?.title, rows: qualityRows(response.qualities?.options) };
}

// --- Sağ tık menüsü ---

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: 'kervan-link', title: 'Kervan ile indir: bağlantı', contexts: ['link'] });
    chrome.contextMenus.create({ id: 'kervan-media', title: 'Kervan ile indir: bu video/ses', contexts: ['video', 'audio'] });
    chrome.contextMenus.create({ id: 'kervan-page', title: 'Kervan ile indir: bu sayfa', contexts: ['page'] });
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const pageUrl = info.pageUrl || tab?.url;
  const request = info.menuItemId === 'kervan-link'
    ? { url: info.linkUrl, pageUrl }
    : info.menuItemId === 'kervan-media'
      ? { url: downloadableUrl(info.srcUrl, pageUrl), pageUrl, title: tab?.title }
      : { url: pageUrl, pageUrl, title: tab?.title };
  notifyResult(request, await addToKervan(request));
});

// Bildirim düğmesinin göndereceği istek. Service worker uyuyunca bellek silinir; bu yüzden storage.session'da.
async function remember(id, request) {
  await chrome.storage.session.set({ [`notify:${id}`]: request });
}

async function recall(id) {
  const key = `notify:${id}`;
  const request = (await chrome.storage.session.get(key))[key];
  await chrome.storage.session.remove(key);
  return request;
}

async function notifyResult(request, response) {
  const id = `kervan-${Date.now()}`;
  let options;
  if (!response?.ok && response?.loginRequired && request.cookies !== 'fallback') {
    await remember(id, { ...request, cookies: 'fallback' });
    options = {
      title: 'Kervan: site giriş istiyor',
      message: 'Tarayıcıda bu siteye giriş yaptıysan çerezlerinle yeniden deneyebilirsin.',
      buttons: [{ title: 'Tarayıcı çerezleriyle dene' }],
      requireInteraction: true,
    };
  } else if (!response?.ok && response?.duplicateOf) {
    await remember(id, { ...request, force: true });
    options = {
      title: 'Kervan: zaten listede',
      message: response.error,
      buttons: [{ title: 'Yine de ekle' }],
      requireInteraction: true,
    };
  } else if (!response?.ok) {
    options = { title: 'Kervan: eklenemedi', message: response?.error || 'bilinmeyen hata' };
  } else if (response.entries) {
    await remember(id, { ...request, items: 'all' });
    options = {
      title: 'Kervan: birden çok video',
      message: `${response.title || 'Bu sayfada'} ${response.entries.length} video var.`,
      buttons: [{ title: 'Hepsini ekle' }],
      requireInteraction: true,
    };
  } else {
    const first = response.items?.[0];
    options = { title: 'Kervan: kuyruğa eklendi', message: first?.title || request.url };
  }
  chrome.notifications.create(id, { type: 'basic', iconUrl: 'icons/128.png', ...options });
}

chrome.notifications.onButtonClicked.addListener(async (id) => {
  const request = await recall(id);
  chrome.notifications.clear(id);
  if (request) notifyResult(request, await addToKervan(request));
});

chrome.notifications.onClosed.addListener((id) => {
  recall(id);
});

// --- Açılır pencere ile konuşma ---

const CONTROL_COMMANDS = ['pause', 'resume', 'cancel', 'retry', 'remove', 'reveal', 'clean'];

/**
 * Mesaj eklentinin kendi sayfasından mı (popup)? İçerik betikleri her sitenin her çerçevesinde çalışır;
 * Chrome'un modelinde onlardan gelen mesaja güvenilmez. Kuyruğu okumak/yönetmek ve başka sekmenin
 * durumunu görmek yalnız eklenti sayfasına açık.
 */
function fromExtensionPage(sender) {
  return sender.id === chrome.runtime.id && !sender.tab && (sender.url || '').startsWith(chrome.runtime.getURL(''));
}

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  (async () => {
    if (!message || typeof message !== 'object') return reply({ ok: false, error: 'Geçersiz istek.' });
    if (message.type === 'candidates' && sender.tab) {
      // Video üstü düğme (content.js) soruyor: bu sekmede neler indirilebilir?
      const state = await loadTab(sender.tab.id);
      const { preset } = await preferences();
      reply({
        preset,
        options: buildCandidates({
          media: visibleMedia(state), srcUrl: message.srcUrl, frameUrl: message.frameUrl,
          tabUrl: sender.tab.url, tabTitle: sender.tab.title,
        }),
      });
    } else if (message.type === 'qualities') {
      reply(await qualitiesFor(message.request || {}));
    } else if (message.type === 'add') {
      reply(await addToKervan(message.request || {}));
    } else if (!fromExtensionPage(sender)) {
      reply({ ok: false, error: 'Bu istek yalnız Kervan penceresinden yapılabilir.' });
    } else if (message.type === 'control' && CONTROL_COMMANDS.includes(message.cmd)) {
      reply(await send({ cmd: message.cmd, ids: message.ids }));
    } else if (message.type === 'state') {
      const state = await loadTab(message.tabId);
      reply({ pageUrl: state.pageUrl, title: state.title, media: visibleMedia(state) });
    } else if (message.type === 'list') {
      reply(await send({ cmd: 'list' }));
    } else {
      reply({ ok: false, error: 'Bilinmeyen istek.' });
    }
  })();
  return true;
});
