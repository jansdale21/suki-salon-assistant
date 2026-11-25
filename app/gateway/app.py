"""
Suki AI gateway: an OpenAI-compatible proxy between LibreChat and Google Gemini.

Why it exists (SAM10 requirements it covers):
  * Loads the salon knowledge base from S3 at runtime and injects it as the system
    prompt (AWS integration; content can change without a redeploy).
  * Reads the Gemini API key and model name from SSM Parameter Store at runtime
    (no keys in code, config files or the repository).
  * Redacts e-mail addresses and phone numbers BEFORE anything leaves the AWS
    account (responsible use: no personal data to a third-party AI service).
  * Writes one JSON log line per request: question, latency, success, which
    model/knowledge/app version answered. CloudWatch metric filters turn these
    lines into the AnswersTotal / AnswersFailed / EmptyAnswer / latency metrics.

LibreChat talks to it as a "custom endpoint" (see app/librechat.yaml).
Model aliases:  suki-salon -> chat with knowledge,  suki-title -> chat titles.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import sys
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

# --------------------------------------------------------------------------- config
APP_VERSION = os.getenv("APP_VERSION", "dev")
AWS_REGION = os.getenv("AWS_REGION", "ap-southeast-1")
PARAM_PREFIX = os.getenv("PARAM_PREFIX", "/suki/prod")  # SSM parameter path
KNOWLEDGE_SOURCE = os.getenv("KNOWLEDGE_SOURCE", "file://../../content")  # s3://bucket/content/ or file://dir
KNOWLEDGE_REFRESH_SECONDS = int(os.getenv("KNOWLEDGE_REFRESH_SECONDS", "300"))
GEMINI_BASE_URL = os.getenv(
    "GEMINI_BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai"
).rstrip("/")
UPSTREAM_TIMEOUT = float(os.getenv("UPSTREAM_TIMEOUT_SECONDS", "60"))
MAX_LOGGED_QUESTION = 300
CHAT_ALIAS, TITLE_ALIAS = "suki-salon", "suki-title"
ALLOWED_PARAMS = {"model", "messages", "stream", "temperature", "top_p", "max_tokens", "stop", "n"}

# Structured logs to stdout -> docker awslogs driver -> CloudWatch Logs (/suki/gateway)
def log_event(event: str, **fields: Any) -> None:
    fields = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event, **fields}
    print(json.dumps(fields, ensure_ascii=False, default=str), flush=True)


# --------------------------------------------------------------------------- secrets
class Settings:
    """Values read from SSM Parameter Store, with env fallbacks for local dev."""

    def __init__(self) -> None:
        self._cache: dict[str, str] = {}
        self._ssm = None

    def _client(self):
        if self._ssm is None:
            import boto3  # imported lazily so unit tests need no AWS

            self._ssm = boto3.client("ssm", region_name=AWS_REGION)
        return self._ssm

    def get(self, name: str, env_fallback: str | None = None, default: str | None = None,
            refresh: bool = False) -> str | None:
        if env_fallback and os.getenv(env_fallback):
            return os.getenv(env_fallback)
        if name in self._cache and not refresh:
            return self._cache[name]
        if os.getenv("SUKI_DISABLE_SSM") == "1":
            return default
        try:
            resp = self._client().get_parameter(Name=f"{PARAM_PREFIX}/{name}", WithDecryption=True)
            self._cache[name] = resp["Parameter"]["Value"]
            return self._cache[name]
        except Exception as exc:  # noqa: BLE001 - log and fall back
            log_event("settings_error", parameter=f"{PARAM_PREFIX}/{name}", error=type(exc).__name__)
            return default


settings = Settings()


def gemini_key(refresh: bool = False) -> str | None:
    return settings.get("GEMINI_API_KEY", env_fallback="GEMINI_API_KEY", refresh=refresh)


def gateway_token() -> str | None:
    return settings.get("GATEWAY_TOKEN", env_fallback="GATEWAY_TOKEN")


def gemini_model() -> str:
    return settings.get("GEMINI_MODEL", env_fallback="GEMINI_MODEL", default="gemini-2.5-flash") or "gemini-2.5-flash"


# --------------------------------------------------------------------------- knowledge
class Knowledge:
    def __init__(self) -> None:
        self.text: str = ""
        self.version: str = "none"
        self.files: int = 0
        self.loaded_at: float = 0.0

    def _read_local(self, path: str) -> list[tuple[str, str, str]]:
        base = Path(path)
        out = []
        for f in sorted(base.glob("*.md")):
            body = f.read_text(encoding="utf-8")
            out.append((f.name, body, hashlib.sha1(body.encode()).hexdigest()[:8]))
        return out

    def _read_s3(self, uri: str) -> list[tuple[str, str, str]]:
        import boto3

        bucket, _, prefix = uri[len("s3://"):].partition("/")
        s3 = boto3.client("s3", region_name=AWS_REGION)
        keys = []
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
            keys += [o["Key"] for o in page.get("Contents", []) if o["Key"].endswith(".md")]
        out = []
        for key in sorted(keys):
            obj = s3.get_object(Bucket=bucket, Key=key)
            body = obj["Body"].read().decode("utf-8")
            tag = obj.get("VersionId") or obj.get("ETag", "").strip('"')
            out.append((key.rsplit("/", 1)[-1], body, str(tag)[:8]))
        return out

    def load(self) -> None:
        src = KNOWLEDGE_SOURCE
        try:
            docs = self._read_s3(src) if src.startswith("s3://") else self._read_local(src.removeprefix("file://"))
        except Exception as exc:  # noqa: BLE001
            log_event("knowledge_error", source=src, error=f"{type(exc).__name__}: {exc}"[:300])
            return  # keep the previous copy if we had one
        if not docs:
            log_event("knowledge_error", source=src, error="no .md documents found")
            return
        text = "\n\n".join(body.strip() for _, body, _ in docs)
        version = hashlib.sha1("|".join(f"{n}:{t}" for n, _, t in docs).encode()).hexdigest()[:10]
        changed = version != self.version
        self.text, self.version, self.files, self.loaded_at = text, version, len(docs), time.time()
        if changed:
            log_event("knowledge_loaded", source=src, files=len(docs), chars=len(text), knowledge_version=version)

    @property
    def ok(self) -> bool:
        return bool(self.text)


knowledge = Knowledge()


async def _refresh_loop() -> None:
    while True:
        await asyncio.sleep(KNOWLEDGE_REFRESH_SECONDS)
        await asyncio.to_thread(knowledge.load)


# --------------------------------------------------------------------------- PII redaction
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
# PH mobile (09xx / +639xx) and landlines/other long digit runs (7+ digits, optional separators)
PHONE_RE = re.compile(r"(?<![\w₱])(?:\+?63[\s-]?|0)9\d{2}[\s-]?\d{3}[\s-]?\d{4}(?!\d)"
                      r"|(?<![\w₱,.])\(?\d{2,4}\)?[\s-]\d{3,4}[\s-]\d{4}(?!\d)")
SALON_EMAIL = "hello@suklaykulay.example"


def redact(text: str) -> tuple[str, int]:
    count = 0

    def _email(m: re.Match) -> str:
        nonlocal count
        if m.group(0).lower() == SALON_EMAIL:
            return m.group(0)
        count += 1
        return "[email removed]"

    def _phone(m: re.Match) -> str:
        nonlocal count
        count += 1
        return "[phone removed]"

    text = EMAIL_RE.sub(_email, text)
    text = PHONE_RE.sub(_phone, text)
    return text, count


def _redact_messages(messages: list[dict]) -> tuple[list[dict], int]:
    total = 0
    clean = []
    for msg in messages:
        msg = dict(msg)
        content = msg.get("content")
        if isinstance(content, str):
            msg["content"], n = redact(content)
            total += n
        elif isinstance(content, list):
            parts = []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    part = dict(part)
                    part["text"], n = redact(part.get("text", ""))
                    total += n
                    parts.append(part)
                # non-text parts (images, files) are dropped: Suki is text-only
            msg["content"] = parts
        clean.append(msg)
    return clean, total


def _last_user_text(messages: list[dict]) -> str:
    for msg in reversed(messages):
        if msg.get("role") == "user":
            c = msg.get("content")
            if isinstance(c, str):
                return c
            if isinstance(c, list):
                return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
    return ""


def build_payload(body: dict, model: str, kind: str) -> tuple[dict, int, str]:
    messages, pii = _redact_messages(body.get("messages") or [])
    question = _last_user_text(messages)
    if kind == "chat":
        system = {"role": "system", "content": knowledge.text}
        # LibreChat may send its own system message; keep ours first.
        messages = [system] + messages
    payload = {k: v for k, v in body.items() if k in ALLOWED_PARAMS}
    if "max_completion_tokens" in body and "max_tokens" not in payload:
        payload["max_tokens"] = body["max_completion_tokens"]
    payload["model"] = model
    payload["messages"] = messages
    return payload, pii, question


# --------------------------------------------------------------------------- app
http_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    global http_client
    http_client = httpx.AsyncClient(timeout=httpx.Timeout(UPSTREAM_TIMEOUT, connect=10.0))
    await asyncio.to_thread(knowledge.load)
    task = asyncio.create_task(_refresh_loop())
    log_event("gateway_started", app_version=APP_VERSION, knowledge_version=knowledge.version,
              knowledge_files=knowledge.files, model=gemini_model())
    yield
    task.cancel()
    await http_client.aclose()


app = FastAPI(title="Suki AI gateway", lifespan=lifespan)


@app.get("/healthz")
async def healthz():
    body = {"status": "ok" if knowledge.ok else "degraded", "app_version": APP_VERSION,
            "knowledge_version": knowledge.version, "knowledge_files": knowledge.files,
            "knowledge_chars": len(knowledge.text)}
    return JSONResponse(body, status_code=200 if knowledge.ok else 503)


@app.post("/admin/reload-knowledge")
async def reload_knowledge(request: Request):
    if not _authorised(request):
        return JSONResponse({"error": "unauthorised"}, status_code=401)
    await asyncio.to_thread(knowledge.load)
    return {"knowledge_version": knowledge.version, "files": knowledge.files}


@app.get("/v1/models")
async def models():
    return {"object": "list", "data": [{"id": CHAT_ALIAS, "object": "model", "owned_by": "suki"},
                                        {"id": TITLE_ALIAS, "object": "model", "owned_by": "suki"}]}


def _authorised(request: Request) -> bool:
    expected = gateway_token()
    got = request.headers.get("authorization", "").removeprefix("Bearer ").strip()
    return bool(expected) and got == expected


def _error(status: int, message: str) -> JSONResponse:
    return JSONResponse({"error": {"message": message, "type": "suki_gateway_error"}}, status_code=status)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    started = time.perf_counter()
    rid = uuid.uuid4().hex[:12]
    if not _authorised(request):
        return _error(401, "Invalid gateway token")
    body = await request.json()
    kind = "title" if body.get("model") == TITLE_ALIAS else "chat"
    model = gemini_model()
    stream = bool(body.get("stream"))
    source = request.headers.get("x-suki-source", "librechat")[:20]  # "eval" for the scheduled test run
    base = dict(request_id=rid, kind=kind, source=source, alias=body.get("model"), model=model, stream=stream,
                app_version=APP_VERSION, knowledge_version=knowledge.version)

    if kind == "chat" and not knowledge.ok:
        log_event("chat", **base, success=False, empty=True, latency_ms=0, upstream_status=None,
                  error="knowledge_missing", pii_redacted=0, question="")
        return _error(503, "Suki's salon information is temporarily unavailable. Please try again soon.")

    payload, pii, question = build_payload(body, model, kind)
    base.update(pii_redacted=pii, question=question[:MAX_LOGGED_QUESTION])
    key = gemini_key()
    if not key:
        log_event("chat", **base, success=False, empty=True, latency_ms=0, upstream_status=None,
                  error="missing_api_key")
        return _error(500, "Model key not configured")
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    url = f"{GEMINI_BASE_URL}/chat/completions"
    assert http_client is not None

    if not stream:
        try:
            resp = await http_client.post(url, json=payload, headers=headers)
        except httpx.HTTPError as exc:
            ms = int((time.perf_counter() - started) * 1000)
            log_event("chat", **base, success=False, empty=True, latency_ms=ms, upstream_status=None,
                      error=type(exc).__name__)
            return _error(502, "The AI service did not respond")
        ms = int((time.perf_counter() - started) * 1000)
        if resp.status_code != 200:
            log_event("chat", **base, success=False, empty=True, latency_ms=ms,
                      upstream_status=resp.status_code, error=resp.text[:300])
            return JSONResponse(_safe_json(resp), status_code=resp.status_code)
        data = resp.json()
        answer = ""
        try:
            answer = data["choices"][0]["message"].get("content") or ""
        except (KeyError, IndexError, TypeError):
            pass
        usage = data.get("usage") or {}
        log_event("chat", **base, success=bool(answer.strip()), empty=not answer.strip(), latency_ms=ms,
                  first_token_ms=ms, upstream_status=200, answer_chars=len(answer),
                  prompt_tokens=usage.get("prompt_tokens"), completion_tokens=usage.get("completion_tokens"))
        return JSONResponse(data)

    # ---- streaming (Server-Sent Events): relay bytes as they arrive, observe content on the way
    req = http_client.build_request("POST", url, json=payload, headers=headers)
    try:
        upstream = await http_client.send(req, stream=True)
    except httpx.HTTPError as exc:
        ms = int((time.perf_counter() - started) * 1000)
        log_event("chat", **base, success=False, empty=True, latency_ms=ms, upstream_status=None,
                  error=type(exc).__name__)
        return _error(502, "The AI service did not respond")

    if upstream.status_code != 200:
        raw = await upstream.aread()
        await upstream.aclose()
        ms = int((time.perf_counter() - started) * 1000)
        log_event("chat", **base, success=False, empty=True, latency_ms=ms,
                  upstream_status=upstream.status_code, error=raw.decode(errors="replace")[:300])
        try:
            content = json.loads(raw)
        except ValueError:
            content = {"error": {"message": raw.decode(errors="replace")[:300]}}
        if isinstance(content, list) and content:
            content = content[0]
        return JSONResponse(content, status_code=upstream.status_code)

    async def relay() -> AsyncIterator[bytes]:
        answer_chars = 0
        first_token_ms = None
        finish = None
        usage: dict = {}
        error = None
        buf = ""
        try:
            async for chunk in upstream.aiter_bytes():
                yield chunk
                buf += chunk.decode("utf-8", errors="replace")
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    line = line.strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        continue
                    try:
                        evt = json.loads(data)
                    except ValueError:
                        continue
                    for choice in evt.get("choices") or []:
                        piece = (choice.get("delta") or {}).get("content") or ""
                        if piece and first_token_ms is None:
                            first_token_ms = int((time.perf_counter() - started) * 1000)
                        answer_chars += len(piece)
                        finish = choice.get("finish_reason") or finish
                    usage = evt.get("usage") or usage
        except httpx.HTTPError as exc:
            error = f"stream_interrupted:{type(exc).__name__}"
        finally:
            await upstream.aclose()
            ms = int((time.perf_counter() - started) * 1000)
            log_event("chat", **base, success=answer_chars > 0 and error is None, empty=answer_chars == 0,
                      latency_ms=ms, first_token_ms=first_token_ms, upstream_status=200,
                      answer_chars=answer_chars, finish_reason=finish, error=error,
                      prompt_tokens=usage.get("prompt_tokens"), completion_tokens=usage.get("completion_tokens"))

    return StreamingResponse(relay(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


def _safe_json(resp: httpx.Response) -> Any:
    try:
        data = resp.json()
        return data[0] if isinstance(data, list) and data else data
    except ValueError:
        return {"error": {"message": resp.text[:300]}}
