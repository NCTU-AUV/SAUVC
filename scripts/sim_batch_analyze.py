#!/usr/bin/env python3
"""把 sim_batch.sh 的原始紀錄整理成每次跑的 result.json 與整批的 summary。

用法：
    scripts/sim_batch_analyze.py logs_sim_batch/batch_<...>

資料來源與各自負責的欄位：
    status.jsonl   —— 階段序列（current_action / target_label / target_locked）
                      這是「每個階段的任務執行狀況」的唯一來源
    autonomy.log   —— 撞擊、跳過、投球、flare 順序（BT 節點的成敗只記在 log，
                      status_json 的 current_action 看不到 BumpFlare/SkipFlare）
    pose_trace.txt —— 軌跡衍生量（最遠 x、最深、是否過門）

這支是重寫的。batch_20260918 的原始分析器已經遺失，所以下列 baseline 欄位
**沒有**重建：depth_clamped、breach_pre_finish、move_above、deadline 的明細。
跨批次比較請只用本檔有產出的欄位。
"""
import json
import math
import re
import sys
from pathlib import Path

GATE_X = 3.5            # 閘門在 x = -12.5 + 16.0
LONG_SEARCH_S = 40.0    # 與先前分析一致的「長搜尋」門檻
LOWLOCK = 0.2


def read_status(path):
    """讀 status.jsonl，**只取第一段任務週期**。

    收尾時 kill 的是 host 端的 docker compose exec，容器內的 ros2 topic echo
    並沒有跟著死，會繼續往同一個檔案寫 —— 於是每個 run 的 status.jsonl 裡除了
    自己那次，還接著後面每一次的資料（實測 run_01 累積到 34 MB／156k 行，而單
    次只該有約 3.7k 行）。徵兆是所有 run 的 mission_time_s 會變成同一個數字。

    切割點不能直接用「計時倒退」：任務完成時 mission_time 本來就會歸零，而
    收尾的 MissionComplete 階段正是在歸零之後才發布的（baseline 的該階段
    t_in/t_out 都是 0.0）。所以歸零之後要繼續收，直到計時**再次上升** —— 那
    才是下一次跑真的開始。
    """
    rows = []
    peak = 0.0
    reset = False
    for line in path.read_text(errors='replace').splitlines():
        line = line.strip()
        if not line or line == '---':
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = float(r.get('mission_time') or 0.0)
        if peak > 1.0 and t < peak - 1.0:
            reset = True        # 任務結束，計時歸零
        # 歸零之後，下一次跑的起點以 mission_started 再次為 true 為準。
        # 不能用 mission_time > 1.0：下一次跑最初那一秒的動作列（t=0.1、0.3…）
        # 都還 <= 1.0，會漏進來並蓋掉本次的 MissionComplete 收尾階段。
        if reset and (r.get('mission_started') or t > 1.0):
            break
        if not reset:
            peak = max(peak, t)
        rows.append(r)
    return rows


def build_phases(rows):
    """把逐筆狀態壓成連續的階段區段。

    一個階段 = current_action 維持不變的一段時間。lock 是該段內 target_locked
    為真的比例，flips 是 target_locked 翻轉的次數 —— 後者能分辨「穩定看不到」
    與「時有時無地閃爍」，兩者的成因完全不同。
    """
    phases = []
    cur = None
    for r in rows:
        act = r.get('current_action') or ''
        t = float(r.get('mission_time') or 0.0)
        if not act:
            continue
        if cur is None or act != cur['action']:
            if cur is not None:
                phases.append(cur)
            cur = {'action': act, 't_in': t, 't_out': t,
                   '_n': 0, '_lock': 0, '_flips': 0, '_prev': None,
                   'labels': []}
        cur['t_out'] = t
        cur['_n'] += 1
        locked = bool(r.get('target_locked'))
        cur['_lock'] += 1 if locked else 0
        if cur['_prev'] is not None and locked != cur['_prev']:
            cur['_flips'] += 1
        cur['_prev'] = locked
        lab = r.get('target_label') or ''
        if lab and lab not in cur['labels']:
            cur['labels'].append(lab)
    if cur is not None:
        phases.append(cur)

    out = []
    for p in phases:
        n = max(p['_n'], 1)
        out.append({
            'action': p['action'],
            't_in': round(p['t_in'], 1),
            't_out': round(p['t_out'], 1),
            'dur': round(p['t_out'] - p['t_in'], 1),
            'lock': round(p['_lock'] / n, 3),
            'flips': p['_flips'],
            'labels': p['labels'],
        })
    return out


