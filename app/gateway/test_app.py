"""Unit tests for the Suki gateway. Run: cd app/gateway && pytest -q
No AWS or Gemini access needed: the upstream model is replaced by a fake transport."""
import json
import os
from pathlib import Path

os.environ.update(SUKI_DISABLE_SSM="1", GATEWAY_TOKEN="test-token", GEMINI_API_KEY="fake-key",
                  KNOWLEDGE_SOURCE="file://" + str(Path(__file__).resolve().parents[2] / "content"))

import httpx  # noqa: E402
import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import app as gw  # noqa: E402

AUTH = {"Authorization": "Bearer test-token"}
captured: dict = {}


def fake_upstream(request: httpx.Request) -> httpx.Response:
    body = json.loads(request.content)
    captured["body"] = body
    if body["messages"][-1]["content"] == "trigger 429":
        return httpx.Response(429, json=[{"error": {"code": 429, "message": "quota"}}])
    if body.get("stream"):
        sse = ('data: {"choices":[{"delta":{"content":"Hi! "},"index":0}]}\n\n'
               'data: {"choices":[{"delta":{"content":"₱350"},"index":0,"finish_reason":"stop"}]}\n\n'
               "data: [DONE]\n\n")
        return httpx.Response(200, content=sse.encode(), headers={"content-type": "text/event-stream"})
    return httpx.Response(200, json={"choices": [{"message": {"role": "assistant", "content": "₱350"}}],
                                     "usage": {"prompt_tokens": 10, "completion_tokens": 2}})


@pytest.fixture()
def client():
    with TestClient(gw.app) as c:
        gw.http_client = httpx.AsyncClient(transport=httpx.MockTransport(fake_upstream))
        yield c


def test_health_reports_knowledge(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json()["knowledge_files"] >= 8


def test_rejects_bad_token(client):
    r = client.post("/v1/chat/completions", json={"model": "suki-salon", "messages": []},
                    headers={"Authorization": "Bearer nope"})
    assert r.status_code == 401


def test_injects_knowledge_and_redacts_pii(client, capsys):
    msg = "Hi, I'm at juan.dc@mail.com or 0917 123 4567. How much is a women's haircut (₱350?)"
    r = client.post("/v1/chat/completions", headers=AUTH,
                    json={"model": "suki-salon", "messages": [{"role": "user", "content": msg}],
                          "user": "abc", "stream_options": {"include_usage": True}})
    assert r.status_code == 200
    sent = captured["body"]
    assert sent["messages"][0]["role"] == "system" and "Suklay & Kulay" in sent["messages"][0]["content"]
    user_text = sent["messages"][-1]["content"]
    assert "juan.dc@mail.com" not in user_text and "0917" not in user_text
    assert "₱350" in user_text, "prices must not be redacted"
    assert "user" not in sent and "stream_options" not in sent
    log = [json.loads(l) for l in capsys.readouterr().out.splitlines() if '"event": "chat"' in l][-1]
    assert log["pii_redacted"] == 2 and log["success"] is True and log["empty"] is False


def test_salon_email_is_kept():
    text, n = gw.redact("Email hello@suklaykulay.example to book")
    assert n == 0 and "hello@suklaykulay.example" in text


def test_streaming_is_relayed_and_logged(client, capsys):
    r = client.post("/v1/chat/completions", headers=AUTH,
                    json={"model": "suki-salon", "stream": True,
                          "messages": [{"role": "user", "content": [{"type": "text", "text": "price?"}]}]})
    assert r.status_code == 200 and "₱350" in r.text and "[DONE]" in r.text
    log = [json.loads(l) for l in capsys.readouterr().out.splitlines() if '"event": "chat"' in l][-1]
    assert log["answer_chars"] == len("Hi! ₱350") and log["success"] is True
    assert log["first_token_ms"] is not None


def test_title_requests_skip_knowledge(client):
    client.post("/v1/chat/completions", headers=AUTH,
                json={"model": "suki-title", "messages": [{"role": "user", "content": "title please"}]})
    assert captured["body"]["messages"][0]["role"] == "user"


def test_upstream_429_is_logged_as_failure(client, capsys):
    r = client.post("/v1/chat/completions", headers=AUTH,
                    json={"model": "suki-salon", "messages": [{"role": "user", "content": "trigger 429"}]})
    assert r.status_code == 429
    log = [json.loads(l) for l in capsys.readouterr().out.splitlines() if '"event": "chat"' in l][-1]
    assert log["success"] is False and log["upstream_status"] == 429


def test_missing_knowledge_fails_closed(client, capsys):
    saved = gw.knowledge.text
    gw.knowledge.text = ""
    try:
        r = client.post("/v1/chat/completions", headers=AUTH,
                        json={"model": "suki-salon", "messages": [{"role": "user", "content": "hi"}]})
        assert r.status_code == 503
        assert client.get("/healthz").status_code == 503
    finally:
        gw.knowledge.text = saved
