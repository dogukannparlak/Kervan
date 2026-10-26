import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  addMedia, classifyResponse, downloadableUrl, emptyTab, hideVariants, mediaLabel, parseMasterPlaylist, visibleMedia,
} from '../detect.js';

const res = (url, contentType, extra = {}, statusCode = 200) => ({
  url,
  statusCode,
  responseHeaders: [
    ...(contentType ? [{ name: 'Content-Type', value: contentType }] : []),
    ...Object.entries(extra).map(([name, value]) => ({ name, value })),
  ],
});

test('HLS ve DASH manifestleri yakalanır', () => {
  assert.equal(classifyResponse(res('https://cdn.x/a/master.m3u8?t=1', 'application/vnd.apple.mpegurl')).kind, 'hls');
  assert.equal(classifyResponse(res('https://cdn.x/a/index.m3u8', 'text/plain')).kind, 'hls');
  assert.equal(classifyResponse(res('https://cdn.x/a/manifest.mpd', 'application/dash+xml')).kind, 'dash');
});

test('büyük video dosyası yakalanır, boyut Content-Range\'den okunur', () => {
  const media = classifyResponse(res('https://cdn.x/v.mp4#t=3', 'video/mp4', { 'Content-Range': 'bytes 0-1023/52428800' }, 206));
  assert.equal(media.kind, 'file');
  assert.equal(media.size, 52428800);
  assert.equal(media.url, 'https://cdn.x/v.mp4');
  assert.equal(media.ext, 'mp4');
});

test('octet-stream ama video uzantılı dosya yakalanır', () => {
  assert.equal(classifyResponse(res('https://cdn.x/film.mkv', 'application/octet-stream', { 'Content-Length': '9000000' })).kind, 'file');
});

test('parçalar, küçük dosyalar, YouTube akışı, reklam ve HTML elenir', () => {
  assert.equal(classifyResponse(res('https://cdn.x/seg-001.ts', 'video/mp2t')), null);
  assert.equal(classifyResponse(res('https://cdn.x/chunk.m4s', 'video/iso.segment')), null);
  assert.equal(classifyResponse(res('https://cdn.x/beep.mp3', 'audio/mpeg', { 'Content-Length': '20000' })), null);
  assert.equal(classifyResponse(res('https://rr1---sn.googlevideo.com/videoplayback?x=1', 'video/mp4', { 'Content-Length': '9000000' })), null);
  assert.equal(classifyResponse(res('https://ad.doubleclick.net/v.mp4', 'video/mp4')), null);
  assert.equal(classifyResponse(res('https://x.com/page', 'text/html')), null);
  assert.equal(classifyResponse(res('https://cdn.x/v.mp4', 'video/mp4', {}, 404)), null);
  assert.equal(classifyResponse(res('https://cdn.x/v.mp4?range=0-1000', 'video/mp4')), null);
});

test('HLS ana listesi alt listeleri mutlak adreslere çevirir', () => {
  const text = [
    '#EXTM3U',
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio/en.m3u8"',
    '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360',
    'v360/index.m3u8',
    '#EXT-X-STREAM-INF:BANDWIDTH=2000000',
    'https://other.cdn/v720.m3u8',
  ].join('\n');
  const { isMaster, variants } = parseMasterPlaylist(text, 'https://cdn.x/hls/master.m3u8');
  assert.equal(isMaster, true);
  assert.deepEqual(variants, ['https://cdn.x/hls/audio/en.m3u8', 'https://cdn.x/hls/v360/index.m3u8', 'https://other.cdn/v720.m3u8']);
  assert.equal(parseMasterPlaylist('#EXTM3U\n#EXTINF:4,\nseg1.ts', 'https://cdn.x/a.m3u8').isMaster, false);
});

test('sekme durumu: tekrar eklenmez, alt listeler gizlenir', () => {
  const state = emptyTab('https://site/page', 'Başlık');
  assert.equal(addMedia(state, { url: 'https://cdn.x/master.m3u8', kind: 'hls' }), true);
  assert.equal(addMedia(state, { url: 'https://cdn.x/v360.m3u8', kind: 'hls' }), true);
  assert.equal(addMedia(state, { url: 'https://cdn.x/master.m3u8', kind: 'hls' }), false);
  hideVariants(state, ['https://cdn.x/v360.m3u8']);
  assert.deepEqual(visibleMedia(state).map((m) => m.url), ['https://cdn.x/master.m3u8']);
  assert.equal(mediaLabel(visibleMedia(state)[0]), 'HLS akışı');
});

test('blob: adresleri sayfa adresine düşer', () => {
  assert.equal(downloadableUrl('blob:https://site/uuid', 'https://site/page'), 'https://site/page');
  assert.equal(downloadableUrl('https://cdn.x/v.mp4', 'https://site/page'), 'https://cdn.x/v.mp4');
});

test('video üstü menü: dosya, akışlar, sayfa sırası', async () => {
  const { buildCandidates } = await import('../detect.js');
  const options = buildCandidates({
    media: [
      { url: 'https://cdn.x/master.m3u8', kind: 'hls' },
      { url: 'https://cdn.x/v.mp4', kind: 'file', ext: 'mp4', size: 5_000_000 },
    ],
    srcUrl: 'https://cdn.x/v.mp4',
    frameUrl: 'https://player.site/embed/1',
    tabUrl: 'https://site/page',
    tabTitle: 'Başlık',
  });
  assert.deepEqual(options.map((o) => o.request.url), ['https://cdn.x/v.mp4', 'https://cdn.x/master.m3u8', 'https://player.site/embed/1']);
  assert.ok(options.every((o) => o.request.pageUrl === 'https://site/page' && o.request.title === 'Başlık'));
});

test('menü seçenek türleri ve kalite satırları', async () => {
  const { buildCandidates, qualityRows } = await import('../detect.js');
  const kinds = buildCandidates({
    media: [{ url: 'https://cdn.x/m.m3u8', kind: 'hls' }],
    srcUrl: 'https://cdn.x/v.mp4',
    tabUrl: 'https://site/page',
  }).map((o) => o.kind);
  assert.deepEqual(kinds, ['file', 'stream', 'page']);
  assert.deepEqual(qualityRows([
    { preset: '1080p', label: '1080p60', size: 267_900_000 },
    { preset: 'audio', label: 'Yalnız ses', size: null },
  ]), [
    { preset: '1080p', size: 267_900_000, label: '1080p60', detail: '~267.9 MB' },
    { preset: 'audio', size: undefined, label: 'Yalnız ses (m4a)', detail: '' },
  ]);
});

test('YouTube gibi blob oynatıcıda tek seçenek: sayfa', async () => {
  const { buildCandidates } = await import('../detect.js');
  const options = buildCandidates({ srcUrl: 'blob:https://www.youtube.com/x', frameUrl: 'https://www.youtube.com/watch?v=1', tabUrl: 'https://www.youtube.com/watch?v=1' });
  assert.equal(options.length, 1);
  assert.equal(options[0].request.url, 'https://www.youtube.com/watch?v=1');
});
