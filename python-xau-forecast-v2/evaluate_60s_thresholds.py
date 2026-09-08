from __future__ import annotations

import argparse
import os
from datetime import datetime, timedelta, timezone

import joblib
import MetaTrader5 as mt5
import numpy as np

from forecast_features import make_features

SYMBOL = 'XAUUSD.a'
MODEL_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'xau_60s_forecast.joblib')


def fetch_ticks(start, end):
    chunks = []
    cur = start
    while cur < end:
        nxt = min(cur + timedelta(days=1), end)
        a = mt5.copy_ticks_range(SYMBOL, cur, nxt, mt5.COPY_TICKS_ALL)
        n = 0 if a is None else len(a)
        print(f'Fetched {cur.date()} -> {nxt.date()} : {n:,} ticks')
        if a is not None and len(a):
            chunks.append(a)
        cur = nxt
    if not chunks:
        raise RuntimeError('No historical ticks returned by MT5')
    return np.concatenate(chunks)


def build_eval_dataset(ticks, point, sample_ms, horizon_ms, max_samples):
    times = ticks['time_msc'].astype(np.int64)
    bids = ticks['bid'].astype(float)
    asks = ticks['ask'].astype(float)
    good = (bids > 0) & (asks > 0) & (asks >= bids)
    times, bids, asks = times[good], bids[good], asks[good]

    duration = max(int(times[-1] - times[0]), 1)
    expected = max(duration // sample_ms, 1)
    eff_sample_ms = max(sample_ms, int(duration / max_samples)) if expected > max_samples else sample_ms
    print(f'Usable ticks: {len(times):,}; effective sample interval: {eff_sample_ms} ms')

    X, buy_moves, sell_moves, sample_times = [], [], [], []
    last_sample = -10**18
    for i in range(50, len(times) - 1):
        t = int(times[i])
        if t - last_sample < eff_sample_ms:
            continue
        j = int(np.searchsorted(times, t + horizon_ms, side='left'))
        if j >= len(times):
            break
        feat = make_features(bids[i-49:i+1], asks[i-49:i+1], times[i-49:i+1], point)
        if feat is None:
            continue
        buy_move = (bids[j] - asks[i]) / point
        sell_move = (bids[i] - asks[j]) / point
        X.append(feat)
        buy_moves.append(buy_move)
        sell_moves.append(sell_move)
        sample_times.append(t)
        last_sample = t

    if not X:
        raise RuntimeError('No evaluation samples built')
    return (
        np.asarray(X, dtype=np.float64),
        np.asarray(buy_moves, dtype=np.float64),
        np.asarray(sell_moves, dtype=np.float64),
        np.asarray(sample_times, dtype=np.int64),
        eff_sample_ms,
    )


def qtile(x, q):
    return float(np.quantile(x, q)) if len(x) else float('nan')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--eval-days', type=int, default=7,
                    help='Strict pre-training out-of-sample days to evaluate')
    ap.add_argument('--commission-points', type=float, default=7.0,
                    help='Estimated round-turn commission in XAU points at 0.01 lot equivalent')
    ap.add_argument('--margin', type=float, default=0.05,
                    help='Required probability lead over opposite direction')
    ap.add_argument('--max-samples', type=int, default=150000)
    args = ap.parse_args()

    if not os.path.exists(MODEL_FILE):
        raise RuntimeError('xau_60s_forecast.joblib not found. Run TRAIN_60S_MODEL.bat first.')

    bundle = joblib.load(MODEL_FILE)
    model = bundle['model']
    train_days = int(bundle.get('days', 14))
    sample_ms = int(bundle.get('sample_ms', 1000))
    horizon_sec = int(bundle.get('horizon_sec', 60))

    if not mt5.initialize():
        raise RuntimeError(f'MT5 initialize failed: {mt5.last_error()}')
    try:
        sym = mt5.symbol_info(SYMBOL)
        if sym is None:
            raise RuntimeError(f'{SYMBOL} unavailable')

        # Strictly older than the model training window, so these samples were not used in training.
        eval_end = datetime.now(timezone.utc) - timedelta(days=train_days)
        eval_start = eval_end - timedelta(days=args.eval_days)
        print('STRICT PRE-TRAINING OOS WINDOW')
        print('Start UTC:', eval_start.isoformat())
        print('End   UTC:', eval_end.isoformat())
        print(f'Horizon: {horizon_sec}s | commission estimate: {args.commission_points:.1f} pts | margin: {args.margin:.2f}')

        ticks = fetch_ticks(eval_start, eval_end)
        X, buy_moves, sell_moves, sample_times, eff = build_eval_dataset(
            ticks, sym.point, sample_ms, horizon_sec * 1000, args.max_samples
        )
        probs = model.predict_proba(X)
        classes = list(model.classes_)
        idx = {int(c): i for i, c in enumerate(classes)}
        p_sell = probs[:, idx[0]] if 0 in idx else np.zeros(len(X))
        p_flat = probs[:, idx[1]] if 1 in idx else np.zeros(len(X))
        p_buy = probs[:, idx[2]] if 2 in idx else np.zeros(len(X))

        hours = max((sample_times[-1] - sample_times[0]) / 3_600_000.0, 1e-9)
        thresholds = [0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85]

        print('\nTHRESHOLD SCREEN — executable 60s move already includes spread')
        print('thr   signals  sig/hr   buy/sell   net-win%  avg-gross  avg-net  med-net   p25-net   p75-net')
        print('-' * 96)

        rows = []
        for thr in thresholds:
            buy_mask = (p_buy >= thr) & ((p_buy - p_sell) >= args.margin) & (p_buy > p_flat)
            sell_mask = (p_sell >= thr) & ((p_sell - p_buy) >= args.margin) & (p_sell > p_flat)
            mask = buy_mask | sell_mask
            n = int(mask.sum())
            if n == 0:
                print(f'{thr:0.2f} {0:9d} {0:7.2f} {0:4d}/{0:<4d}       n/a        n/a      n/a      n/a       n/a       n/a')
                continue

            gross = np.where(buy_mask, buy_moves, np.where(sell_mask, sell_moves, np.nan))[mask]
            net = gross - args.commission_points
            wins = float(np.mean(net > 0.0) * 100.0)
            sig_hr = n / hours
            nb = int(buy_mask.sum()); ns = int(sell_mask.sum())
            avg_gross = float(np.mean(gross)); avg_net = float(np.mean(net)); med = float(np.median(net))
            p25 = qtile(net, 0.25); p75 = qtile(net, 0.75)
            rows.append((thr, n, sig_hr, wins, avg_net, float(np.sum(net))))
            print(f'{thr:0.2f} {n:9d} {sig_hr:7.2f} {nb:4d}/{ns:<4d} {wins:9.2f}% {avg_gross:10.2f} {avg_net:8.2f} {med:8.2f} {p25:9.2f} {p75:9.2f}')

        positive = [r for r in rows if r[4] > 0 and r[1] >= 100]
        print('\nINTERPRETATION')
        if positive:
            fastest = max(positive, key=lambda r: r[2])
            best_avg = max(positive, key=lambda r: r[4])
            print(f'Fastest positive threshold: {fastest[0]:.2f} | {fastest[2]:.2f} signals/hr | avg net {fastest[4]:.2f} pts')
            print(f'Best average-net threshold: {best_avg[0]:.2f} | {best_avg[2]:.2f} signals/hr | avg net {best_avg[4]:.2f} pts')
            print('Use this only to choose V2 forecast gates; overlapping 60s samples are NOT a one-position trading backtest.')
        else:
            print('No threshold had positive average net movement with at least 100 signals on this strict OOS window.')
            print('Do NOT use this model as a live trade gate yet; retraining/feature work is required.')

    finally:
        mt5.shutdown()


if __name__ == '__main__':
    main()
