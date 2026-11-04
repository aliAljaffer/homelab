# stt

Self-hosted speech-to-text for `fai` Telegram voice notes. One CPU-only
[Speaches](https://github.com/speaches-ai/speaches) pod backed by
`faster-whisper`.

- Model: `Systran/faster-distil-whisper-small.en` (English only), int8 on CPU.
- API: OpenAI-compatible `POST /v1/audio/transcriptions` on
  `http://speaches.stt.svc.cluster.local:8000`.
- Cache: `speaches-models` (5Gi Longhorn PVC) at
  `/home/ubuntu/.cache/huggingface/hub`. The model downloads once on first start.
- Access: only `fai-backend` can reach port 8000. The pod may reach the internet
  on 443 to download the model.

`fai` points at it with `STT_BASE_URL=http://speaches.stt.svc.cluster.local:8000/v1`,
`STT_MODEL=Systran/faster-distil-whisper-small.en`, and `STT_LANGUAGE=en`.

To change the model, update the `postStart` download URL and `STT_MODEL` in
`fai` together. For a multilingual model, use `Systran/faster-whisper-small` and
drop `STT_LANGUAGE` or set the language per deployment.
