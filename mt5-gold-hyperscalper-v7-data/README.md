# XAU HyperScalper V7 DATA

This EA does **not trade**. It is a real-tick research logger built from the V6 FAST_QUALITY candidate engine so we can measure which XAUUSD microstructure setups actually have positive forward expectancy before building V7 Trading.

## What it records

For each confirmed candidate signal it stores:

- direction and signal timestamp
- executable bid/ask and spread
- 2-bar M1 range width/high/low
- breakout level and chase distance
- 3-tick burst size and velocity
- 10/20/32-tick directional momentum
- 10/20/32-tick directional bias and pressure
- 32-tick range and average absolute tick move
- M1 ATR(14)
- executable forward move at 1s, 3s, 5s, 10s and 20s
- MFE and MAE at each horizon

Forward outcomes include spread cost: BUY observations enter conceptually at Ask and mark exits at Bid; SELL observations enter at Bid and mark exits at Ask.

## MT5 test

1. Compile `XAU_HyperScalper_V7_DATA.mq5`.
2. Load `PRESET_V7_DATA.set`.
3. Strategy Tester:
   - Symbol: `XAUUSD.a`
   - Timeframe: `M1`
   - Model: **Every tick based on real ticks**
   - Period: start with **3 months**; then extend to 6 months if successful
   - Deposit is irrelevant because the EA does not trade
4. Run a single test, not Optimization.

## CSV location

The EA writes to the MetaTrader common files folder so the tester-agent sandbox does not hide the output.

Default file:

`XAU_V7_SIGNALS.csv`

Typical Windows location:

`%APPDATA%\MetaQuotes\Terminal\Common\Files\XAU_V7_SIGNALS.csv`

The exact path is also printed in the Experts/Journal when the EA initializes.

When the test finishes, upload the CSV to ChatGPT for feature/expectancy analysis.

## Important

This is a research/data-collection EA. It has no order-send code and makes no profitability claim.
