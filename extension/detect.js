// Ağ yanıtlarından indirilebilir medya bulma. Saf fonksiyonlar: tarayıcı API'si kullanmaz,
// `node --test extension/test` ile test edilir.

const HLS_TYPES = ['application/vnd.apple.mpegurl', 'application/x-mpegurl', 'audio/mpegurl', 'audio/x-mpegurl'];
const DASH_TYPES = ['application/dash+xml'];
const SEGMENT_EXTENSIONS = ['ts', 'm4s', 'cmfv', 'cmfa', 'aac', 'vtt', 'webvtt'];
const FILE_EXTENSIONS = ['mp4', 'm4v', 'webm', 'mkv', 'mov', 'avi', 'flv', 'mp3', 'm4a', 'ogg', 'oga', 'opus', 'flac', 'wav'];
// YouTube parçalı akışı (googlevideo) yakalanmaz; YouTube sayfası "Sayfayı indir" ile yt-dlp'ye gider.
const IGNORED_HOSTS = ['googlevideo.com', 'doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'adnxs.com'];
/** Bundan küçük düz dosyalar (reklam, önizleme, ses efekti) gösterilmez. */
export const MIN_FILE_BYTES = 300 * 1024;

function header(headers, name) {
  const found = (headers || []).find((h) => h.name.toLowerCase() === name);
  return found ? found.value : undefined;
}

/** "bytes 0-1023/52428800" → 52428800; yoksa Content-Length. */
export function responseSize(statusCode, headers) {
  if (statusCode === 206) {
    const match = /\/(\d+)\s*$/.exec(header(headers, 'content-range') || '');
    return match ? Number(match[1]) : undefined;
  }
  const length = Number(header(headers, 'content-length'));
  return Number.isFinite(length) && length > 0 ? length : undefined;
}

/** Bir webRequest yanıtı indirilebilir medya mı? Değilse null. */
export function classifyResponse({ url, statusCode, responseHeaders }) {
  if (statusCode !== 200 && statusCode !== 206) return null;
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
  const host = parsed.hostname.toLowerCase();
  if (IGNORED_HOSTS.some((h) => host === h || host.endsWith('.' + h))) return null;
  if (parsed.searchParams.has('range')) return null;

  const mime = (header(responseHeaders, 'content-type') || '').split(';')[0].trim().toLowerCase();
  const ext = (parsed.pathname.split('.').pop() || '').toLowerCase();
  const base = { url: stripHash(url), mime };

  if (HLS_TYPES.includes(mime) || ext === 'm3u8') return { ...base, kind: 'hls' };
  if (DASH_TYPES.includes(mime) || ext === 'mpd') return { ...base, kind: 'dash' };
  if (SEGMENT_EXTENSIONS.includes(ext) || mime === 'video/mp2t' || mime === 'video/iso.segment') return null;

  const mediaMime = mime.startsWith('video/') || mime.startsWith('audio/');
  const genericMime = mime === '' || mime === 'application/octet-stream' || mime === 'binary/octet-stream';
  if (!mediaMime && !(genericMime && FILE_EXTENSIONS.includes(ext))) return null;
  const size = responseSize(statusCode, responseHeaders);
  if (size !== undefined && size < MIN_FILE_BYTES) return null;
  return { ...base, kind: 'file', size, ext: FILE_EXTENSIONS.includes(ext) ? ext : mime.split('/')[1] };
}

function stripHash(url) {
  const index = url.indexOf('#');
  return index === -1 ? url : url.slice(0, index);
}

/** HLS ana listesi mi? Öyleyse alt (çözünürlük/ses) listelerinin mutlak adresleri. */
export function parseMasterPlaylist(text, baseUrl) {
  const lines = text.split(/\r?\n/).map((l) => l.trim());
  const variants = [];
  let isMaster = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('#EXT-X-STREAM-INF')) {
      isMaster = true;
      const next = lines.slice(i + 1).find((l) => l && !l.startsWith('#'));
      if (next) variants.push(resolve(next, baseUrl));
    } else if (line.startsWith('#EXT-X-MEDIA') || line.startsWith('#EXT-X-I-FRAME-STREAM-INF')) {
      const uri = /URI="([^"]+)"/.exec(line);
      if (uri) variants.push(resolve(uri[1], baseUrl));
    }
  }
  return { isMaster, variants: [...new Set(variants)] };
}

