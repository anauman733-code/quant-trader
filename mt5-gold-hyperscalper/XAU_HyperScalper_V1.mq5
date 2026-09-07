//+------------------------------------------------------------------+
//| XAU_HyperScalper_V1.mq5                                         |
//| Demo-first XAUUSD 10-second scalper for MetaTrader 5             |
//| Native MQL5 execution, percentage-risk sizing, no grid/martingale|
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Demo-first XAUUSD hyper-scalper using synthetic 10-second bars with M1/M5 confirmation and strict risk controls."

#include <Trade/Trade.mqh>

CTrade trade;

//--------------------------- Inputs ---------------------------------
input group "Safety"
input bool   InpDemoOnly                 = true;
input bool   InpEnableTrading            = true;
input long   InpMagicNumber              = 26090810;
input double InpRiskPerTradePct          = 0.10;  // percent of equity
input double InpMaxLots                  = 1.00;
input double InpDailyLossStopPct         = 2.00;  // account-equity guard
input int    InpMaxConsecutiveLosses     = 5;
input int    InpMaxTradesPerHour         = 15;
input int    InpCooldownSeconds          = 20;
input int    InpMaxOpenPositions         = 1;

input group "Execution"
input int    InpMaxSpreadPoints          = 40;
input int    InpSlippagePoints           = 20;
input int    InpMinStopPoints            = 120;
input int    InpMaxStopPoints            = 500;
input double InpATRStopMultiplier        = 0.80;
input double InpRewardRisk               = 1.20;
input int    InpMaxHoldSeconds            = 180;
input bool   InpExitOnOppositeMicroTrend = true;

input group "Synthetic 10-Second Signal"
input int    InpSyntheticSeconds         = 10;
input int    InpMicroFastEMA             = 5;
input int    InpMicroMidEMA              = 13;
input int    InpMicroSlowEMA             = 34;
input int    InpMinMomentumPoints        = 20;
input int    InpMinBarRangePoints        = 25;
input int    InpMaxSyntheticBars         = 400;

input group "Native Timeframe Filters"
input bool   InpUseM1Filter              = true;
input bool   InpUseM5Filter              = true;
input int    InpNativeFastEMA            = 9;
input int    InpNativeSlowEMA            = 21;
input int    InpATRPeriod                = 14;

input group "Session Filter (broker server time)"
input bool   InpUseSessionFilter         = true;
input int    InpSessionStartHour         = 7;
input int    InpSessionStartMinute       = 0;
input int    InpSessionEndHour           = 22;
input int    InpSessionEndMinute         = 0;

input group "Diagnostics"
input bool   InpVerboseLogging           = true;

//--------------------------- Data -----------------------------------
struct MicroBar
{
   datetime start;
   double open;
   double high;
   double low;
   double close;
   long ticks;
};

MicroBar g_currentBar;
bool     g_hasCurrentBar = false;
MicroBar g_bars[];

int g_m1FastHandle = INVALID_HANDLE;
int g_m1SlowHandle = INVALID_HANDLE;
int g_m5FastHandle = INVALID_HANDLE;
int g_m5SlowHandle = INVALID_HANDLE;
int g_atrHandle    = INVALID_HANDLE;

int      g_consecutiveLosses = 0;
datetime g_lastExitTime      = 0;
double   g_dayStartEquity    = 0.0;
string   g_dayEquityKey      = "";

//--------------------------- Utility --------------------------------
void Log(string text)
{
   if(InpVerboseLogging)
      Print("[XAU-HS] ", text);
}

string TodayKey()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string login = IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN));
   return StringFormat("XAUHS_DAY_%s_%04d%02d%02d", login, dt.year, dt.mon, dt.day);
}

void RefreshDayStartEquity()
{
   string key = TodayKey();
   if(key == g_dayEquityKey && g_dayStartEquity > 0.0)
      return;

   g_dayEquityKey = key;
   if(GlobalVariableCheck(key))
      g_dayStartEquity = GlobalVariableGet(key);
   else
   {
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(key, g_dayStartEquity);
   }

   Log(StringFormat("Day-start equity guard: %.2f", g_dayStartEquity));
}

bool IsDemoAllowed()
{
   if(!InpDemoOnly)
      return true;

   ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   return (mode == ACCOUNT_TRADE_MODE_DEMO || mode == ACCOUNT_TRADE_MODE_CONTEST);
}

