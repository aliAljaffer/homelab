#!/usr/bin/env python3
"""OpenAI-compatible router that keeps Hindsight on OpenCode's free models.

Hindsight is configured with the fixed model name ``free``. This router accepts
that call, swaps in the first free OpenCode model that works, and streams the
reply back. The list lives in the ``hindsight-free-models`` ConfigMap, which the
``free-models-sync`` CronJob refreshes. The router reads it through the
Kubernetes API so a ConfigMap created after this pod starts is still picked up.
When the ConfigMap or the API is unavailable the built-in list below is used.

The router also supplies ``x-opencode-session``; OpenCode Go requires it on every
chat request (a missing header is a hard 400).
"""

import asyncio
import hashlib
import json
import logging
import os
import ssl
import time
import uuid

from aiohttp import ClientError, ClientSession, ClientTimeout, web

TOKEN = os.environ.get("HINDSIGHT_API_LLM_API_KEY", "")
NAMESPACE = os.environ.get("POD_NAMESPACE", "hindsight")
CONFIGMAP = "hindsight-free-models"
PORT = int(os.environ.get("PORT", "8899"))
REQUEST_DEADLINE = float(os.environ.get("ROUTER_DEADLINE_SECONDS", "170"))
ATTEMPT_TIMEOUT = float(os.environ.get("ROUTER_ATTEMPT_TIMEOUT_SECONDS", "60"))
CACHE_SECONDS = 300
RETRY_SECONDS = 30
GO_BASE = "https://opencode.ai/inference/go/openai/v1"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

# Used until the CronJob writes the ConfigMap. Keep this to models that are
# free on OpenCode Go; the paid Go models draw down the monthly allowance.
DEFAULT_MODELS = [
    {"id": "hungerg-free", "base_url": GO_BASE},
    {"id": "beam-free", "base_url": GO_BASE},
    {"id": "hy4-flash-free", "base_url": GO_BASE},
]

log = logging.getLogger("llm-router")
_models_cache: tuple[float, list[dict]] | None = None
_last_ids: tuple[str, ...] | None = None


def _valid_models(value) -> list[dict] | None:
    if not isinstance(value, list):
        return None
    models = []
    seen = set()
    for item in value:
        if not isinstance(item, dict):
            continue
        model = str(item.get("id") or "").strip()
        base = str(item.get("base_url") or "").strip().rstrip("/")
        if not model or not base or model in seen:
            continue
        seen.add(model)
        models.append({"id": model, "base_url": base})
    return models or None


def _service_account_ssl() -> tuple[str, ssl.SSLContext]:
    with open(f"{SA_DIR}/token", encoding="utf-8") as handle:
        token = handle.read()
    context = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    return token, context


async def _read_configmap(client: ClientSession) -> list[dict] | None:
    token, context = _service_account_ssl()
    url = (
        "https://kubernetes.default.svc/api/v1/namespaces/"
        f"{NAMESPACE}/configmaps/{CONFIGMAP}"
    )
    timeout = ClientTimeout(total=5)
    async with client.get(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        ssl=context,
        timeout=timeout,
    ) as response:
        if response.status == 404:
            return None
        response.raise_for_status()
        payload = await response.json()
    raw = (payload.get("data") or {}).get("models.json")
    if not raw:
        return None
    return _valid_models(json.loads(raw))


async def models(client: ClientSession) -> list[dict]:
    """Return the current model list, refreshing it from the ConfigMap."""
    global _models_cache, _last_ids
    now = time.monotonic()
    if _models_cache and now - _models_cache[0] < (
        CACHE_SECONDS if _models_cache[1] else RETRY_SECONDS
    ):
        return _models_cache[1] or DEFAULT_MODELS

    try:
        parsed = await _read_configmap(client)
    except (OSError, ValueError, ClientError) as exc:
        log.warning("cannot read ConfigMap %s/%s: %s", NAMESPACE, CONFIGMAP, exc)
        parsed = None

    _models_cache = (now, parsed or [])
    active = parsed or DEFAULT_MODELS
    ids = tuple(model["id"] for model in active)
    if ids != _last_ids:
        log.info("free model list: %s", ", ".join(ids))
        _last_ids = ids
    return active


