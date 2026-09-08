# Python XAU Multi-Regime V1

Demo-first Python scalping research engine for `XAUUSD.a` using the MetaTrader5 Python package.

## Signal modes
- Momentum burst
- Trend pullback/resumption
- Mean-reversion snapback

## Safety defaults
- Demo execution only (`--execute-demo` is blocked on real accounts)
- 0.01 lot
- One position at a time
- Max spread 15 points
- 100-point hard SL
- 130-point TP
- 12-second max hold
- 350 ms cooldown
- 120 entries/hour cap
- 5-loss streak stop
- Daily balance-loss guard
- IOC filling, matching the tested XAUUSD.a symbol filling flags

## Launch
`START_DRY_RUN.bat` prints signals only.

`START_DEMO_TRADING.bat` sends orders to the connected MT5 demo/contest account.

Keep MT5 open, connected and Algo Trading allowed.

This is research software, not a profitability claim. Forward-test on demo before any live use.