bool IsSessionOK()
{
   if(!InpUseSessionFilter)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin   = dt.hour * 60 + dt.min;
   int startMin = InpSessionStartHour * 60 + InpSessionStartMinute;
   int endMin   = InpSessionEndHour * 60 + InpSessionEndMinute;

   if(startMin <= endMin)
      return (nowMin >= startMin && nowMin <= endMin);

   return (nowMin >= startMin || nowMin <= endMin);
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPoints <= 0)
      return true;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double spreadPts = (tick.ask - tick.bid) / _Point;
   return (spreadPts <= InpMaxSpreadPoints);
}

int CountOurOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      count++;
   }
   return count;
}

int CountEntriesLastHour()
{
   datetime now = TimeCurrent();
   if(!HistorySelect(now - 3600, now))
      return 0;

   int count = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; ++i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
         count++;
   }
   return count;
}

bool DailyLossGuardOK()
{
   RefreshDayStartEquity();
   if(InpDailyLossStopPct <= 0.0 || g_dayStartEquity <= 0.0)
      return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double floorEquity = g_dayStartEquity * (1.0 - InpDailyLossStopPct / 100.0);
   return (equity > floorEquity);
}

bool RiskGatesOK()
{
   if(!InpEnableTrading)                              return false;
   if(!IsDemoAllowed())                              return false;
   if(!IsSessionOK())                                return false;
   if(!IsSpreadOK())                                 return false;
   if(CountOurOpenPositions() >= InpMaxOpenPositions)return false;
   if(!DailyLossGuardOK())                           return false;
   if(InpMaxConsecutiveLosses > 0 && g_consecutiveLosses >= InpMaxConsecutiveLosses)
      return false;
   if(InpMaxTradesPerHour > 0 && CountEntriesLastHour() >= InpMaxTradesPerHour)
      return false;
   if(InpCooldownSeconds > 0 && g_lastExitTime > 0 && (TimeCurrent() - g_lastExitTime) < InpCooldownSeconds)
      return false;
   return true;
}

//----------------------- Synthetic bars ------------------------------
datetime BucketStart(datetime t, int secondsStep)
{
   int step = MathMax(secondsStep, 1);
   return (datetime)(t - (t % step));
}

void PushClosedBar(const MicroBar &bar)
{
   int n = ArraySize(g_bars);
   if(n < InpMaxSyntheticBars)
   {
      ArrayResize(g_bars, n + 1);
      g_bars[n] = bar;
      return;
   }

   for(int i = 1; i < n; ++i)
      g_bars[i - 1] = g_bars[i];
   g_bars[n - 1] = bar;
}

bool UpdateSyntheticBar()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double mid = (tick.bid + tick.ask) * 0.5;
   datetime bucket = BucketStart(tick.time, InpSyntheticSeconds);

   if(!g_hasCurrentBar)
   {
      g_currentBar.start = bucket;
      g_currentBar.open  = mid;
      g_currentBar.high  = mid;
      g_currentBar.low   = mid;
      g_currentBar.close = mid;
      g_currentBar.ticks = 1;
      g_hasCurrentBar = true;
      return false;
   }

   if(bucket == g_currentBar.start)
   {
      if(mid > g_currentBar.high) g_currentBar.high = mid;
      if(mid < g_currentBar.low)  g_currentBar.low  = mid;
      g_currentBar.close = mid;
      g_currentBar.ticks++;
      return false;
   }

   if(bucket > g_currentBar.start)
   {
      PushClosedBar(g_currentBar);
      g_currentBar.start = bucket;
      g_currentBar.open  = mid;
      g_currentBar.high  = mid;
      g_currentBar.low   = mid;
      g_currentBar.close = mid;
      g_currentBar.ticks = 1;
      return true;
   }

   return false;
}

double MicroEMA(int period, int offset = 0)
{
   int n = ArraySize(g_bars) - offset;
   if(period <= 0 || n <= 0)
      return 0.0;

   double alpha = 2.0 / (period + 1.0);
   double ema = g_bars[0].close;
   for(int i = 1; i < n; ++i)
      ema = alpha * g_bars[i].close + (1.0 - alpha) * ema;
   return ema;
}

int MicroTrend()
{
   int need = MathMax(InpMicroSlowEMA + 3, 40);
   int n = ArraySize(g_bars);
   if(n < need)
      return 0;

   double fast = MicroEMA(InpMicroFastEMA, 0);
   double mid  = MicroEMA(InpMicroMidEMA, 0);
   double slow = MicroEMA(InpMicroSlowEMA, 0);

   double prevFast = MicroEMA(InpMicroFastEMA, 1);
   double prevMid  = MicroEMA(InpMicroMidEMA, 1);

   if(fast > mid && mid > slow && fast > prevFast && mid >= prevMid)
      return 1;
   if(fast < mid && mid < slow && fast < prevFast && mid <= prevMid)
      return -1;
   return 0;
}

