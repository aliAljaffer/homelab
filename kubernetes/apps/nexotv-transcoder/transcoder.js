const express = require('express');
const http = require('http');
const https = require('https');
const { URL } = require('url');

const app = express();
app.set('trust proxy', true);
const PORT = process.env.PORT || 7001;

function fetchText(url) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith('https:') ? https : http;
    client.get(url, { headers: { 'User-Agent': 'Mozilla/5.0' } }, (upstreamRes) => {
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

function pipeBinary(url, res) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith('https:') ? https : http;
    const req = client.get(url, { headers: { 'User-Agent': 'Mozilla/5.0' } }, (upstreamRes) => {
      if (upstreamRes.statusCode >= 300 && upstreamRes.statusCode < 400 && upstreamRes.headers.location) {
        upstreamRes.resume();
        return resolve(pipeBinary(new URL(upstreamRes.headers.location, url).toString(), res));
      }
      if (upstreamRes.statusCode !== 200) {
        upstreamRes.resume();
        return reject(new Error(`HTTP ${upstreamRes.statusCode} for ${url}`));
      }
      upstreamRes.pipe(res);
      upstreamRes.on('end', resolve);
      upstreamRes.on('error', reject);
    });
    req.on('error', reject);
  });
}

function rewritePlaylist(text, baseUrl, selfBase) {
  return text
    .split('\n')
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) return line;
      const absolute = new URL(trimmed, baseUrl).toString();
      return `${selfBase}/segment.ts?url=${encodeURIComponent(absolute)}`;
    })
    .join('\n');
}

app.get('/playlist.m3u8', async (req, res) => {
  const streamUrl = req.query.url;
  if (!streamUrl) {
    return res.status(400).json({ error: 'Missing url parameter' });
  }

  try {
    const { body, finalUrl } = await fetchText(streamUrl);
    const selfBase = `${req.protocol}://${req.get('host')}`;
    const rewritten = rewritePlaylist(body, finalUrl, selfBase);

    res.set({
      'Content-Type': 'application/vnd.apple.mpegurl',
      'Cache-Control': 'no-cache',
      'Access-Control-Allow-Origin': '*'
    });
    res.send(rewritten);
  } catch (err) {
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
    await pipeBinary(segmentUrl, res);
  } catch (err) {
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
  console.log(`[TRANSCODER] Running on port ${PORT}`);
  console.log(`[TRANSCODER] Mode: HLS proxy (playlist + segment rewrite, no ffmpeg)`);
});
