const express = require('express');
const http = require('http');
const https = require('https');
const { URL } = require('url');
const client = require('prom-client');

const app = express();
app.set('trust proxy', true);

client.collectDefaultMetrics();

const playlistRequestsTotal = new client.Counter({
  name: 'relay_playlist_requests_total',
  help: 'Playlist requests by cache result',
  labelNames: ['cache']
});
const playlistErrorsTotal = new client.Counter({
  name: 'relay_playlist_errors_total',
  help: 'Playlist fetch errors'
});
const segmentRequestsTotal = new client.Counter({
  name: 'relay_segment_requests_total',
  help: 'Segment requests by source',
  labelNames: ['source']
});
const segmentErrorsTotal = new client.Counter({
  name: 'relay_segment_errors_total',
  help: 'Segment fetch errors'
});
const prefetchTotal = new client.Counter({
  name: 'relay_prefetch_total',
  help: 'Segment prefetches by outcome',
  labelNames: ['outcome']
});
const PORT = process.env.PORT || 7001;
const PLAYLIST_CACHE_TTL_MS = parseInt(process.env.PLAYLIST_CACHE_TTL_MS || '5000');
const SEGMENT_PREFETCH_COUNT = parseInt(process.env.SEGMENT_PREFETCH_COUNT || '1');
const SEGMENT_BUFFER_TTL_MS = parseInt(process.env.SEGMENT_BUFFER_TTL_MS || '30000');
const PLAYLIST_ERROR_BACKOFF_MS = parseInt(process.env.PLAYLIST_ERROR_BACKOFF_MS || '8000');

const playlistCache = new Map();
const playlistErrorBackoff = new Map();
const segmentBuffer = new Map();

const SEGMENT_ID_RE = /(\d+_\d+)\.ts$/;

function segmentIdFor(url) {
  const match = url.match(SEGMENT_ID_RE);
  return match ? match[1] : url;
}

const agentOpts = { keepAlive: true, keepAliveMsecs: 10000, maxSockets: 32 };
const httpAgent = new http.Agent(agentOpts);
const httpsAgent = new https.Agent(agentOpts);

function agentFor(url) {
  return url.startsWith('https:') ? httpsAgent : httpAgent;
}

function fetchText(url) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith('https:') ? https : http;
    client.get(url, { agent: agentFor(url), headers: { 'User-Agent': 'Mozilla/5.0' } }, (upstreamRes) => {
      if (upstreamRes.statusCode >= 300 && upstreamRes.statusCode < 400 && upstreamRes.headers.location) {
        upstreamRes.resume();
        return resolve(fetchText(new URL(upstreamRes.headers.location, url).toString()));
      }
      if (upstreamRes.statusCode !== 200) {
        upstreamRes.resume();
        return reject(new Error(`HTTP ${upstreamRes.statusCode} for ${url}`));
      }
      const chunks = [];
      upstreamRes.on('data', (c) => chunks.push(c));
      upstreamRes.on('end', () => resolve({ body: Buffer.concat(chunks).toString('utf8'), finalUrl: url }));
      upstreamRes.on('error', reject);
    }).on('error', reject);
  });
}

function fetchBinary(url) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith('https:') ? https : http;
    client.get(url, { agent: agentFor(url), headers: { 'User-Agent': 'Mozilla/5.0' } }, (upstreamRes) => {
      if (upstreamRes.statusCode >= 300 && upstreamRes.statusCode < 400 && upstreamRes.headers.location) {
        upstreamRes.resume();
        return resolve(fetchBinary(new URL(upstreamRes.headers.location, url).toString()));
      }
      if (upstreamRes.statusCode !== 200) {
        upstreamRes.resume();
        return reject(new Error(`HTTP ${upstreamRes.statusCode} for ${url}`));
      }
      const chunks = [];
      upstreamRes.on('data', (c) => chunks.push(c));
      upstreamRes.on('end', () => resolve(Buffer.concat(chunks)));
      upstreamRes.on('error', reject);
    }).on('error', reject);
  });
}

function prefetchSegment(url) {
  const id = segmentIdFor(url);
  if (segmentBuffer.has(id)) return;
  console.log(`[PREFETCH] ${url}`);
  const entry = { promise: fetchBinary(url), fetchedAt: Date.now() };
  segmentBuffer.set(id, entry);
  entry.promise
    .then((data) => {
      console.log(`[PREFETCH] Done: ${url} (${data.length} bytes)`);
      prefetchTotal.inc({ outcome: 'success' });
    })
    .catch((err) => {
      console.error(`[PREFETCH] Error: ${url} (${err.message})`);
      prefetchTotal.inc({ outcome: 'error' });
      segmentBuffer.delete(id);
    });
}

