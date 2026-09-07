# V2 Validation Plan

## Gate 1 — Compile

- Open `XAU_HyperScalper_V2.mq5` in MetaEditor.
- Press F7.
- Required: 0 errors before testing.
- If warnings appear, review them before forward demo.

## Gate 2 — Mechanical backtest

Use XAUUSD.a / M1 / Every tick based on real ticks.

Run 5 trading days first. Confirm:

- pending BUY STOP / SELL STOP orders are created;
- old pending orders are cancelled/repriced;
- no more than one pending order exists at once;
- no more than one position exists at once;
- hard SL is attached to every filled trade;
- profit-target, micro-trail, reversal and time exits appear in the log;
- no martingale/grid behaviour exists;
- hourly trade cap and loss-streak stop work.

## Gate 3 — One-month baseline

Run one full month with `PRESET_DEMO_MICRO.set` unchanged.

Record:

- total trades;
- trades/hour during enabled session;
- net profit;
- profit factor;
- win rate;
- expected payoff;
- max equity drawdown;
- average winner;
- average loser;
- long/short split;
- consecutive losses.

Do not optimize yet.

## Gate 4 — Diagnostic tuning

Only after the baseline, tune one family at a time:

1. Signal window: lookback ticks, min/max ms.
2. Momentum: net points, recent points, directional ratio.
3. Execution: entry offset, pending age, repricing threshold.
4. Exit: profit target, trail start/giveback, max hold.
5. Session/spread filters.

Do not optimize all parameters simultaneously.

## Gate 5 — Three-month validation

After a candidate configuration is selected, test it on a different 3-month period that was not used for tuning.

Reject the configuration if performance collapses out of sample.

## Gate 6 — Forward demo

Run continuously on the IC Markets demo account and compare:

- backtest fills vs live fills;
- real spread;
- slippage;
- pending-order rejection/cancellation latency;
- live trades/hour;
- live P/L distribution.

Only after these gates should any discussion of live capital occur.