def session_id(body: dict) -> str:
    """Stable per-conversation id for OpenCode's routing and prompt cache."""
    messages = body.get("messages")
    if messages:
        raw = json.dumps(messages, sort_keys=True, separators=(",", ":")).encode()
        return "hindsight-" + hashlib.sha256(raw).hexdigest()[:32]
    return "hindsight-" + uuid.uuid4().hex


def error_payload(message: str, detail: str | None = None) -> dict:
    error = {"message": message, "type": "router_error"}
    if detail:
        error["detail"] = detail[:2000]
    return {"error": error}


async def chat(request: web.Request) -> web.StreamResponse:
    try:
        body = await request.json()
    except ValueError:
        return web.json_response(error_payload("request body is not valid JSON"), status=400)
    if not isinstance(body, dict):
        return web.json_response(error_payload("request body must be a JSON object"), status=400)

    deadline = time.monotonic() + REQUEST_DEADLINE
    stream = bool(body.get("stream"))
    sid = session_id(body)
    failures = []

    for model in await models(request.app["client"]):
        remaining = deadline - time.monotonic()
        if remaining <= 1:
            break
        payload = dict(body)
        payload["model"] = model["id"]
        headers = {
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "x-opencode-session": sid,
            "User-Agent": "hindsight-free-model-router/1.0",
        }
        timeout = ClientTimeout(
            total=min(ATTEMPT_TIMEOUT, remaining),
            connect=10,
            sock_read=min(ATTEMPT_TIMEOUT, remaining),
        )
        url = model["base_url"] + "/chat/completions"
        try:
            async with request.app["client"].post(
                url, json=payload, headers=headers, timeout=timeout
            ) as upstream:
                if upstream.status >= 400:
                    detail = (await upstream.read())[:2000].decode(errors="replace")
                    failures.append(f"{model['id']}: HTTP {upstream.status} {detail}")
                    log.warning("model %s failed: HTTP %s", model["id"], upstream.status)
                    continue

                if stream and "text/event-stream" in upstream.headers.get("Content-Type", ""):
                    response = web.StreamResponse(
                        status=upstream.status,
                        headers={
                            "Content-Type": "text/event-stream",
                            "Cache-Control": "no-cache",
                            "X-Accel-Buffering": "no",
                        },
                    )
                    await response.prepare(request)
                    async for chunk in upstream.content.iter_any():
                        await response.write(chunk)
                    await response.write_eof()
                    return response

                raw = await upstream.read()
                content_type = upstream.headers.get("Content-Type", "application/json")
        except (asyncio.TimeoutError, ClientError) as exc:
            failures.append(f"{model['id']}: {type(exc).__name__}")
            log.warning("model %s failed: %s", model["id"], exc)
            continue

        if not stream:
            try:
                parsed = json.loads(raw)
            except ValueError:
                failures.append(f"{model['id']}: non-JSON response")
                continue
            choices = parsed.get("choices") or []
            answered = any(
                (choice.get("message") or {}).get("content")
                or (choice.get("message") or {}).get("tool_calls")
                for choice in choices
            )
            if parsed.get("error") or not answered:
                failures.append(f"{model['id']}: {json.dumps(parsed)[:500]}")
                continue
        return web.Response(body=raw, status=upstream.status, content_type=content_type)

    log.error("all free models failed: %s", "; ".join(failures))
    return web.json_response(
        error_payload("all free OpenCode models failed", "; ".join(failures)), status=502
    )


async def health(_request: web.Request) -> web.Response:
    return web.Response(text="ok")


async def list_models(_request: web.Request) -> web.Response:
    return web.json_response(
        {
            "object": "list",
            "data": [{"id": "free", "object": "model", "owned_by": "hindsight-router"}],
        }
    )


async def start_client(app: web.Application) -> None:
    app["client"] = ClientSession()


async def cleanup(app: web.Application) -> None:
    await app["client"].close()


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    if not TOKEN:
        raise SystemExit("HINDSIGHT_API_LLM_API_KEY is empty")
    app = web.Application()
    app.on_startup.append(start_client)
    app.on_cleanup.append(cleanup)
    app.router.add_get("/healthz", health)
    app.router.add_get("/v1/models", list_models)
    app.router.add_post("/v1/chat/completions", chat)
    app.router.add_post("/chat/completions", chat)
    web.run_app(app, host="0.0.0.0", port=PORT, access_log=None)


if __name__ == "__main__":
    main()
