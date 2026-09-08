XAU Python V5 — Direct Tick-State Edge Discovery

Purpose:
- Abandons the negative Momentum/Pullback/Mean-Reversion hard-coded entry families.
- Samples the full XAUUSD.a tick stream instead.
- Learns BUY / FLAT / SELL directly from quote-state features.
- Tests 5s, 10s, 20s and 30s horizons.
- Uses strict train / validation / untouched holdout time splits.
- Chooses configuration on validation only, then evaluates it once on holdout.
- Requires at least 5 trades/hour and >=100 trades before a candidate can pass.
- Executable bid/ask includes spread. An estimated 7-point round-turn commission is subtracted.

Run:
1. Keep MT5 open on DEMO.
2. Double-click TRAIN_DIRECT_EDGE_V5.bat.
3. When finished, upload V5_RESULTS.txt to ChatGPT.

This is research/demo-only. It does not place trades.
