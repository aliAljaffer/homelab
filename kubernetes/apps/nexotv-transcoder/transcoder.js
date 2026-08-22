const express = require('express');
const { spawn } = require('child_process');
const http = require('http');
const https = require('https');
const { URL } = require('url');

const app = express();
const PORT = process.env.PORT || 7001;

const FFMPEG_PATH = process.env.FFMPEG_PATH || 'ffmpeg';
const USE_HWACCEL = process.env.USE_HWACCEL !== 'false';
const VIDEO_CODEC = process.env.VIDEO_CODEC || 'h264';
const AUDIO_CODEC = process.env.AUDIO_CODEC || 'aac';
const VIDEO_BITRATE = process.env.VIDEO_BITRATE || '2M';
const AUDIO_BITRATE = process.env.AUDIO_BITRATE || '128k';
const MAX_RECONNECTS = parseInt(process.env.MAX_RECONNECTS || '10');
const RECONNECT_DELAY = parseInt(process.env.RECONNECT_DELAY || '2000');

app.get('/transcode', async (req, res) => {
  const streamUrl = req.query.url;
  
  if (!streamUrl) {
    return res.status(400).json({ error: 'Missing url parameter' });
  }

  console.log(`[TRANSCODE] Starting: ${streamUrl}`);

  let reconnectAttempts = 0;
  let ffmpegProcess = null;
  let upstreamReq = null;
  let headersSent = false;

  function startTranscoding() {
    const parsedUrl = new URL(streamUrl);
    const isHttps = parsedUrl.protocol === 'https:';
    const httpModule = isHttps ? https : http;

    upstreamReq = httpModule.get(streamUrl, {
      headers: {
        'User-Agent': 'Mozilla/5.0',
        'Connection': 'keep-alive'
      }
    }, (upstreamRes) => {
      if (!headersSent) {
        headersSent = true;
        res.writeHead(200, {
          'Content-Type': 'video/mp2t',
          'Transfer-Encoding': 'chunked',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
          'Access-Control-Allow-Origin': '*'
        });
      }

      const ffmpegArgs = [
        '-i', 'pipe:0',
        '-c:v', VIDEO_CODEC,
        '-b:v', VIDEO_BITRATE,
        '-c:a', AUDIO_CODEC,
        '-b:a', AUDIO_BITRATE,
        '-f', 'mpegts',
        '-flush_packets', '1',
        'pipe:1'
      ];

      if (USE_HWACCEL) {
        ffmpegArgs.unshift(
          '-hwaccel', 'vaapi',
          '-hwaccel_output_format', 'vaapi',
          '-vaapi_device', '/dev/dri/renderD128'
        );
        ffmpegArgs[ffmpegArgs.indexOf('-c:v') + 1] = 'h264_vaapi';
      }

      ffmpegProcess = spawn(FFMPEG_PATH, ffmpegArgs, {
        stdio: ['pipe', 'pipe', 'pipe']
      });

      upstreamRes.pipe(ffmpegProcess.stdin);

      ffmpegProcess.stdout.on('data', (chunk) => {
        if (!res.write(chunk)) {
          ffmpegProcess.stdout.pause();
        }
      });

      res.on('drain', () => {
        if (ffmpegProcess && ffmpegProcess.stdout) {
          ffmpegProcess.stdout.resume();
        }
      });

      ffmpegProcess.stderr.on('data', (data) => {
        const msg = data.toString();
        if (msg.includes('Error') || msg.includes('error')) {
          console.error(`[FFMPEG] ${msg.trim()}`);
        }
      });

      ffmpegProcess.on('close', (code) => {
        console.log(`[FFMPEG] Exited with code ${code}`);
        if (reconnectAttempts < MAX_RECONNECTS) {
          reconnectAttempts++;
          console.log(`[TRANSCODE] Reconnecting (attempt ${reconnectAttempts})`);
          setTimeout(startTranscoding, RECONNECT_DELAY);
        } else {
          console.log(`[TRANSCODE] Max reconnects reached`);
          res.end();
        }
      });

      upstreamRes.on('end', () => {
        console.log(`[UPSTREAM] Stream ended`);
        if (ffmpegProcess) {
          ffmpegProcess.stdin.end();
        }
      });

      upstreamRes.on('error', (err) => {
        console.error(`[UPSTREAM] Error: ${err.message}`);
        if (ffmpegProcess) {
          ffmpegProcess.kill();
        }
      });
    });

    upstreamReq.on('error', (err) => {
      console.error(`[UPSTREAM] Request error: ${err.message}`);
      if (reconnectAttempts < MAX_RECONNECTS) {
        reconnectAttempts++;
        console.log(`[TRANSCODE] Reconnecting (attempt ${reconnectAttempts})`);
        setTimeout(startTranscoding, RECONNECT_DELAY);
      } else {
        if (!headersSent) {
          res.status(502).json({ error: 'Upstream error' });
        } else {
          res.end();
        }
      }
    });
  }

  res.on('close', () => {
    console.log(`[CLIENT] Disconnected`);
    if (ffmpegProcess) {
      ffmpegProcess.kill();
    }
    if (upstreamReq) {
      upstreamReq.destroy();
    }
  });

  startTranscoding();
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.listen(PORT, () => {
  console.log(`[TRANSCODER] Running on port ${PORT}`);
  console.log(`[TRANSCODER] Hardware acceleration: ${USE_HWACCEL ? 'enabled' : 'disabled'}`);
  console.log(`[TRANSCODER] Video codec: ${VIDEO_CODEC}, bitrate: ${VIDEO_BITRATE}`);
  console.log(`[TRANSCODER] Audio codec: ${AUDIO_CODEC}, bitrate: ${AUDIO_BITRATE}`);
});
