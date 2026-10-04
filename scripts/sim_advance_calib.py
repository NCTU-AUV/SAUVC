#!/usr/bin/env python3
"""前進掃描校正：量 SearchTarget 在 [advance] 模式下的實際前進速度。

用法：scripts/sim_advance_calib.py <run_dir>

做法：
  status.jsonl 只取第一段任務週期，依 mission_time 找出 debug 含 "[advance"
  的連續區段（區段間隔 > 1 s 就切開）。
  pose_trace.txt 的牆鐘時間以「載具第一次移動」對齊到 mission_time ≈ 0
  （誤差約一個取樣間隔 ~2 s，所以只報 ≥ 5 s 的區段）。
  每段輸出：時長、位移、沿掃描中心方向的前進量、速度。
"""
import json, math, re, sys
from pathlib import Path

run = Path(sys.argv[1])

# ── status：第一段任務週期 ──────────────────────────────────────────────
samples, started = [], False
for line in open(run / 'status.jsonl', errors='ignore'):
    line = line.strip()
    if not line.startswith('{'):
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get('mission_started'):
        started = True
        samples.append(d)
        if d.get('mission_complete'):
            break
    elif started:
        break

# ── advance 區段 ────────────────────────────────────────────────────────
segs, cur = [], None
for d in samples:
    t, dbg = d['mission_time'], d.get('debug', '')
    if '[advance' in dbg:
        if cur and t - cur['t1'] <= 1.0:
            cur['t1'] = t
        else:
            cur = {'t0': t, 't1': t, 'label': d.get('target_label', ''), 'last': dbg}
            segs.append(cur)
        cur['last'] = dbg
modes = {}
for d in samples:
    m = re.search(r'\[(advance|recenter|spin)', d.get('debug', ''))
    if m:
        modes[(d.get('target_label', ''), m.group(1))] = modes.get((d.get('target_label', ''), m.group(1)), 0) + 1

# ── pose ────────────────────────────────────────────────────────────────
P = []
for line in open(run / 'pose_trace.txt'):
    nums = re.findall(r'\[\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*\]', line)
    if len(nums) >= 2:
        P.append((float(line.split()[0]), [float(v) for v in nums[0]], float(nums[1][2])))
x0, y0 = P[0][1][:2]
t_move = next(t for t, xyz, yw in P
              if abs(xyz[0] - x0) > 0.02 or abs(xyz[1] - y0) > 0.02 or abs(yw) > 0.02)
T0 = t_move - 1.0

def pose_at(mt):
    return min(P, key=lambda p: abs(p[0] - (T0 + mt)))

print(f'status 樣本 {len(samples)}，任務時間 {samples[-1]["mission_time"]:.0f}s')
print('模式 tick 數（label, mode）：', {f'{k[0]}/{k[1]}': v for k, v in sorted(modes.items())})
print()
print(f'{"label":10} {"t0":>6} {"dur":>5} {"dx":>6} {"dy":>6} {"dist":>5} {"v":>5}  last debug')
for s in segs:
    dur = s['t1'] - s['t0']
    a, b = pose_at(s['t0']), pose_at(s['t1'])
    dx, dy = b[1][0] - a[1][0], b[1][1] - a[1][1]
    dist = math.hypot(dx, dy)
    v = dist / dur if dur > 0 else float('nan')
    flag = '' if dur >= 5 else '  (短，不採計)'
    print(f'{s["label"]:10} {s["t0"]:6.1f} {dur:5.1f} {dx:+6.2f} {dy:+6.2f} {dist:5.2f} {v:5.2f}  '
          f'{s["last"][-40:]}{flag}')
