import { formatBytes, mediaLabel, shortUrl } from './detect.js';

const STATE_LABELS = {
  queued: 'sırada', downloading: 'iniyor', postprocessing: 'işleniyor', paused: 'duraklatıldı',
  failed: 'hata', canceled: 'iptal', done: 'bitti',
};

const $ = (id) => document.getElementById(id);
const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
const state = await chrome.runtime.sendMessage({ type: 'state', tabId: tab.id });
const pageUrl = tab.url || state.pageUrl;
const title = tab.title || state.title;

// Kalite tercihi
const { preset = '1080p' } = await chrome.storage.local.get('preset');
$('preset').value = preset;
$('preset').addEventListener('change', (e) => chrome.storage.local.set({ preset: e.target.value }));

// Sayfa
$('page-title').textContent = title;
$('page').addEventListener('click', () => add({ url: pageUrl, pageUrl, title }, $('page')));

// Yakalanan medya
$('media-empty').hidden = state.media.length > 0;
for (const media of state.media.slice().reverse()) {
  const item = document.createElement('li');
  const info = document.createElement('div');
  info.className = 'info';
  const name = document.createElement('div');
  name.className = 'name';
  name.textContent = `${mediaLabel(media)}${media.size ? ' · ' + formatBytes(media.size) : ''}`;
  const meta = document.createElement('div');
  meta.className = 'meta';
  meta.textContent = shortUrl(media.url);
  meta.title = media.url;
  info.append(name, meta);
  const button = document.createElement('button');
  button.textContent = 'İndir';
  button.addEventListener('click', () => add({ url: media.url, pageUrl, title }, button));
  item.append(info, button);
  $('media').append(item);
}

async function add(request, button) {
  button.disabled = true;
  show('Ekleniyor…');
  const response = await chrome.runtime.sendMessage({ type: 'add', request });
  button.disabled = false;
  if (!response?.ok && response?.loginRequired && request.cookies !== 'fallback') return askCookies(request);
  if (!response?.ok && response?.duplicateOf) return askForce(request, response.error);
  if (!response?.ok) return show(response?.error || 'bilinmeyen hata', true);
  if (response.entries) return askSelection(request, response);
  const first = response.items?.[0];
  show(`✓ Kuyrukta: ${first?.title || request.url}`);
}

/** Çok videolu sayfa: hepsi ya da "1,3" gibi seçim. */
function askSelection(request, response) {
  const box = $('result');
  box.className = '';
  box.textContent = `${response.entries.length} video var: `;
  const all = document.createElement('button');
  all.textContent = 'Hepsini ekle';
  all.addEventListener('click', () => add({ ...request, items: 'all' }, all));
  const row = document.createElement('div');
  row.className = 'choice';
  const input = document.createElement('input');
  input.placeholder = 'ör. 1,3 ya da 2-5';
  const some = document.createElement('button');
  some.textContent = 'Seçilenler';
  some.addEventListener('click', () => input.value && add({ ...request, items: input.value }, some));
  row.append(input, some);
  box.append(all, row);
}

/** Site giriş istedi: kullanıcı onaylarsa tarayıcı çerezleriyle yeniden dene. */
function askCookies(request) {
  show('Site giriş istiyor. Tarayıcıda bu siteye giriş yaptıysan: ', true);
  const retry = document.createElement('button');
  retry.textContent = 'Tarayıcı çerezleriyle dene';
  retry.addEventListener('click', () => add({ ...request, cookies: 'fallback' }, retry));
  $('result').append(retry);
}

/** Link zaten listede: kullanıcı isterse yine de ekle. */
function askForce(request, message) {
  show(`${message} `, true);
  const again = document.createElement('button');
  again.textContent = 'Yine de ekle';
  again.addEventListener('click', () => add({ ...request, force: true }, again));
  $('result').append(again);
}

function show(text, isError = false) {
  $('result').textContent = text;
  $('result').className = isError ? 'error' : '';
}

/** Öğenin durumuna göre gösterilecek eylemler: [komut, etiket, tehlikeli mi]. */
const ACTIONS = {
  queued: [['pause', 'Durdur'], ['cancel', 'İptal', true]],
  downloading: [['pause', 'Durdur'], ['cancel', 'İptal', true]],
  postprocessing: [['cancel', 'İptal', true]],
  paused: [['resume', 'Devam'], ['cancel', 'İptal', true]],
  failed: [['retry', 'Yeniden'], ['remove', 'Sil', true]],
  canceled: [['retry', 'Yeniden'], ['remove', 'Sil', true]],
  done: [['reveal', 'Klasörde göster'], ['remove', 'Listeden sil']],
};
/** İnen öğeyi iptal etmek/silmek ikinci tıklamayla onaylanır (yarım iş kaybolmasın). */
const NEEDS_CONFIRM = new Set(['downloading', 'postprocessing']);
const CONFIRM_MS = 3000;
const confirming = new Map(); // "id:komut" → bitiş zamanı