function resolve(relative, base) {
  try {
    return stripHash(new URL(relative, base).href);
  } catch {
    return relative;
  }
}

export function emptyTab(pageUrl = '', title = '') {
  return { pageUrl, title, media: [], hidden: [] };
}

/** Medyayı sekme durumuna ekler; yeni eklendiyse true. */
export function addMedia(state, media, now = Date.now()) {
  const existing = state.media.find((m) => m.url === media.url);
  if (existing) {
    if (media.size && !existing.size) existing.size = media.size;
    return false;
  }
  state.media.push({ ...media, seenAt: now });
  if (state.media.length > 50) state.media.shift();
  return true;
}

/** Ana listeye bağlı alt listeleri gizler (kullanıcı tek "HLS akışı" görür). */
export function hideVariants(state, variants) {
  state.hidden = [...new Set([...(state.hidden || []), ...variants])].slice(-200);
}

export function visibleMedia(state) {
  const hidden = new Set(state.hidden || []);
  return state.media.filter((m) => !hidden.has(m.url));
}

export function mediaLabel(media) {
  if (media.kind === 'hls') return 'HLS akışı';
  if (media.kind === 'dash') return 'DASH akışı';
  return (media.ext || 'dosya').toUpperCase();
}

export function formatBytes(bytes) {
  if (!bytes) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  let size = bytes;
  let unit = 0;
  while (size >= 1000 && unit < units.length - 1) {
    size /= 1000;
    unit++;
  }
  return unit === 0 ? `${bytes} B` : `${size.toFixed(1)} ${units[unit]}`;
}

/** Servisin kalite listesini menü satırlarına çevirir: "1080p60" · "~267.9 MB". */
export function qualityRows(options = []) {
  return options.map((option) => ({
    preset: option.preset,
    size: option.size || undefined,
    label: { audio: 'Yalnız ses (m4a)', mp3: 'MP3 (kapak ve etiketli)' }[option.preset] || option.label,
    detail: option.size ? `~${formatBytes(option.size)}` : '',
  }));
}

/** Sağ tık menüsünden gelen adres: blob:/data: indirilemez, sayfaya düşülür. */
export function downloadableUrl(candidate, pageUrl) {
  if (candidate && /^https?:/i.test(candidate)) return candidate;
  return pageUrl;
}

export function shortUrl(url) {
  try {
    const parsed = new URL(url);
    const file = parsed.pathname.split('/').filter(Boolean).pop() || '';
    return file ? `${parsed.hostname} · ${decodeURIComponent(file)}` : parsed.hostname;
  } catch {
    return url;
  }
}

/**
 * Video üstü düğmenin menüsü: önce videonun kendi dosyası (http ise), sonra yakalanan akışlar
 * (yeniden eskiye), en sonda "sayfadan indir" (yt-dlp; iframe içindeyse çerçevenin adresi).
 * Her seçenek kuyruğa gönderilecek isteği taşır; Referer üst sekmenin adresidir.
 */
export function buildCandidates({ media = [], srcUrl, frameUrl, tabUrl, tabTitle }) {
  const isHttp = (url) => Boolean(url) && /^https?:/i.test(url);
  const base = { pageUrl: tabUrl, title: tabTitle };
  const options = [];
  if (isHttp(srcUrl)) {
    options.push({ kind: 'file', label: 'Bu video dosyası', detail: shortUrl(srcUrl), request: { ...base, url: srcUrl } });
  }
  for (const item of media.slice().reverse()) {
    if (item.url === srcUrl) continue;
    const size = item.size ? ` · ${formatBytes(item.size)}` : '';
    options.push({
      kind: item.kind === 'file' ? 'file' : 'stream',
      label: `${mediaLabel(item)}${size}`,
      detail: shortUrl(item.url),
      request: { ...base, url: item.url, size: item.size },
    });
  }
  const page = isHttp(frameUrl) ? frameUrl : tabUrl;
  if (isHttp(page)) {
    options.push({
      kind: 'page',
      label: 'Sayfadan indir (site tanınırsa en iyi kalite)',
      detail: new URL(page).hostname,
      request: { ...base, url: page },
    });
  }
  return options;
}