def parse_autonomy(path):
    txt = path.read_text(errors='replace') if path.exists() else ''
    bumped = re.findall(r'BumpFlare: Successfully bumped \[(\w+)\]', txt)
    skipped = re.findall(r'SkipFlare: Failed to find/align \[(\w+)\]', txt)
    order_m = re.search(r"using default order '(\w+)'", txt)
    drop_m = re.search(r'DropBall: saved drop_pose \(([-\d.]+), ([-\d.]+), ([-\d.]+)\)', txt)
    drop_pose = tuple(float(g) for g in drop_m.groups()) if drop_m else None
    return {
        'bumped': list(dict.fromkeys(bumped)),
        'skipped': list(dict.fromkeys(skipped)),
        'flare_order': order_m.group(1) if order_m else None,
        'order_timeout': bool(order_m),
        'drop_ball': drop_pose is not None,
        'drop_pose_zero': drop_pose is not None and all(abs(v) < 1e-6 for v in drop_pose),
        'surfaced': 'surfacing, mission complete' in txt,
    }


def parse_pose(path):
    pts = []
    if not path.exists():
        return pts
    for line in path.read_text(errors='replace').splitlines():
        b = re.findall(r'\[\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*\]', line)
        if len(b) >= 2:
            pts.append((float(b[0][0]), float(b[0][1]), float(b[0][2]),
                        float(b[1][2])))
    return pts


def analyse_run(run_dir):
    sp = run_dir / 'status.jsonl'
    if not sp.exists():
        return None
    rows = read_status(sp)
    if not rows:
        return None
    phases = build_phases(rows)
    auto = parse_autonomy(run_dir / 'autonomy.log')
    pose = parse_pose(run_dir / 'pose_trace.txt')

    searches = [p for p in phases if p['action'] == 'SearchTarget']
    longs = [p for p in searches if p['dur'] >= LONG_SEARCH_S]
    m = re.match(r'run_(\d+)_seed_(\S+)', run_dir.name)

    res = {
        'seed': int(m.group(2)) if m and m.group(2).isdigit() else None,
        'run': int(m.group(1)) if m else None,
        'dir': run_dir.name,
        'mission_time_s': round(max((float(r.get('mission_time') or 0) for r in rows),
                                    default=0.0), 1),
        'final_action': phases[-1]['action'] if phases else None,
        'mission_complete': any(r.get('mission_complete') for r in rows),
        'blind_forward': sum(1 for p in phases if p['action'] == 'BlindForward'),
        'status_samples': len(rows),
        'traj_samples': len(pose),
        'search_total_s': round(sum(p['dur'] for p in searches), 1),
        # 分母用任務總時長，不能用 phases[-1]['t_out'] —— 最後一段固定是
        # MissionComplete，它的 t_in/t_out 都是 0.0，會讓比例爆成天文數字。
        'search_share': round(sum(p['dur'] for p in searches)
                              / max(max((p['t_out'] for p in phases), default=0.0), 1e-6), 3),
        'long_search_n': len(longs),
        'long_search_s': round(sum(p['dur'] for p in longs), 1),
        'long_search_lowlock': sum(1 for p in longs if p['lock'] < LOWLOCK),
        'long_search_highlock': sum(1 for p in longs if p['lock'] >= LOWLOCK),
        'phases': phases,
    }
    res.update(auto)
    if pose:
        res['max_x'] = round(max(p[0] for p in pose), 3)
        res['deepest_z'] = round(min(p[2] for p in pose), 5)
        res['shallowest_z'] = round(max(p[2] for p in pose), 5)
        res['crossed_gate'] = max(p[0] for p in pose) > GATE_X
    return res


def main(batch_dir):
    batch = Path(batch_dir)
    results = []
    for run_dir in sorted(batch.glob('run_*')):
        r = analyse_run(run_dir)
        if r is None:
            print(f'  ! {run_dir.name}: 沒有可用的 status.jsonl，略過')
            continue
        (run_dir / 'result.json').write_text(
            json.dumps(r, ensure_ascii=False, indent=2), encoding='utf-8')
        results.append(r)
        print(f'  ✓ {run_dir.name}: {r["final_action"]} '
              f'{r["mission_time_s"]}s  bumped={len(r["bumped"])} '
              f'drop={r["drop_ball"]}')
    (batch / 'results.json').write_text(
        json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'\n{len(results)} 次分析完成 → {batch}/results.json')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