async function control(cmd, id) {
  const response = await chrome.runtime.sendMessage({ type: 'control', cmd, ids: id === undefined ? undefined : [id] });
  if (!response?.ok) show(response?.error || 'İşlem yapılamadı.', true);
}

// --- Kuyruk: tek kalıcı köprü bağlantısı (connectNative). Önce abone olunur, sonra liste gelir;
// sonrası yalnız değişiklik olayları. Popup kapanınca bağlantı ve köprü süreci kapanır.

const HOST = 'com.dogukan.kervan';
const queue = new Map();
let queueError = null;
let renderScheduled = false;

function connectQueue() {
  const port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener((message) => {
    if (!message?.ok) {
      queueError = message?.error || 'Kuyruk okunamadı.';
    } else {
      queueError = null;
      if (!message.event && message.items) queue.clear(); // tam liste
      for (const item of message.items || []) {
        const known = queue.get(item.id);
        // Liste yanıtından önce üretilmiş, geç gelen eski olay yeni durumu ezmesin.
        if (message.event && known && item.updatedAt < known.updatedAt) continue;
        queue.set(item.id, item);
      }
      for (const id of message.removed || []) queue.delete(id);
    }
    scheduleRender();
  });
  port.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError?.message || 'bağlantı kapandı';
    queueError = `Kervan köprüsü yok (${reason}). Terminalde: kervan extension install`;
    scheduleRender();
  });
  port.postMessage({ cmd: 'subscribe' });
  port.postMessage({ cmd: 'list' });
}

function scheduleRender() {
  if (renderScheduled) return;
  renderScheduled = true;
  requestAnimationFrame(() => {
    renderScheduled = false;
    renderQueue();
  });
}

function renderQueue() {
  const list = $('queue');
  const note = (text) => {
    const item = document.createElement('li');
    item.className = 'meta';
    item.textContent = text;
    list.replaceChildren(item);
  };
  if (queueError) return note(queueError);
  $('clean').hidden = ![...queue.values()].some((i) => i.kind !== 'group' && (i.state === 'done' || i.state === 'canceled'));
  const items = [...queue.values()].filter((i) => i.kind !== 'group').sort((a, b) => b.id - a.id).slice(0, 8);
  if (!items.length) return note('Kuyruk boş.');
  list.replaceChildren(...items.map(queueRow));
}

function queueRow(entry) {
  const item = document.createElement('li');
  item.className = `state-${entry.state}`;
  const info = document.createElement('div');
  info.className = 'info';
  const name = document.createElement('div');
  name.className = 'name';
  name.textContent = entry.title || entry.url;
  name.title = entry.title || entry.url;
  const meta = document.createElement('div');
  meta.className = 'meta';
  const total = entry.bytesTotal || entry.bytesTotalEstimate;
  const fraction = total ? Math.min(1, entry.bytesDone / total) : entry.state === 'done' ? 1 : 0;
  const parts = [STATE_LABELS[entry.state] || entry.state];
  if (total) parts.push(`%${Math.round(fraction * 100)}`);
  if (entry.speed && entry.state === 'downloading') parts.push(`${formatBytes(Math.round(entry.speed))}/s`);
  if (entry.state === 'failed' && entry.lastError) parts.push(entry.lastError);
  meta.textContent = parts.join(' · ');
  meta.title = meta.textContent;
  info.append(name, meta);
  if (entry.state !== 'done' && entry.state !== 'canceled') {
    const bar = document.createElement('div');
    bar.className = 'bar';
    bar.setAttribute('role', 'progressbar');
    bar.setAttribute('aria-valuenow', String(Math.round(fraction * 100)));
    const fill = document.createElement('div');
    fill.style.width = `${Math.round(fraction * 100)}%`;
    bar.append(fill);
    info.append(bar);
  }
  const actions = document.createElement('div');
  actions.className = 'actions';
  for (const [cmd, label, danger] of ACTIONS[entry.state] || []) {
    const key = `${entry.id}:${cmd}`;
    const pending = (confirming.get(key) || 0) > Date.now();
    const button = document.createElement('button');
    button.textContent = pending ? 'Emin misin?' : label;
    if (danger) button.className = pending ? 'danger confirm' : 'danger';
    button.addEventListener('click', () => {
      if (danger && NEEDS_CONFIRM.has(entry.state) && (confirming.get(key) || 0) <= Date.now()) {
        confirming.set(key, Date.now() + CONFIRM_MS);
        setTimeout(scheduleRender, CONFIRM_MS + 50);
        return scheduleRender();
      }
      confirming.delete(key);
      control(cmd, entry.id);
    });
    actions.append(button);
  }
  item.append(info, actions);
  return item;
}

// Video üstü düğme tercihi (content.js dinler)
const { overlay = true } = await chrome.storage.local.get('overlay');
$('overlay').checked = overlay;
$('overlay').addEventListener('change', (e) => chrome.storage.local.set({ overlay: e.target.checked }));

$('clean').addEventListener('click', () => control('clean'));
connectQueue();
