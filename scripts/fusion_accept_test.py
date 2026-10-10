#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fusion 线（8088）最小验收：短问答 + 超窗长题面针测两轮。

用法:
  python3 fusion_accept_test.py                 # 默认 http://127.0.0.1:8088/v1
  python3 fusion_accept_test.py --port 8088 --filler-chars 120000

判据（项目 docs/判据.txt 口径）:
  [1] /v1/models 200
  [2] 7*5 → 35
  [3] 长题面（远超常驻窗口）中段埋针 → 第一轮与追问轮都答出针号
      （超窗时引擎日志应出现 kvmem_score: SELECT …；检索关着会"静默答错"，务必两轮都核）

只做只读 HTTP 调用，不改服务、不改任何现有脚本。
"""
import argparse
import json
import time
import urllib.request

NEEDLE = "NINFER-NEEDLE-7731"


def post(url, payload, timeout=900):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), headers={"content-type": "application/json"}
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.load(resp)
    return body, time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8088)
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("--filler-chars", type=int, default=400000,
                    help="长题面填充字符数（默认 40 万 ≈ 14-15 万 token，确保超过常驻窗口 131072；"
                         "中文约 2.7 字符/token。想快跑就传 120000，但那样题面≈4.4万 token、"
                         "装得进窗口，测不到'设备池装不下题面'的检索路径）")
    ap.add_argument("--window-tokens", type=int, default=131072,
                    help="本档常驻窗口（用于判断题面是否真的超窗；默认 131072）")
    args = ap.parse_args()
    base = "http://%s:%d" % (args.host, args.port)

    # [1] 就绪
    with urllib.request.urlopen(base + "/v1/models", timeout=10) as r:
        models = json.load(r)
    print("[1] /v1/models OK:", [m.get("id") for m in models.get("data", [])])

    # [2] 短问答（关思考，判答案）
    body, dt = post(base + "/v1/chat/completions", {
        "model": args.model,
        "messages": [{"role": "user", "content": "What is 7*5? Reply with the number only."}],
        "max_tokens": 32, "reasoning_effort": "none", "stream": False,
    })
    ans = (body.get("choices", [{}])[0].get("message", {}) or {}).get("content", "")
    print("[2] 7*5 -> %r  (%.1fs, finish=%s)" % (ans.strip()[:40], dt,
          body.get("choices", [{}])[0].get("finish_reason")))

    # [3] 长题面针测：中段埋针，超窗（> 常驻窗口）才能验证检索
    filler = ("这是填充内容，用于把题面推到远超常驻窗口的长度。The quick brown fox jumps over the lazy dog。"
              * ((args.filler_chars // 60) + 1))[: args.filler_chars]
    mid = len(filler) // 2
    long_prompt = (filler[:mid] +
                   f"\n\n【重要记录】本次会话的暗号是 {NEEDLE}，请记住它。\n\n" +
                   filler[mid:] +
                   "\n\n问题：本次会话的暗号是什么？只回答暗号本身。")
    print("[3] 长题面 %d 字符，针在中段；第一轮提问…" % len(long_prompt))
    t0 = time.time()
    body, dt1 = post(base + "/v1/chat/completions", {
        "model": args.model,
        "messages": [{"role": "user", "content": long_prompt}],
        "max_tokens": 256, "reasoning_effort": "none", "stream": False,
    })
    c0 = body.get("choices", [{}])[0]
    a1 = (c0.get("message") or {}).get("content", "")
    u = body.get("usage", {})
    pt = u.get("prompt_tokens") or 0
    over = pt > args.window_tokens
    print("    轮1: %r  finish=%s prompt_tokens=%s  (%.1fs)" %
          (a1.strip()[:60], c0.get("finish_reason"), pt, dt1))
    print("    题面 %s 常驻窗口 %d：%s" %
          ("超过" if over else "未超过", args.window_tokens,
           "✓ 已覆盖'设备池装不下题面'的检索路径" if over else
           "⚠ 本次没测到超窗检索（想测就加大 --filler-chars，如 400000；中文约 2.7 字符/token）"))

    # 追问轮：同一会话前缀（验证 host-backed 复用）
    msgs = [{"role": "user", "content": long_prompt},
            {"role": "assistant", "content": a1},
            {"role": "user", "content": "再确认一遍：暗号是什么？只回答暗号本身。"}]
    body, dt2 = post(base + "/v1/chat/completions", {
        "model": args.model, "messages": msgs,
        "max_tokens": 256, "reasoning_effort": "none", "stream": False,
    })
    c1 = body.get("choices", [{}])[0]
    a2 = (c1.get("message") or {}).get("content", "")
    u2 = body.get("usage", {})
    print("    轮2: %r  finish=%s prompt_tokens=%s  (%.1fs)" %
          (a2.strip()[:60], c1.get("finish_reason"), u2.get("prompt_tokens"), dt2))

    ok = (NEEDLE in a1) and (NEEDLE in a2)
    print("\n结论: 针测两轮 %s（%s）" % ("PASS" if ok else "FAIL",
          "两轮都命中" if ok else "有轮次未命中——先看引擎日志 kvmem_score/SELECT 行与 finish_reason"))
    print("提示: 超窗请求应有 kvmem_score: SELECT … 行；轮2 应见 cache 命中/adopt host-backed 行。")


if __name__ == "__main__":
    main()
