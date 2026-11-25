#!/usr/bin/env python3
"""
Suki evaluation: sends every labelled question in questions.json through the deployed AI path
(gateway -> knowledge base -> Gemini) and scores the answers with transparent keyword rules.

Standard library only (runs on the EC2 host without pip). Talks to AWS through the aws CLI.

  On the instance (every 12 hours via suki-eval.timer):
      python3 ops/eval/run_eval.py --notify --upload
  On a laptop against the local stack:
      GATEWAY_TOKEN=... python3 ops/eval/run_eval.py --base-url http://127.0.0.1:8080
  Score a saved results file again (no API calls):
      python3 ops/eval/run_eval.py --rescore results.json

What this measures honestly: knowledge base + system prompt + model, through the same gateway the
web app uses. It does NOT test the LibreChat web UI itself (the health check and manual tests do).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent


def norm(text: str) -> str:
    text = text.lower().replace("₱", "").replace("php", "")
    text = re.sub(r"(?<=\d),(?=\d{3})", "", text)       # 1,200 -> 1200
    text = text.replace("’", "'")
    return re.sub(r"\s+", " ", text)


def score(item: dict, answer: str) -> tuple[bool, list[str]]:
    a = norm(answer)
    problems = []
    if not a.strip():
        return False, ["empty answer"]
    for group in item.get("all_of", []):
        if not any(norm(p) in a for p in group):
            problems.append(f"missing one of {group}")
    for bad in item.get("none_of", []):
        if norm(bad) in a:
            problems.append(f"contains forbidden '{bad}'")
    return not problems, problems


def aws(*args: str) -> str:
    return subprocess.run(["aws", *args], check=True, capture_output=True, text=True).stdout.strip()


def ask(base_url: str, token: str, question: str, retries: int = 3) -> tuple[str, int, str | None]:
    body = json.dumps({"model": "suki-salon", "temperature": 0.2, "stream": False,
                       "messages": [{"role": "user", "content": question}]}).encode()
    for attempt in range(retries):
        req = urllib.request.Request(f"{base_url}/v1/chat/completions", data=body, method="POST",
                                     headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                                              "X-Suki-Source": "eval"})
        start = time.time()
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                data = json.load(r)
            ms = int((time.time() - start) * 1000)
            return data["choices"][0]["message"].get("content") or "", ms, None
        except urllib.error.HTTPError as e:
            ms = int((time.time() - start) * 1000)
            if e.code == 429 and attempt < retries - 1:
                time.sleep(30 * (attempt + 1))  # free-tier rate limit: back off and retry
                continue
            return "", ms, f"HTTP {e.code}"
        except Exception as e:  # noqa: BLE001
            return "", int((time.time() - start) * 1000), type(e).__name__
    return "", 0, "retries exhausted"


def summarise(results: list[dict]) -> dict:
    total = len(results)
    passed = sum(r["passed"] for r in results)
    by_cat: dict[str, list[int]] = {}
    for r in results:
        by_cat.setdefault(r["category"], [0, 0])
        by_cat[r["category"]][0] += r["passed"]
        by_cat[r["category"]][1] += 1
    lat = sorted(r["latency_ms"] for r in results if not r.get("error"))
    return {"passed": passed, "total": total, "pass_rate": round(100 * passed / total, 1) if total else 0.0,
            "by_category": {k: f"{v[0]}/{v[1]}" for k, v in sorted(by_cat.items())},
            "median_latency_ms": lat[len(lat) // 2] if lat else None,
            "errors": sum(1 for r in results if r.get("error"))}


def markdown(summary: dict, results: list[dict], meta: dict) -> str:
    lines = [f"# Suki evaluation - {meta['run_at']}", "",
             f"**{summary['passed']} / {summary['total']} passed ({summary['pass_rate']}%)** - "
             f"model `{meta.get('model', '?')}`, app `{meta.get('app_version', '?')}`, "
             f"knowledge `{meta.get('knowledge_version', '?')}`, median latency {summary['median_latency_ms']} ms", "",
             "| Category | Passed |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in summary["by_category"].items()]
    lines += ["", "| ID | Category | Pass | Question | Answer (first 160 chars) | Why it failed |", "|---|---|---|---|---|---|"]
    for r in results:
        ans = r["answer"].replace("\n", " ").replace("|", "/")[:160]
        lines.append(f"| {r['id']} | {r['category']} | {'✅' if r['passed'] else '❌'} | {r['question']} | {ans} | "
                     f"{'; '.join(r['problems']) or ''} |")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=os.getenv("SUKI_GATEWAY_URL", "http://127.0.0.1:8080"))
    ap.add_argument("--questions", default=str(HERE / "questions.json"))
    ap.add_argument("--delay", type=float, default=7.0, help="seconds between questions (free tier ~10 req/min)")
    ap.add_argument("--out", default="/var/log/suki/eval" if Path("/var/log/suki").exists() else str(HERE / "results"))
    ap.add_argument("--upload", action="store_true", help="upload results to s3://<bucket>/eval/ and put the EvalPassRate metric")
    ap.add_argument("--notify", action="store_true", help="e-mail the summary through the SNS alert topic")
    ap.add_argument("--rescore", help="re-score an existing results JSON instead of calling the model")
    args = ap.parse_args()

    items = json.loads(Path(args.questions).read_text(encoding="utf-8"))["questions"]
    run_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    meta: dict = {"run_at": run_at}

    if args.rescore:
        old = json.loads(Path(args.rescore).read_text(encoding="utf-8"))
        answers = {r["id"]: r for r in old["results"]}
        meta.update({k: old.get("meta", {}).get(k) for k in ("model", "app_version", "knowledge_version")})
    else:
        token = os.getenv("GATEWAY_TOKEN")
        prefix = os.getenv("PARAM_PREFIX", "/suki/prod")
        if not token:
            token = aws("ssm", "get-parameter", "--name", f"{prefix}/GATEWAY_TOKEN", "--with-decryption",
                        "--query", "Parameter.Value", "--output", "text")
        try:
            with urllib.request.urlopen(f"{args.base_url}/healthz", timeout=5) as r:
                h = json.load(r)
            meta.update(app_version=h.get("app_version"), knowledge_version=h.get("knowledge_version"))
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"event": "eval", "result": "gateway_unreachable", "error": str(e)}))
        try:
            meta["model"] = aws("ssm", "get-parameter", "--name", f"{prefix}/GEMINI_MODEL", "--query",
                                "Parameter.Value", "--output", "text")
        except Exception:  # noqa: BLE001
            meta["model"] = os.getenv("GEMINI_MODEL", "unknown")
        answers = {}
        for i, item in enumerate(items):
            text, ms, err = ask(args.base_url, token, item["question"])
            answers[item["id"]] = {"answer": text, "latency_ms": ms, "error": err}
            if i < len(items) - 1:
                time.sleep(args.delay)

    results = []
    for item in items:
        a = answers.get(item["id"], {"answer": "", "latency_ms": 0, "error": "not run"})
        ok, problems = score(item, a["answer"])
        if a.get("error"):
            problems = [a["error"]] + problems
        results.append({"id": item["id"], "category": item["category"], "question": item["question"],
                        "answer": a["answer"], "latency_ms": a["latency_ms"], "error": a.get("error"),
                        "passed": ok, "problems": problems})
    summary = summarise(results)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    stamp = run_at.replace(":", "").replace("-", "")
    jpath, mpath = out / f"eval-{stamp}.json", out / f"eval-{stamp}.md"
    jpath.write_text(json.dumps({"meta": meta, "summary": summary, "results": results}, ensure_ascii=False, indent=2),
                     encoding="utf-8")
    mpath.write_text(markdown(summary, results, meta), encoding="utf-8")
    print(json.dumps({"ts": run_at, "event": "eval", "result": "ok", **summary, **meta, "file": str(jpath)}, ensure_ascii=False))

    if args.upload:
        bucket = os.environ["CONTENT_BUCKET"]
        day = run_at[:10].replace("-", "/")
        aws("s3", "cp", "--quiet", str(jpath), f"s3://{bucket}/eval/{day}/{jpath.name}")
        aws("s3", "cp", "--quiet", str(mpath), f"s3://{bucket}/eval/{day}/{mpath.name}")
        aws("cloudwatch", "put-metric-data", "--namespace", "Suki", "--metric-data",
            f"MetricName=EvalPassRate,Value={summary['pass_rate']},Unit=Percent")
    if args.notify:
        failed = [r for r in results if not r["passed"]]
        msg = (f"Suki scheduled test run {run_at}\n\nPassed {summary['passed']}/{summary['total']} "
               f"({summary['pass_rate']}%). Median latency {summary['median_latency_ms']} ms.\n"
               f"By category: {summary['by_category']}\n\nFailed:\n" +
               "\n".join(f"- {r['id']} {r['question']} -> {'; '.join(r['problems'])}" for r in failed))
        aws("sns", "publish", "--topic-arn", os.environ["ALERT_TOPIC_ARN"],
            "--subject", f"Suki test run: {summary['pass_rate']}% passed", "--message", msg[:60000])
    return 0


if __name__ == "__main__":
    sys.exit(main())
