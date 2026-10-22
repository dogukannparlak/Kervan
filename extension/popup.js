import { formatBytes, mediaLabel } from './detect.js';

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
  if (!response?.ok) return show(response?.error || 'bilinmeyen hata', true);
  if (response.entries) return askSelection(request, response);
  const first = response.items?.[0];
  show(`✓ Kuyrukta: ${first?.title || request.url}`);
  refreshQueue();
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

function show(text, isError = false) {
  $('result').textContent = text;
  $('result').className = isError ? 'error' : '';
}

function shortUrl(url) {
  try {
    const parsed = new URL(url);
    const file = parsed.pathname.split('/').filter(Boolean).pop() || '';
    return `${parsed.hostname} · ${decodeURIComponent(file)}`;
  } catch {
    return url;
  }
}

async function refreshQueue() {
  const response = await chrome.runtime.sendMessage({ type: 'list' });
  const list = $('queue');
  list.replaceChildren();
  if (!response?.ok) {
    const item = document.createElement('li');
    item.textContent = response?.error || 'Kuyruk okunamadı.';
    item.className = 'meta';
    list.append(item);
    return;
  }
  const items = (response.items || []).filter((i) => i.kind !== 'group').slice(-6).reverse();
  if (!items.length) {
    const item = document.createElement('li');
    item.className = 'meta';
    item.textContent = 'Kuyruk boş.';
    list.append(item);
  }
  for (const entry of items) {
    const item = document.createElement('li');
    const info = document.createElement('div');
    info.className = 'info';
    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = entry.title || entry.url;
    const meta = document.createElement('div');
    meta.className = 'meta';
    const total = entry.bytesTotal || entry.bytesTotalEstimate;
    const percent = total ? ` · %${Math.min(100, Math.round((entry.bytesDone / total) * 100))}` : '';
    meta.textContent = `${STATE_LABELS[entry.state] || entry.state}${percent}`;
    info.append(name, meta);
    item.append(info);
    list.append(item);
  }
}

refreshQueue();
setInterval(refreshQueue, 2000);
