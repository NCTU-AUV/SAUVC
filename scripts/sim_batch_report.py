#!/usr/bin/env python3
"""產出批次的階段執行報告，並可對照另一批（baseline）。

用法：
    scripts/sim_batch_report.py <batch_dir> [--baseline <batch_dir>]

回答的問題是「每個階段的任務執行狀況」：
  1. 每次跑的階段序列
  2. 跨全部有效次數，各階段花了多少時間、鎖定率如何
  3. 任務層級的成果（過門／撞擊／投球）與 baseline 的差異

「有效」的定義：mission_started 真的為 true、而且有階段序列。啟動失敗或
解鎖失敗的次數會被排除並明確列出 —— 把它們混進統計會把成功率稀釋成
無意義的數字（見 batch_flare5x_cam120 早期那兩次「看似完整實則沒動」的跑）。
"""
import argparse
import json
import statistics as st
from collections import defaultdict
from pathlib import Path


def load(batch_dir):
    """讀入一批的 result.json，分成有效與無效兩堆。"""
    good, bad = [], []
    for f in sorted(Path(batch_dir).glob('run_*/result.json')):
        r = json.load(f.open())
        if r.get('phases') and r.get('mission_time_s', 0) > 0:
            good.append(r)
        else:
            bad.append(r)
    return good, bad


def phase_table(runs):
    """各 action 的彙總：出現次數、總時間、時間佔比、鎖定率中位數。"""
    agg = defaultdict(lambda: {'n': 0, 'dur': 0.0, 'locks': [], 'flips': 0})
    total = 0.0
    for r in runs:
        for p in r['phases']:
            a = agg[p['action']]
            a['n'] += 1
            a['dur'] += p['dur']
            a['flips'] += p['flips']
            if p['dur'] > 0:
                a['locks'].append(p['lock'])
            total += p['dur']
    rows = []
    for act, a in agg.items():
        rows.append({
            'action': act,
            'n': a['n'],
            'dur': a['dur'],
            'share': a['dur'] / total if total else 0.0,
            'lock': st.median(a['locks']) if a['locks'] else float('nan'),
            'flips': a['flips'],
        })
    return sorted(rows, key=lambda r: -r['dur']), total


def outcomes(runs):
    n = len(runs)
    if not n:
        return {}
    return {
        'n': n,
        'crossed_gate': sum(1 for r in runs if r.get('crossed_gate')),
        'drop_ball': sum(1 for r in runs if r.get('drop_ball')),
        'bumped_mean': st.mean(len(r.get('bumped', [])) for r in runs),
        'bumped_all3': sum(1 for r in runs if len(r.get('bumped', [])) == 3),
        'bumped_none': sum(1 for r in runs if not r.get('bumped')),
        'mission_time': st.mean(r['mission_time_s'] for r in runs),
        # baseline 的 result.json 沒有 search_share（舊分析器沒產），
        # 用 search_total_s / mission_time_s 現算，兩批才是同一個定義。
        'search_share': st.mean(
            r['search_share'] if 'search_share' in r
            else r.get('search_total_s', 0) / max(r['mission_time_s'], 1e-6)
            for r in runs),
        'long_lowlock': sum(r.get('long_search_lowlock', 0) for r in runs),
        'long_n': sum(r.get('long_search_n', 0) for r in runs),
    }


def fmt_pct(a, b):
    return f'{a}/{b} ({100 * a / b:.0f}%)' if b else '—'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('batch')
    ap.add_argument('--baseline')
    args = ap.parse_args()

    good, bad = load(args.batch)
    print(f'# 批次階段報告：{Path(args.batch).name}\n')
    print(f'有效 {len(good)} 次，無效 {len(bad)} 次')
    if bad:
        print('  無效的次數（未納入任何統計）：')
        for r in bad:
            print(f"    {r.get('dir')}  mission_time={r.get('mission_time_s')} "
                  f"階段數={len(r.get('phases', []))}")
    if not good:
        print('\n沒有有效資料，停止。')
        return

    # ── 1. 各階段彙總 ──────────────────────────────────────────────────────
    rows, total = phase_table(good)
    print(f'\n## 1. 各階段彙總（{len(good)} 次合計 {total:.0f} 秒）\n')
    print(f"{'階段':<20}{'次數':>6}{'總時間':>10}{'佔比':>8}{'lock中位':>10}{'翻轉':>7}")
    print('-' * 61)
    for r in rows:
        lock = '—' if r['lock'] != r['lock'] else f"{r['lock']:.3f}"
        print(f"{r['action']:<20}{r['n']:>6}{r['dur']:>9.0f}s{r['share']*100:>7.1f}%"
              f"{lock:>10}{r['flips']:>7}")

    # ── 2. 任務成果 ────────────────────────────────────────────────────────
    cur = outcomes(good)
    base = None
    if args.baseline:
        bgood, _ = load(args.baseline)
        base = outcomes(bgood)

    print('\n## 2. 任務成果' + (f'（對照 {Path(args.baseline).name}）' if base else '') + '\n')
    hdr = f"{'指標':<20}{'本批':>18}"
    if base:
        hdr += f"{'baseline':>18}"
    print(hdr)
    print('-' * (38 + (18 if base else 0)))

    def row(label, key, fmt):
        a = fmt(cur)
        line = f'{label:<20}{a:>18}'
        if base:
            line += f'{fmt(base):>18}'
        print(line)

    row('有效次數', 'n', lambda d: str(d['n']))
    row('過門', 'crossed_gate', lambda d: fmt_pct(d['crossed_gate'], d['n']))
    row('投球成功', 'drop_ball', lambda d: fmt_pct(d['drop_ball'], d['n']))
    row('撞倒 flare 平均', 'bumped_mean', lambda d: f"{d['bumped_mean']:.2f} 根")
    row('撞倒全部 3 根', 'bumped_all3', lambda d: fmt_pct(d['bumped_all3'], d['n']))
    row('一根都沒撞到', 'bumped_none', lambda d: fmt_pct(d['bumped_none'], d['n']))
    row('任務時間平均', 'mission_time', lambda d: f"{d['mission_time']:.0f} s")
    row('搜尋佔任務時間', 'search_share', lambda d: f"{d['search_share']*100:.0f}%")
    row('長搜尋低鎖定段', 'long_lowlock',
        lambda d: fmt_pct(d['long_lowlock'], d['long_n']))

    # ── 3. 每次跑的階段序列 ────────────────────────────────────────────────
    print('\n## 3. 每次跑的階段序列\n')
    for r in good:
        print(f"### seed {r['seed']} — {r['final_action']} / {r['mission_time_s']:.0f}s "
              f"/ 撞倒 {len(r.get('bumped', []))} 根 / 投球 {r.get('drop_ball')}")
        print(f"{'  階段':<20}{'進入':>9}{'離開':>9}{'歷時':>9}{'lock':>7}{'翻轉':>6}  標的")
        for p in r['phases']:
            if p['dur'] < 1.0 and p['action'] != 'MissionComplete':
                continue    # 略過一閃即逝的過渡段，否則序列會被雜訊淹沒
            labs = ','.join(p['labels']) if p['labels'] else '—'
            print(f"  {p['action']:<18}{p['t_in']:>8.1f}s{p['t_out']:>8.1f}s"
                  f"{p['dur']:>8.1f}s{p['lock']:>7.2f}{p['flips']:>6}  {labs}")
        print()


if __name__ == '__main__':
    main()
