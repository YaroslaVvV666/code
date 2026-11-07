#!/usr/bin/env python3
"""Пакует Lottie JSON в gzip (как .tgs): python3 pack_emoji.py файл.json [...]. Файл перезаписывается тем же именем."""
import json, gzip, sys
STRIP = {"nm", "mn", "ln", "cl"}
def rnd(o, strip):
    if isinstance(o, dict): return {k: rnd(v, strip) for k, v in o.items() if not (strip and k in STRIP and isinstance(v, str))}
    if isinstance(o, list): return [rnd(v, strip) for v in o]
    if isinstance(o, float):
        r = round(o, 3); return int(r) if r == int(r) else r
    return o
for f in sys.argv[1:]:
    raw = open(f, "rb").read()
    if raw[:2] == b"\x1f\x8b": print(f, "уже сжат"); continue
    t = raw.decode(); d = json.loads(t)
    out = json.dumps(rnd(d, '"x":"' not in t), separators=(",", ":"), ensure_ascii=False).encode()
    open(f, "wb").write(gzip.compress(out, 9, mtime=0)); print(f, len(raw), "->", len(gzip.compress(out, 9, mtime=0)))
