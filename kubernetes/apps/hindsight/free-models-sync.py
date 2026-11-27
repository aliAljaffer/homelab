#!/usr/bin/env python3
"""Refresh Hindsight's free-model list from OpenCode's public catalogs.

The router sidecar reads the ConfigMap this writes. Every free chat model is a
candidate, but only models that answer a small JSON probe are written, so the
list cannot contain a model that is listed but not callable (region blocks,
free-tier limits, missing Go access). The current working models are ordered
first; other valid models follow.
"""

import json
import os
import pathlib
import ssl
import time
import urllib.error
import urllib.request
import uuid

TOKEN = os.environ["HINDSIGHT_API_LLM_API_KEY"]
NAMESPACE = os.environ.get("POD_NAMESPACE", "hindsight")
CONFIGMAP = "hindsight-free-models"
CATALOGS = (
    "https://opencode.ai/inference/go/v1/models",
    "https://opencode.ai/inference/v1/models",
)
MIN_OUTPUT_TOKENS = int(os.environ.get("MIN_OUTPUT_TOKENS", "32000"))
DRY_RUN = os.environ.get("DRY_RUN") == "1"
PREFERRED = (
    "deepseek-v4.1-flash-free",
    "hungerg-free",
    "beam-free",
    "hy4-flash-free",
)
PROBE_PROMPT = 'Return only the JSON object {"ok": true}.'


def log(message):
    print(message, flush=True)


def fetch(url):
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/json",
            "User-Agent": "hindsight-free-models-sync/1.0",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
        raise ValueError("unexpected model list shape")
    return payload


def free_chat_models(payload):
    for model in payload.get("data") or []:
        if not isinstance(model, dict) or model.get("type") != "chat":
            continue
        model_id = model.get("id")
        if not isinstance(model_id, str) or not model_id.strip():
            continue
        cost = (model.get("cost") or {}).get("text") or {}
        source = (cost.get("input") or {}).get("price")
        output_price = (cost.get("output") or {}).get("price")
        if source != 0 or output_price != 0:
            continue
        api = (model.get("api") or {}).get("chat-completions") or {}
        base_url = api.get("base_url")
        if not isinstance(base_url, str) or not base_url.startswith(("http://", "https://")):
            continue
        limit = (model.get("limit") or {}).get("output")
        if not isinstance(limit, int) or limit < MIN_OUTPUT_TOKENS:
            continue
        yield {"id": model_id, "base_url": base_url.rstrip("/")}


def candidates():
    seen = set()
    models = []
    for url in CATALOGS:
        try:
            payload = fetch(url)
        except (OSError, ValueError) as exc:
            log(f"catalog {url} failed: {exc}")
            continue
        for model in free_chat_models(payload):
            if model["id"] in seen:
                continue
            seen.add(model["id"])
            models.append(model)
    order = {model: index for index, model in enumerate(PREFERRED)}
    return sorted(models, key=lambda model: (order.get(model["id"], len(order)), model["id"]))


def extract_json(text):
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[-1].removesuffix("```").strip()
    try:
        return json.loads(text)
    except ValueError:
        start, end = text.find("{"), text.rfind("}")
        if start >= 0 and end > start:
            return json.loads(text[start : end + 1])
        raise


def probe(model):
    url = model["base_url"] + "/chat/completions"
    body = {
        "model": model["id"],
        "messages": [{"role": "user", "content": PROBE_PROMPT}],
        "response_format": {"type": "json_object"},
        "max_tokens": 512,
    }
    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "hindsight-free-models-sync/1.0",
        "x-opencode-session": "probe-" + uuid.uuid4().hex,
    }
    for attempt in range(2):
        request = urllib.request.Request(
            url, data=json.dumps(body).encode(), headers=headers, method="POST"
        )
        try:
            with urllib.request.urlopen(request, timeout=75) as response:
                payload = json.load(response)
            if payload.get("error"):
                return False, str(payload["error"])[:300]
            choices = payload.get("choices") or []
            if not choices:
                return False, "no choices"
            content = (choices[0].get("message") or {}).get("content")
            if isinstance(content, list):
                content = "".join(
                    part.get("text", "") for part in content if isinstance(part, dict)
                )
            if not content:
                return False, "empty content"
            extract_json(content)
            return True, ""
        except urllib.error.HTTPError as exc:
            detail = exc.read(300).decode(errors="replace")
            if exc.code in (429, 500, 502, 503, 504) and attempt == 0:
                time.sleep(5)
                continue
            return False, f"HTTP {exc.code}: {detail}"
        except (OSError, ValueError) as exc:
            if attempt == 0:
                time.sleep(5)
                continue
            return False, f"{type(exc).__name__}: {exc}"
    return False, "probe failed"


def kube_request(method, path, body=None, content_type="application/json"):
    token = pathlib.Path(
        "/var/run/secrets/kubernetes.io/serviceaccount/token"
    ).read_text()
    context = ssl.create_default_context(
        cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    )
    request = urllib.request.Request(
        "https://kubernetes.default.svc" + path,
        data=None if body is None else json.dumps(body).encode(),
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": content_type,
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=30, context=context) as response:
        raw = response.read()
    return json.loads(raw) if raw else None


def current_configmap():
    try:
        return kube_request(
            "GET", f"/api/v1/namespaces/{NAMESPACE}/configmaps/{CONFIGMAP}"
        )
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def write_configmap(payload):
    existing = current_configmap()
    if existing and (existing.get("data") or {}).get("models.json") == payload:
        log("model list unchanged")
        return
    metadata = {
        "name": CONFIGMAP,
        "namespace": NAMESPACE,
        "labels": {
            "app.kubernetes.io/name": CONFIGMAP,
            "app.kubernetes.io/managed-by": "free-models-sync",
        },
    }
    if existing:
        kube_request(
            "PATCH",
            f"/api/v1/namespaces/{NAMESPACE}/configmaps/{CONFIGMAP}",
            {"metadata": metadata, "data": {"models.json": payload}},
            "application/merge-patch+json",
        )
    else:
        kube_request(
            "POST",
            f"/api/v1/namespaces/{NAMESPACE}/configmaps",
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": metadata,
                "data": {"models.json": payload},
            },
        )
    log("model list updated")


def main():
    chosen = []
    for model in candidates():
        ok, reason = probe(model)
        if ok:
            chosen.append(model)
            log(f"keep {model['id']}")
        else:
            log(f"skip {model['id']}: {reason}")

    if not chosen:
        raise SystemExit("no free model passed the probe; leaving the ConfigMap unchanged")

    payload = json.dumps(chosen, indent=2) + "\n"
    if DRY_RUN:
        log(payload)
        return
    write_configmap(payload)


if __name__ == "__main__":
    main()
