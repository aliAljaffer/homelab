const express = require('express');
const { spawn } = require('child_process');

const app = express();
const PORT = process.env.PORT || 7001;

const FFMPEG_PATH = process.env.FFMPEG_PATH || 'ffmpeg';
const USE_HWACCEL = process.env.USE_HWACCEL !== 'false';
const VIDEO_CODEC = process.env.VIDEO_CODEC || 'h264';
const VIDEO_QUALITY = process.env.VIDEO_QUALITY || '28';
const AUDIO_CODEC = process.env.AUDIO_CODEC || 'aac';
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
  let headersSent = false;

  function startTranscoding(url = streamUrl) {
    let ffmpegArgs = [];

    if (USE_HWACCEL) {
      ffmpegArgs = [
        '-hwaccel', 'vaapi',
        '-hwaccel_output_format', 'vaapi',
        '-vaapi_device', '/dev/dri/renderD128',
        '-i', url,
        '-c:v', 'h264_vaapi',
        '-qp', VIDEO_QUALITY,
        '-c:a', AUDIO_CODEC,
        '-b:a', AUDIO_BITRATE,
        '-f', 'mpegts',
        '-flush_packets', '1',
        'pipe:1'
      ];
    } else {
      ffmpegArgs = [
        '-i', url,
        '-c:v', VIDEO_CODEC,
        '-crf', VIDEO_QUALITY,
        '-c:a', AUDIO_CODEC,
        '-b:a', AUDIO_BITRATE,
        '-f', 'mpegts',
        '-flush_packets', '1',
        'pipe:1'
      ];
    }

    ffmpegProcess = spawn(FFMPEG_PATH, ffmpegArgs, {
      stdio: ['ignore', 'pipe', 'pipe']
    });

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
      console.error(`[FFMPEG] ${msg.trim()}`);
    });

    ffmpegProcess.on('close', (code) => {
      console.log(`[FFMPEG] Exited with code ${code}`);
      if (reconnectAttempts < MAX_RECONNECTS) {
        reconnectAttempts++;
        console.log(`[TRANSCODE] Reconnecting (attempt ${reconnectAttempts})`);
        setTimeout(() => startTranscoding(url), RECONNECT_DELAY);
      } else {
        console.log(`[TRANSCODE] Max reconnects reached`);
        res.end();
      }
    });
  }

  res.on('close', () => {
    console.log(`[CLIENT] Disconnected`);
    if (ffmpegProcess) {
      ffmpegProcess.kill();
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
  console.log(`[TRANSCODER] Video codec: ${VIDEO_CODEC}, quality: ${VIDEO_QUALITY}`);
  console.log(`[TRANSCODER] Audio codec: ${AUDIO_CODEC}, bitrate: ${AUDIO_BITRATE}`);
});
