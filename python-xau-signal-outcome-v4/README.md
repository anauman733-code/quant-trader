# XAU Python Signal-Outcome V4

Research-only trainer for `XAUUSD.a` using the user's existing Python/MetaTrader5 stack.

## What V4 fixes

- scans the **entire 30-day tick period** instead of stopping after the first N candidates;
- uses strict time-based train / validation / holdout splits (70% / 15% / 15% of the actual date span);
- evaluates Momentum, Pullback and Mean-Reversion independently so Momentum cannot hide the other modes;
- de-duplicates repeated near-identical signals with a per-mode time gap;
- uses deterministic reservoir sampling separately for each split and each mode, so early dates cannot dominate when a cap is reached;
- simulates the current trade lifecycle: 12-second max hold, 100-point SL, 130-point TP and 7-point estimated round-turn commission cost;
- prints the no-ML holdout baseline plus ML threshold tables and only recommends a threshold with at least 50 simulated holdout trades and positive average/total net points.

## Run

Keep MetaTrader 5 open and logged into the demo account, then double-click `TRAIN_SIGNAL_OUTCOME_V4.bat`.

Do not use the saved `xau_signal_outcome_v4.joblib` for demo execution until the holdout tables have been reviewed.