bool MicroTriggerOK(int direction)
{
   int n = ArraySize(g_bars);
   if(n < 3 || direction == 0)
      return false;

   const MicroBar &last = g_bars[n - 1];
   const MicroBar &prev = g_bars[n - 2];

   double momentumPts = (last.close - prev.close) / _Point;
   double rangePts    = (last.high - last.low) / _Point;

   if(rangePts < InpMinBarRangePoints)
      return false;

   if(direction > 0)
      return (momentumPts >= InpMinMomentumPoints && last.close > last.open);
   else
      return (momentumPts <= -InpMinMomentumPoints && last.close < last.open);
}

//----------------------- Native filters ------------------------------
bool ReadIndicatorValue(int handle, int shift, double &value)
{
   if(handle == INVALID_HANDLE)
      return false;
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1)
      return false;
   value = buf[0];
   return true;
}

int NativeTrend(int fastHandle, int slowHandle)
{
   double fast = 0.0, slow = 0.0;
   if(!ReadIndicatorValue(fastHandle, 1, fast) || !ReadIndicatorValue(slowHandle, 1, slow))
      return 0;
   if(fast > slow) return 1;
   if(fast < slow) return -1;
   return 0;
}

bool HigherTimeframeFiltersOK(int direction)
{
   if(direction == 0)
      return false;

   if(InpUseM1Filter)
   {
      int m1 = NativeTrend(g_m1FastHandle, g_m1SlowHandle);
      if(m1 != direction)
         return false;
   }

   if(InpUseM5Filter)
   {
      int m5 = NativeTrend(g_m5FastHandle, g_m5SlowHandle);
      if(m5 != direction)
         return false;
   }

   return true;
}

//----------------------- Risk sizing ---------------------------------
double CurrentATRPoints()
{
   double atr = 0.0;
   if(!ReadIndicatorValue(g_atrHandle, 1, atr) || atr <= 0.0)
      return (double)InpMinStopPoints;
   return atr / _Point;
}

int StopDistancePoints()
{
   double raw = CurrentATRPoints() * InpATRStopMultiplier;
   int stopPts = (int)MathRound(raw);
   stopPts = MathMax(stopPts, InpMinStopPoints);
   stopPts = MathMin(stopPts, InpMaxStopPoints);

   int brokerMin = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   stopPts = MathMax(stopPts, brokerMin + 5);
   return stopPts;
}

double NormalizeVolume(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;

   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathMin(lots, InpMaxLots);

   lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < minLot)
      return 0.0;

   int digits = 2;
   if(step >= 1.0) digits = 0;
   else if(step >= 0.1) digits = 1;
   else if(step >= 0.01) digits = 2;
   else digits = 3;
   return NormalizeDouble(lots, digits);
}

