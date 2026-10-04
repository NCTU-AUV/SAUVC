#!/usr/bin/env python3
"""單一 seed 的新舊批次對照（批次進行中逐次回報用）。

用法：scripts/sim_batch_seed_compare.py <new_batch_dir> <baseline_batch_dir> <seed>

需要兩邊都已跑過 scripts/sim_batch_analyze.py（讀 results.json）。
過門採 SIM_BATCH_FLARE5X_CAM120.md §4 的嚴格定義：軌跡穿越 x=3.5 時內插的
y 在兩柱之間（|Δy| ≤ 0.75）且 z 在門洞內（−1.6 ～ −0.6）。
"""
import json
import re
import sys
from pathlib import Path

GATE_X, HALF_GAP, Z_LO, Z_HI = 3.5, 0.75, -1.6, -0.6
POOL_HALF_X, POOL_HALF_Y = 12.5, 8.0


def load_run(batch: Path, seed: int):
    res = json.load(open(batch / 'results.json'))
    r = next((x for x in res if x['seed'] == seed), None)
    if r is None:
        return None
    run = batch / r['dir']
    P = []
    for line in open(run / 'pose_trace.txt'):
        n = re.findall(r'\[\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*\]', line)
        if len(n) >= 2:
            P.append([float(v) for v in n[0]])
    gate_y = None
    for line in open(run / 'sim.log', errors='ignore'):
        m = re.search(r'Spawned navigation_gate from \w+ at x=([-\d.]+), y=([-\d.]+)', line)
        if m:
            gate_y = float(m.group(2))
    passes = []
    for a, b in zip(P, P[1:]):
        if (a[0] - GATE_X) * (b[0] - GATE_X) < 0:
            f = (GATE_X - a[0]) / (b[0] - a[0])
            y = a[1] + f * (b[1] - a[1])
            z = a[2] + f * (b[2] - a[2])
            ok = abs(y - gate_y) <= HALF_GAP and Z_LO <= z <= Z_HI
            passes.append(('去' if b[0] > a[0] else '回', ok, abs(y - gate_y)))
    wall = min(min(POOL_HALF_X - abs(p[0]), POOL_HALF_Y - abs(p[1])) for p in P) if P else float('nan')
    bumped = sum(1 for p in r['phases'] if p['action'] == 'BumpFlare')
    return {
        't': r['mission_time_s'], 'final': r['final_action'], 'drop': r.get('drop_ball'),
        'bumped': bumped, 'search': r.get('search_share'), 'passes': passes, 'wall': wall,
    }


def fmt_pass(passes, leg):
    xs = [p for p in passes if p[0] == leg]
    if not xs:
        return '—未發生'
    # 只看第一次穿越；多次穿越（衝過頭再折回）另外標記
    _, ok, dy = xs[0]
    extra = f'(+{len(xs) - 1})' if len(xs) > 1 else ''
    return f"{'✓' if ok else '✗'}Δy={dy:.2f}{extra}"


def main():
    new_dir, base_dir, seed = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
    rows = [('本批', load_run(new_dir, seed)), ('baseline', load_run(base_dir, seed))]
    print(f'seed {seed}')
    for name, r in rows:
        if r is None:
            print(f'  {name:8} （無資料）')
            continue
        print(f"  {name:8} {r['t']:6.1f}s  去程{fmt_pass(r['passes'], '去'):12} "
              f"回程{fmt_pass(r['passes'], '回'):12} 投球{'✓' if r['drop'] else '✗'}  "
              f"撞柱段{r['bumped']}  搜尋{r['search']:.0%}  離牆最近{r['wall']:.2f}m  {r['final']}")


if __name__ == '__main__':
    main()
