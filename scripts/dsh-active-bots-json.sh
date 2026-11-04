#!/bin/bash
# DSH 当前工作 Bot → JSON。头像 shape/color 完全复刻 DSH 原生算法（按 bot.id 派生）
# 数据源: ~/.dsh/bot/inflight.json + ~/.dsh/bot/state.json

STATE="$HOME/.dsh/bot/state.json"
INFLIGHT="$HOME/.dsh/bot/inflight.json"

[ -f "$STATE" ] || { echo '{"active":[]}'; exit 0; }
[ -f "$INFLIGHT" ] || { echo '{"active":[]}'; exit 0; }

export STATE INFLIGHT
/usr/bin/python3 - <<'PY'
import json, os, time

state = json.load(open(os.environ["STATE"]))
try:
    infl = json.load(open(os.environ["INFLIGHT"]))
except Exception:
    infl = {"turns": {}, "queued": {}}

# ===== 复刻 ds-bot/client.js 的派生算法 =====
DEFAULT_SHAPES = ["star","moon","gumdrop","peanut","bunny","kitty","acorn"]
# CHARACTER_COLORS 去掉 black/gray/brown 和 GRADIENTS(aurora):
DEFAULT_COLORS = ["red","orange","yellow","green","cyan","blue","violet","magenta"]
COLOR_HEX = {
    'red':'#FF453A','orange':'#FF9F0A','yellow':'#FFD60A','green':'#30D158',
    'cyan':'#64D2FF','blue':'#0A84FF','violet':'#BF5AF2','magenta':'#FF375F',
    'deepseek':'#4D6BFE','black':'#3A3A3C','gray':'#8E8E93','brown':'#AC8E68',
    'aurora':'#5AC8FA','charcoal':'#36454F','graphite':'#41424C','rose':'#F5ACB9',
    'sky':'#7EC8E3','tangerine':'#FF7F50','cobalt':'#0047AB',
}

def fnv1a(text):
    v = 2166136261
    for ch in text:
        v = ((v ^ ord(ch)) * 16777619) & 0xFFFFFFFF
    return v

def u32(x): return x & 0xFFFFFFFF
def i32(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x >= 0x80000000 else x
def imul(a, b): return i32((i32(a) * i32(b)) & 0xFFFFFFFF)

def default_shape(idv):
    v = i32(fnv1a(idv))
    v = i32(imul(v ^ (u32(v) >> 16), 73244475))
    v = i32(imul(v ^ (u32(v) >> 13), 3266489909))
    idx = ((v ^ (u32(v) >> 16)) & 0xFFFFFFFF) % len(DEFAULT_SHAPES)
    return DEFAULT_SHAPES[idx]

def default_color_name(idv):
    t = i32((fnv1a(idv) + 1831565813) & 0xFFFFFFFF)
    a = i32(t ^ (u32(t) >> 15))
    b = (1 | t) & 0xFFFFFFFF
    n = imul(a, b)
    part = imul(i32(n ^ (u32(n) >> 7)), (61 | n))
    n = i32((n + part) ^ n)
    idx = u32(i32(n ^ (u32(n) >> 14)))
    return DEFAULT_COLORS[int(idx / 4294967296 * len(DEFAULT_COLORS))]

def is_hex(c):
    if not isinstance(c, str) or len(c) != 7 or not c.startswith('#'): return False
    try:
        int(c[1:], 16); return True
    except: return False

def abbr(name):
    if any('\u4e00' <= ch <= '\u9fff' for ch in name):
        return name[:4]
    return name[:4].upper()

def look_of(bot_id, bot):
    """完全照 lookOf(bot): 有合法 avatar.shape 用它的；否则 defaultShape(bot.id)"""
    av = bot.get("avatar") if isinstance(bot.get("avatar"), dict) else {}
    shape = av.get("shape")
    if shape in ("whale","star","moon","wave","squircle","zed","hex",
                 "gumdrop","peanut","saucer","bunny","kitty","beacon","plus",
                 "magnet","acorn","pebbles","cushion","ring","gem"):
        s = shape
    else:
        s = default_shape(bot_id)  # ← 用 bot.id, 与界面一致
    # color: 有合法 hex/color 名则用之，否则 defaultColor(bot.id)
    c = bot.get("color")
    if c and (is_hex(c) or c in COLOR_HEX):
        chex = c if is_hex(c) else COLOR_HEX[c]
    else:
        chex = COLOR_HEX[default_color_name(bot_id)]
    return s, chex

sid2info = {}
for bid, b in state.get("bots", {}).items():
    shape, color = look_of(bid, b)
    info = {"id": bid, "sessionId": b.get("sessionId") or bid, "name": b.get("name") or "?", "abbr": abbr(b.get("name") or "?"),
            "color": color, "shape": shape}
    sid2info[bid] = info
    for seg in b.get("segments", []) or []:
        if seg.get("sessionId"): sid2info[seg["sessionId"]] = info
    if b.get("sessionId"): sid2info[b["sessionId"]] = info

now = time.time() * 1000
active = []
for sid, t in (infl.get("turns") or {}).items():
    info = sid2info.get(sid, {"name": "未知", "abbr": "未知", "color": "#8E8E93", "shape": "star", "id": sid})
    since = t.get("since") or now
    sec = int((now - since) / 1000)
    active.append({"id": info.get("id", sid), "sessionId": info.get("sessionId", sid), "name": info["name"], "abbr": info["abbr"], "color": info["color"], "shape": info["shape"], "sec": sec, "state": "working"})

# 全部 bot 列表: 活跃的标 working 并带 sec/更新顺序, 其余 idle
active_ids = {a["id"] for a in active}
allbots = []
for bid, b in state.get("bots", {}).items():
    info = sid2info.get(bid)
    if not info: continue
    is_active = bid in {sid2info.get(s,{}).get("id") for s in (infl.get("turns") or {})}
    entry = {"id": info["id"], "sessionId": info.get("sessionId", bid), "name": info["name"],
             "abbr": info["abbr"], "color": info["color"], "shape": info["shape"]}
    if is_active:
        # 找它 sec
        a = next((x for x in active if x["id"]==info["id"]), None)
        entry["state"]="working"; entry["sec"]=a["sec"] if a else 0
    else:
        entry["state"]="idle"; entry["sec"]=0
    allbots.append(entry)
# 排序: working 在前(sec 大的更前), idle 在后
allbots.sort(key=lambda e: (0 if e["state"]=="working" else 1, -e.get("sec",0)))

print(json.dumps({"active": active, "all": allbots, "queued": len(infl.get("queued") or {})}, ensure_ascii=False))
PY
