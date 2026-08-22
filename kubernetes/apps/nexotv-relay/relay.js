const express = require('express');
const http = require('http');
const https = require('https');
const { URL } = require('url');

const app = express();
app.set('trust proxy', true);
const PORT = process.env.PORT || 7001;
const PLAYLIST_CACHE_TTL_MS = parseInt(process.env.PLAYLIST_CACHE_TTL_MS || '5000');
const SEGMENT_PREFETCH_COUNT = parseInt(process.env.SEGMENT_PREFETCH_COUNT || '2');
const SEGMENT_BUFFER_TTL_MS = parseInt(process.env.SEGMENT_BUFFER_TTL_MS || '30000');

const playlistCache = new Map();
const segmentBuffer = new Map();

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
  if (segmentBuffer.has(url)) return;
  console.log(`[PREFETCH] ${url}`);
  const entry = { promise: fetchBinary(url), fetchedAt: Date.now() };
  segmentBuffer.set(url, entry);
  entry.promise
    .then((data) => console.log(`[PREFETCH] Done: ${url} (${data.length} bytes)`))
    .catch((err) => {
      console.error(`[PREFETCH] Error: ${url} (${err.message})`);
      segmentBuffer.delete(url);
    });
}

function pruneSegmentBuffer() {
  const now = Date.now();
  for (const [url, entry] of segmentBuffer) {
    if (now - entry.fetchedAt > SEGMENT_BUFFER_TTL_MS) segmentBuffer.delete(url);
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

  console.log(`[PLAYLIST] Request: ${streamUrl} (${isHit ? 'cache hit' : 'cache miss'})`);

  try {
    let result;
    if (isHit) {
      result = await cached.promise;
    } else {
      const promise = fetchText(streamUrl).then(({ body, finalUrl }) => rewritePlaylist(body, finalUrl, selfBase));
      playlistCache.set(cacheKey, { promise, fetchedAt: Date.now() });
      result = await promise;
    }

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
    console.error(`[PLAYLIST] Error: ${err.message}`);
    res.status(502).json({ error: err.message });
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

  try {
    const buffered = segmentBuffer.get(segmentUrl);
    const source = buffered ? 'memory' : 'remote';
    const start = Date.now();
    const data = buffered ? await buffered.promise : await fetchBinary(segmentUrl);
    console.log(`[SEGMENT] ${source}: ${segmentUrl} (${data.length} bytes, ${Date.now() - start}ms)`);
    res.end(data);
  } catch (err) {
    segmentBuffer.delete(segmentUrl);
    console.error(`[SEGMENT] Error: ${err.message}`);
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

app.listen(PORT, () => {
  console.log(`[RELAY] Running on port ${PORT}`);
  console.log(`[RELAY] Mode: HLS proxy (playlist + segment rewrite, no ffmpeg)`);
});