function pruneSegmentBuffer() {
  const now = Date.now();
  for (const [id, entry] of segmentBuffer) {
    if (now - entry.fetchedAt > SEGMENT_BUFFER_TTL_MS) segmentBuffer.delete(id);
  }
}

function rewritePlaylist(text, baseUrl, selfBase) {
  const segmentUrls = [];
  const rewritten = text
    .split('\n')
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) return line;
      const absolute = new URL(trimmed, baseUrl).toString();
      segmentUrls.push(absolute);
      return `${selfBase}/segment.ts?url=${encodeURIComponent(absolute)}`;
    })
    .join('\n');
  return { rewritten, segmentUrls };
}

app.get('/playlist.m3u8', async (req, res) => {
  const streamUrl = req.query.url;
  if (!streamUrl) {
    return res.status(400).json({ error: 'Missing url parameter' });
  }

  const selfBase = `${req.protocol}://${req.get('host')}`;
  const cacheKey = `${selfBase}|${streamUrl}`;
  const cached = playlistCache.get(cacheKey);
  const isHit = cached && Date.now() - cached.fetchedAt < PLAYLIST_CACHE_TTL_MS;

  const backoffUntil = playlistErrorBackoff.get(cacheKey);
  if (backoffUntil && Date.now() < backoffUntil && !isHit) {
    console.log(`[PLAYLIST] Backing off: ${streamUrl} (${Math.ceil((backoffUntil - Date.now()) / 1000)}s remaining)`);
    playlistErrorsTotal.inc();
    return res.status(502).json({ error: 'Upstream backoff active' });
  }

  console.log(`[PLAYLIST] Request: ${streamUrl} (${isHit ? 'cache hit' : 'cache miss'})`);
  playlistRequestsTotal.inc({ cache: isHit ? 'hit' : 'miss' });

  try {
    let result;
    if (isHit) {
      result = await cached.promise;
    } else {
      const promise = fetchText(streamUrl).then(({ body, finalUrl }) => rewritePlaylist(body, finalUrl, selfBase));
      playlistCache.set(cacheKey, { promise, fetchedAt: Date.now() });
      result = await promise;
    }

    playlistErrorBackoff.delete(cacheKey);
    pruneSegmentBuffer();
    result.segmentUrls.slice(-SEGMENT_PREFETCH_COUNT).forEach(prefetchSegment);

    res.set({
      'Content-Type': 'application/vnd.apple.mpegurl',
      'Cache-Control': 'no-cache',
      'Access-Control-Allow-Origin': '*'
    });
    res.send(result.rewritten);
  } catch (err) {
    playlistCache.delete(cacheKey);
    playlistErrorBackoff.set(cacheKey, Date.now() + PLAYLIST_ERROR_BACKOFF_MS);
    console.error(`[PLAYLIST] Error: ${err.message || err.code || err}`);
    playlistErrorsTotal.inc();
    res.status(502).json({ error: err.message || err.code || 'Unknown error' });
  }
});

app.get('/segment.ts', async (req, res) => {
  const segmentUrl = req.query.url;
  if (!segmentUrl) {
    return res.status(400).json({ error: 'Missing url parameter' });
  }

  res.set({
    'Content-Type': 'video/mp2t',
    'Cache-Control': 'no-cache',
    'Access-Control-Allow-Origin': '*'
  });

  const id = segmentIdFor(segmentUrl);
  try {
    const buffered = segmentBuffer.get(id);
    const source = buffered ? 'memory' : 'remote';
    const start = Date.now();
    const data = buffered ? await buffered.promise : await fetchBinary(segmentUrl);
    console.log(`[SEGMENT] ${source}: ${segmentUrl} (${data.length} bytes, ${Date.now() - start}ms)`);
    segmentRequestsTotal.inc({ source });
    res.end(data);
  } catch (err) {
    segmentBuffer.delete(id);
    console.error(`[SEGMENT] Error: ${err.message}`);
    segmentErrorsTotal.inc();
    if (!res.headersSent) {
      res.status(502).json({ error: err.message });
    } else {
      res.end();
    }
  }
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

app.listen(PORT, () => {
  console.log(`[RELAY] Running on port ${PORT}`);
  console.log(`[RELAY] Mode: HLS proxy (playlist + segment rewrite, no ffmpeg)`);
});