double LotsForRisk(int stopPoints)
{
   if(stopPoints <= 0 || InpRiskPerTradePct <= 0.0)
      return 0.0;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPerTradePct / 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   double priceDistance = stopPoints * _Point;
   if(tickSize <= 0.0 || tickValue <= 0.0 || priceDistance <= 0.0)
      return 0.0;

   double lossPerLot = (priceDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;

   return NormalizeVolume(riskMoney / lossPerLot);
}

//----------------------- Trading -------------------------------------
bool OpenTrade(int direction)
{
   if(direction == 0 || !RiskGatesOK())
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   int stopPts = StopDistancePoints();
   int tpPts   = (int)MathRound(stopPts * InpRewardRisk);
   int brokerMin = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   tpPts = MathMax(tpPts, brokerMin + 5);

   double lots = LotsForRisk(stopPts);
   if(lots <= 0.0)
   {
      Log("Entry skipped: calculated lot size is zero.");
      return false;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl = 0.0, tp = 0.0;

   if(direction > 0)
   {
      sl = NormalizeDouble(tick.ask - stopPts * _Point, digits);
      tp = NormalizeDouble(tick.ask + tpPts   * _Point, digits);
   }
   else
   {
      sl = NormalizeDouble(tick.bid + stopPts * _Point, digits);
      tp = NormalizeDouble(tick.bid - tpPts   * _Point, digits);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool sent = false;
   if(direction > 0)
      sent = trade.Buy(lots, _Symbol, 0.0, sl, tp, "XAU-HS BUY");
   else
      sent = trade.Sell(lots, _Symbol, 0.0, sl, tp, "XAU-HS SELL");

   if(!sent)
   {
      Log(StringFormat("Order failed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
      return false;
   }

   Log(StringFormat("OPEN %s lots=%.3f SLpts=%d TPpts=%d", direction > 0 ? "BUY" : "SELL", lots, stopPts, tpPts));
   return true;
}

void CloseOurPositions(string reason)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if(trade.PositionClose(ticket))
         Log("CLOSE #" + IntegerToString((long)ticket) + " reason=" + reason);
      else
         Log(StringFormat("Close failed #%I64u: %u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   }
}

void ManageOpenPositions(int microDirection, bool onNewMicroBar)
{
   bool closeOpposite = false;
   bool closeTime = false;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      if(InpMaxHoldSeconds > 0 && (TimeCurrent() - openTime) >= InpMaxHoldSeconds)
         closeTime = true;

      if(onNewMicroBar && InpExitOnOppositeMicroTrend && microDirection != 0)
      {
         if(type == POSITION_TYPE_BUY  && microDirection < 0) closeOpposite = true;
         if(type == POSITION_TYPE_SELL && microDirection > 0) closeOpposite = true;
      }
   }

   if(closeTime)
      CloseOurPositions("time-stop");
   else if(closeOpposite)
      CloseOurPositions("opposite-micro-trend");
}

void RebuildLossStreak()
{
   g_consecutiveLosses = 0;
   g_lastExitTime = 0;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);

   if(!HistorySelect(dayStart, TimeCurrent()))
      return;

   for(int i = HistoryDealsTotal() - 1; i >= 0; --i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
         continue;

      datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      if(g_lastExitTime == 0)
         g_lastExitTime = t;

      double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_SWAP)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION);

      if(pnl < 0.0)
         g_consecutiveLosses++;
      else
         break;
   }
}

//----------------------- MT5 events ----------------------------------
int OnInit()
{
   if(InpSyntheticSeconds < 2 || InpMicroFastEMA <= 0 || InpMicroMidEMA <= InpMicroFastEMA || InpMicroSlowEMA <= InpMicroMidEMA)
   {
      Print("[XAU-HS] Invalid synthetic/EMA configuration.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpRiskPerTradePct <= 0.0 || InpRiskPerTradePct > 1.0)
   {
      Print("[XAU-HS] Risk per trade must be >0 and <=1.0% in V1.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!IsDemoAllowed())
   {
      Print("[XAU-HS] Demo-only guard blocked initialization on a real account.");
      return INIT_FAILED;
   }

   g_m1FastHandle = iMA(_Symbol, PERIOD_M1, InpNativeFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_m1SlowHandle = iMA(_Symbol, PERIOD_M1, InpNativeSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_m5FastHandle = iMA(_Symbol, PERIOD_M5, InpNativeFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_m5SlowHandle = iMA(_Symbol, PERIOD_M5, InpNativeSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle    = iATR(_Symbol, PERIOD_M1, InpATRPeriod);

   if(g_m1FastHandle == INVALID_HANDLE || g_m1SlowHandle == INVALID_HANDLE ||
      g_m5FastHandle == INVALID_HANDLE || g_m5SlowHandle == INVALID_HANDLE ||
      g_atrHandle == INVALID_HANDLE)
   {
      Print("[XAU-HS] Failed to create indicator handles. Error=", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   RefreshDayStartEquity();
   RebuildLossStreak();

   Log(StringFormat("Initialized on %s. DemoOnly=%s risk=%.2f%% maxTrades/hr=%d", _Symbol, InpDemoOnly ? "true" : "false", InpRiskPerTradePct, InpMaxTradesPerHour));
   Log("Warm-up: EA will wait for enough synthetic bars before trading.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_m1FastHandle != INVALID_HANDLE) IndicatorRelease(g_m1FastHandle);
   if(g_m1SlowHandle != INVALID_HANDLE) IndicatorRelease(g_m1SlowHandle);
   if(g_m5FastHandle != INVALID_HANDLE) IndicatorRelease(g_m5FastHandle);
   if(g_m5SlowHandle != INVALID_HANDLE) IndicatorRelease(g_m5SlowHandle);
   if(g_atrHandle    != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
}

void OnTick()
{
   RefreshDayStartEquity();

   bool newMicroBar = UpdateSyntheticBar();
   int microDirection = MicroTrend();

   ManageOpenPositions(microDirection, newMicroBar);

   if(!newMicroBar)
      return;

   if(microDirection == 0)
      return;

   if(!MicroTriggerOK(microDirection))
      return;

   if(!HigherTimeframeFiltersOK(microDirection))
      return;

   if(!RiskGatesOK())
      return;

   OpenTrade(microDirection);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
      return;

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   g_lastExitTime = TimeCurrent();
   if(pnl < 0.0)
      g_consecutiveLosses++;
   else
      g_consecutiveLosses = 0;

   Log(StringFormat("Exit P/L=%.2f consecutiveLosses=%d", pnl, g_consecutiveLosses));
}
