//+------------------------------------------------------------------+
//| XAU_HyperScalper_V4.mq5                                         |
//| Quality-first XAUUSD scalper for MetaTrader 5                   |
//| Trend/regime + adaptive tick impulse + passive pullback LIMIT    |
//+------------------------------------------------------------------+
#property strict
#property version   "4.00"
#property description "Demo-first XAUUSD quality scalper using multi-factor regime confirmation and passive pullback LIMIT entries."

#include <Trade/Trade.mqh>

CTrade trade;

#define MAX_TICK_BUFFER 192

//--------------------------- Inputs ---------------------------------
input group "Safety"
input bool   InpDemoOnly                         = true;
input bool   InpEnableTrading                    = true;
input long   InpMagicNumber                      = 26090840;
input double InpRiskPerTradePct                  = 0.12;   // desired % equity risk
input bool   InpAllowMinLotFloor                 = true;   // allow broker min lot only inside effective-risk cap
input double InpMaxEffectiveRiskPctAtMinLot      = 0.18;   // hard cap if min lot exceeds desired risk
input double InpMaxLots                          = 0.03;
input double InpDailyLossStopPct                 = 1.00;
input int    InpMaxConsecutiveLosses             = 3;
input int    InpMaxTradesPerHour                 = 12;
input int    InpCooldownAfterExitMs              = 3000;
input int    InpMaxOpenPositions                 = 1;

input group "Execution / Cost Control"
input int    InpMaxSpreadPoints                  = 14;
input double InpMinTargetToSpreadRatio           = 4.00;
input int    InpPendingMaxAgeMs                  = 4500;
input int    InpMinOrderActionIntervalMs         = 300;
input int    InpSlippagePointsForClose           = 20;
input int    InpExtraPassivePoints               = 2;

input group "Adaptive Tick Impulse"
input int    InpLookbackTicks                    = 24;
input int    InpMinTickWindowMs                  = 350;
input int    InpMaxTickWindowMs                  = 2200;
input double InpMinImpulsePoints                 = 10.0;
input double InpImpulseAtrFraction               = 0.08;   // adaptive threshold = max(min, ATR * fraction)
input double InpMinDirectionalRatio              = 0.70;
input double InpStrongDirectionalRatio           = 0.82;
input double InpMinRecentMomentumPoints          = 4.0;
input double InpMinRecentMomentumShare           = 0.35;
input int    InpConfirmationsRequired            = 2;
input int    InpConfirmationWindowMs             = 1200;
input int    InpSignalRearmMs                    = 2200;

input group "M1 / M5 Quality Regime"
input int    InpFastEmaPeriod                    = 9;
input int    InpSlowEmaPeriod                    = 21;
input bool   InpRequireM5Confirmation            = true;
input double InpMinM1EmaGapPoints                = 10.0;
input double InpMinM5EmaGapPoints                = 4.0;
input double InpMinFastEmaSlopePoints            = 1.0;
input int    InpAtrPeriod                        = 14;
input double InpMinAtrPoints                     = 45.0;
input double InpMaxAtrPoints                     = 350.0;
input bool   InpRequireADX                       = true;
input int    InpAdxPeriod                        = 14;
input double InpMinADX                           = 16.0;
input double InpMinClosedCandleBodyRatio         = 0.25;
input int    InpMinQualityScore                  = 6;

input group "Passive Pullback Entry"
input double InpPullbackFractionOfImpulse        = 0.35;
input int    InpMinPullbackPoints                = 5;
input int    InpMaxPullbackPoints                = 28;

input group "Stop / Target"
input double InpStopAtrFraction                  = 0.75;
input int    InpMinStopPoints                    = 70;
input int    InpMaxStopPoints                    = 150;
input double InpRewardRisk                       = 1.25;
input int    InpMaxTargetPoints                  = 220;

input group "Position Management"
input double InpBreakEvenAtR                     = 0.55;
input int    InpBreakEvenLockPoints              = 3;
input double InpTrailStartR                      = 0.80;
input int    InpTrailDistancePoints              = 18;
input int    InpMinModifyIntervalMs              = 500;
input int    InpMaxHoldSeconds                   = 35;
input int    InpStaleLossSeconds                 = 10;
input double InpStaleLossR                       = 0.30;
input bool   InpExitOnConfirmedReversal          = true;
input int    InpMinHoldBeforeReversalMs          = 1200;

input group "Session Filter (broker server time)"
input bool   InpUseSessionFilter                 = true;
input int    InpSessionStartHour                 = 7;
input int    InpSessionStartMinute               = 0;
input int    InpSessionEndHour                   = 22;
input int    InpSessionEndMinute                 = 0;

input group "Diagnostics"
input bool   InpVerboseLogging                   = true;
input int    InpHeartbeatSeconds                 = 10;

//--------------------------- State ----------------------------------
double g_tickMid[MAX_TICK_BUFFER];
long   g_tickMs[MAX_TICK_BUFFER];
int    g_tickCount = 0;
int    g_tickHead  = 0;

long   g_lastOrderActionMs   = 0;
long   g_lastExitMs          = 0;
long   g_lastHeartbeatMs     = 0;
long   g_lastModifyMs        = 0;
long   g_lastConfirmedMs     = 0;

int    g_candidateDir        = 0;
int    g_candidateCount      = 0;
long   g_candidateStartMs    = 0;

ulong  g_trackedPositionTicket = 0;
double g_peakProfitPoints       = 0.0;
double g_positionRiskPoints     = 0.0;

int    g_consecutiveLosses   = 0;
double g_dayStartEquity      = 0.0;
string g_dayEquityKey        = "";

int g_emaFastM1 = INVALID_HANDLE;
int g_emaSlowM1 = INVALID_HANDLE;
int g_emaFastM5 = INVALID_HANDLE;
int g_emaSlowM5 = INVALID_HANDLE;
int g_atrM1     = INVALID_HANDLE;
int g_adxM1     = INVALID_HANDLE;

//--------------------------- Logging --------------------------------
void Log(const string text)
{
   if(InpVerboseLogging)
      Print("[XAU-HS4] ", text);
}

string DirText(const int dir)
{
   if(dir > 0) return "BUY";
   if(dir < 0) return "SELL";
   return "NONE";
}

//--------------------------- Environment -----------------------------
bool IsDemoAllowed()
{
   if(!InpDemoOnly) return true;
   if(MQLInfoInteger(MQL_TESTER)) return true;
   ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   return (mode == ACCOUNT_TRADE_MODE_DEMO || mode == ACCOUNT_TRADE_MODE_CONTEST);
}

bool IsFullTradeSymbol()
{
   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   return (mode == SYMBOL_TRADE_MODE_FULL);
}

bool IsSessionOK()
{
   if(!InpUseSessionFilter) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin   = dt.hour * 60 + dt.min;
   int startMin = InpSessionStartHour * 60 + InpSessionStartMinute;
   int endMin   = InpSessionEndHour * 60 + InpSessionEndMinute;

   if(startMin <= endMin)
      return (nowMin >= startMin && nowMin <= endMin);
   return (nowMin >= startMin || nowMin <= endMin);
}

double CurrentSpreadPoints()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return 999999.0;
   return (tick.ask - tick.bid) / _Point;
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   return (CurrentSpreadPoints() <= InpMaxSpreadPoints);
}

//--------------------------- Day / risk guards -----------------------
string TodayKey()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   return StringFormat("XAUHS4_%I64d_%I64d_%04d%02d%02d", login, InpMagicNumber, dt.year, dt.mon, dt.day);
}

void RefreshDayStartEquity()
{
   string key = TodayKey();
   if(key == g_dayEquityKey && g_dayStartEquity > 0.0)
      return;

   g_dayEquityKey = key;

   if(MQLInfoInteger(MQL_TESTER))
   {
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      return;
   }

   if(GlobalVariableCheck(key))
      g_dayStartEquity = GlobalVariableGet(key);
   else
   {
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(key, g_dayStartEquity);
   }

   Log(StringFormat("Day-start equity %.2f", g_dayStartEquity));
}

bool DailyLossGuardOK()
{
   RefreshDayStartEquity();
   if(InpDailyLossStopPct <= 0.0 || g_dayStartEquity <= 0.0) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double floorEquity = g_dayStartEquity * (1.0 - InpDailyLossStopPct / 100.0);
   return (equity > floorEquity);
}

int CountEntriesLastHour()
{
   datetime now = TimeCurrent();
   if(!HistorySelect(now - 3600, now)) return 0;

   int count = 0;
   for(int i = 0; i < HistoryDealsTotal(); ++i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT) count++;
   }
   return count;
}

void RebuildLossStreak()
{
   g_consecutiveLosses = 0;
   g_lastExitMs = 0;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);
   if(!HistorySelect(dayStart, TimeCurrent())) return;

   for(int i = HistoryDealsTotal() - 1; i >= 0; --i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT) continue;

      long tms = (long)HistoryDealGetInteger(deal, DEAL_TIME_MSC);
      if(g_lastExitMs == 0) g_lastExitMs = tms;

      double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_SWAP)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION);

      if(pnl < 0.0) g_consecutiveLosses++;
      else break;
   }
}

//--------------------------- Indicator helpers -----------------------
bool ReadBufferValue(const int handle, const int buffer, const int shift, double &value)
{
   value = 0.0;
   if(handle == INVALID_HANDLE) return false;
   double a[1];
   if(CopyBuffer(handle, buffer, shift, 1, a) != 1) return false;
   value = a[0];
   return true;
}

bool GetAtrPoints(double &atrPts)
{
   atrPts = 0.0;
   double atr = 0.0;
   if(!ReadBufferValue(g_atrM1, 0, 1, atr) || atr <= 0.0) return false;
   atrPts = atr / _Point;
   return (atrPts > 0.0);
}

// Returns strict regime pass plus a transparent quality score.
bool QualityRegime(const int direction,
                   const double tickRatio,
                   int &score,
                   double &m1GapPts,
                   double &m5GapPts,
                   double &fastSlopePts,
                   double &atrPts,
                   double &adx,
                   double &plusDI,
                   double &minusDI,
                   double &bodyRatio)
{
   score = 0;
   m1GapPts = 0.0;
   m5GapPts = 0.0;
   fastSlopePts = 0.0;
   atrPts = 0.0;
   adx = 0.0;
   plusDI = 0.0;
   minusDI = 0.0;
   bodyRatio = 0.0;

   if(direction == 0) return false;

   if(!GetAtrPoints(atrPts)) return false;
   if(InpMinAtrPoints > 0.0 && atrPts < InpMinAtrPoints) return false;
   if(InpMaxAtrPoints > 0.0 && atrPts > InpMaxAtrPoints) return false;

   double f1 = 0.0, s1 = 0.0, f2 = 0.0;
   if(!ReadBufferValue(g_emaFastM1, 0, 1, f1) ||
      !ReadBufferValue(g_emaSlowM1, 0, 1, s1) ||
      !ReadBufferValue(g_emaFastM1, 0, 2, f2))
      return false;

   m1GapPts = (f1 - s1) / _Point;
   fastSlopePts = (f1 - f2) / _Point;

   // M1 alignment and slope are mandatory, not optional score cosmetics.
   if(direction > 0)
   {
      if(m1GapPts < InpMinM1EmaGapPoints) return false;
      if(fastSlopePts < InpMinFastEmaSlopePoints) return false;
   }
   else
   {
      if(m1GapPts > -InpMinM1EmaGapPoints) return false;
      if(fastSlopePts > -InpMinFastEmaSlopePoints) return false;
   }
   score += 3; // M1 alignment + slope

   if(InpRequireM5Confirmation)
   {
      double f5 = 0.0, s5 = 0.0;
      if(!ReadBufferValue(g_emaFastM5, 0, 1, f5) || !ReadBufferValue(g_emaSlowM5, 0, 1, s5))
         return false;
      m5GapPts = (f5 - s5) / _Point;
      if(direction > 0 && m5GapPts < InpMinM5EmaGapPoints) return false;
      if(direction < 0 && m5GapPts > -InpMinM5EmaGapPoints) return false;
      score += 1;
   }

   if(InpRequireADX)
   {
      if(!ReadBufferValue(g_adxM1, 0, 1, adx) ||
         !ReadBufferValue(g_adxM1, 1, 1, plusDI) ||
         !ReadBufferValue(g_adxM1, 2, 1, minusDI))
         return false;
      if(adx < InpMinADX) return false;
      if(direction > 0 && plusDI > minusDI) score += 1;
      if(direction < 0 && minusDI > plusDI) score += 1;
   }

   double o = iOpen(_Symbol, PERIOD_M1, 1);
   double h = iHigh(_Symbol, PERIOD_M1, 1);
   double l = iLow(_Symbol, PERIOD_M1, 1);
   double c = iClose(_Symbol, PERIOD_M1, 1);
   if(o > 0.0 && h > l && c > 0.0)
   {
      bodyRatio = MathAbs(c - o) / (h - l);
      bool candleAligned = (direction > 0 ? c > o : c < o);
      if(candleAligned && bodyRatio >= InpMinClosedCandleBodyRatio)
         score += 1;
   }

   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick))
   {
      double mid = (tick.bid + tick.ask) * 0.5;
      if(direction > 0 && mid > f1) score += 1;
      if(direction < 0 && mid < f1) score += 1;
   }

   if(tickRatio >= InpStrongDirectionalRatio)
      score += 1;

   return (score >= InpMinQualityScore);
}

//--------------------------- Tick buffer / impulse -------------------
void PushTick(const MqlTick &tick)
{
   double mid = (tick.bid + tick.ask) * 0.5;
   g_tickMid[g_tickHead] = mid;
   g_tickMs[g_tickHead]  = tick.time_msc;
   g_tickHead = (g_tickHead + 1) % MAX_TICK_BUFFER;
   if(g_tickCount < MAX_TICK_BUFFER) g_tickCount++;
}

bool TickByOffset(const int offset, double &mid, long &ms)
{
   if(offset < 0 || offset >= g_tickCount) return false;
   int idx = g_tickHead - 1 - offset;
   while(idx < 0) idx += MAX_TICK_BUFFER;
   idx %= MAX_TICK_BUFFER;
   mid = g_tickMid[idx];
   ms  = g_tickMs[idx];
   return true;
}

int RawImpulse(double &netPts, double &dirRatio, long &ageMs, double &recentPts, double &thresholdPts)
{
   netPts = 0.0;
   dirRatio = 0.0;
   ageMs = 0;
   recentPts = 0.0;
   thresholdPts = InpMinImpulsePoints;

   if(g_tickCount < 4) return 0;

   double atrPts = 0.0;
   if(GetAtrPoints(atrPts))
      thresholdPts = MathMax(InpMinImpulsePoints, atrPts * InpImpulseAtrFraction);

   int maxOffset = InpLookbackTicks - 1;
   if(maxOffset > g_tickCount - 1) maxOffset = g_tickCount - 1;
   if(maxOffset > MAX_TICK_BUFFER - 1) maxOffset = MAX_TICK_BUFFER - 1;
   if(maxOffset < 2) return 0;

   double latestMid = 0.0;
   long latestMs = 0;
   if(!TickByOffset(0, latestMid, latestMs)) return 0;

   int chosen = -1;
   for(int off = 1; off <= maxOffset; ++off)
   {
      double oldMid = 0.0;
      long oldMs = 0;
      if(!TickByOffset(off, oldMid, oldMs)) break;
      long age = latestMs - oldMs;
      if(age > InpMaxTickWindowMs) break;
      if(age >= InpMinTickWindowMs) chosen = off;
   }
   if(chosen < 2) return 0;

   double oldMid = 0.0;
   long oldMs = 0;
   TickByOffset(chosen, oldMid, oldMs);
   ageMs = latestMs - oldMs;
   netPts = (latestMid - oldMid) / _Point;

   int upMoves = 0, downMoves = 0, meaningful = 0;
   for(int off = chosen; off >= 1; --off)
   {
      double older = 0.0, newer = 0.0;
      long t1 = 0, t2 = 0;
      TickByOffset(off, older, t1);
      TickByOffset(off - 1, newer, t2);
      double d = (newer - older) / _Point;
      if(d > 0.05) { upMoves++; meaningful++; }
      else if(d < -0.05) { downMoves++; meaningful++; }
   }
   if(meaningful <= 0) return 0;

   int halfOffset = chosen / 2;
   if(halfOffset < 1) halfOffset = 1;
   double halfMid = 0.0;
   long halfMs = 0;
   TickByOffset(halfOffset, halfMid, halfMs);
   recentPts = (latestMid - halfMid) / _Point;

   double upRatio = (double)upMoves / (double)meaningful;
   double downRatio = (double)downMoves / (double)meaningful;
   double recentShare = (MathAbs(netPts) > 0.0 ? MathAbs(recentPts / netPts) : 0.0);

   if(netPts >= thresholdPts &&
      recentPts >= InpMinRecentMomentumPoints &&
      upRatio >= InpMinDirectionalRatio &&
      recentShare >= InpMinRecentMomentumShare)
   {
      dirRatio = upRatio;
      return 1;
   }

   if(netPts <= -thresholdPts &&
      recentPts <= -InpMinRecentMomentumPoints &&
      downRatio >= InpMinDirectionalRatio &&
      recentShare >= InpMinRecentMomentumShare)
   {
      dirRatio = downRatio;
      return -1;
   }

   dirRatio = MathMax(upRatio, downRatio);
   return 0;
}

int ConfirmSignal(const int rawDir, const long nowMs)
{
   if(InpConfirmationsRequired <= 1)
   {
      if(rawDir == 0) return 0;
      if(g_lastConfirmedMs > 0 && (nowMs - g_lastConfirmedMs) < InpSignalRearmMs) return 0;
      g_lastConfirmedMs = nowMs;
      return rawDir;
   }

   if(g_candidateCount > 0 && (nowMs - g_candidateStartMs) > InpConfirmationWindowMs)
   {
      g_candidateDir = 0;
      g_candidateCount = 0;
      g_candidateStartMs = 0;
   }

   if(rawDir == 0) return 0;

   if(g_candidateDir != rawDir || g_candidateCount == 0)
   {
      g_candidateDir = rawDir;
      g_candidateCount = 1;
      g_candidateStartMs = nowMs;
      return 0;
   }

   g_candidateCount++;

   if(g_candidateCount < InpConfirmationsRequired)
      return 0;

   if(g_lastConfirmedMs > 0 && (nowMs - g_lastConfirmedMs) < InpSignalRearmMs)
      return 0;

   int confirmed = g_candidateDir;
   g_candidateDir = 0;
   g_candidateCount = 0;
   g_candidateStartMs = 0;
   g_lastConfirmedMs = nowMs;
   return confirmed;
}

//--------------------------- Positions / pending ---------------------
int CountOurOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      count++;
   }
   return count;
}

bool GetOurPosition(ulong &ticket, ENUM_POSITION_TYPE &type, double &openPrice, double &sl, double &tp, long &openMs)
{
   ticket = 0;
   openPrice = 0.0;
   sl = 0.0;
   tp = 0.0;
   openMs = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ticket = t;
      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      sl = PositionGetDouble(POSITION_SL);
      tp = PositionGetDouble(POSITION_TP);
      openMs = (long)PositionGetInteger(POSITION_TIME_MSC);
      return true;
   }
   return false;
}

bool GetOurPending(ulong &ticket, ENUM_ORDER_TYPE &type, double &price, long &setupMs)
{
   ticket = 0;
   price = 0.0;
   setupMs = 0;

   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;

      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_LIMIT && ot != ORDER_TYPE_SELL_LIMIT) continue;

      ticket = t;
      type = ot;
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      setupMs = (long)OrderGetInteger(ORDER_TIME_SETUP_MSC);
      return true;
   }
   return false;
}

bool CanOrderAction(const long nowMs)
{
   if(g_lastOrderActionMs <= 0) return true;
   return ((nowMs - g_lastOrderActionMs) >= InpMinOrderActionIntervalMs);
}

bool DeletePending(const ulong ticket, const long nowMs, const string reason)
{
   if(ticket == 0 || !CanOrderAction(nowMs)) return false;

   trade.SetExpertMagicNumber(InpMagicNumber);
   bool ok = trade.OrderDelete(ticket);
   g_lastOrderActionMs = nowMs;

   if(ok)
   {
      Log(StringFormat("DELETE LIMIT #%I64u reason=%s", ticket, reason));
      return true;
   }

   Log(StringFormat("Delete failed #%I64u ret=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   return false;
}

void DeleteAllPending(const string reason)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT) continue;
      if(!CanOrderAction(tick.time_msc)) return;
      DeletePending(ticket, tick.time_msc, reason);
   }
}

string RiskGateReason(const long nowMs)
{
   if(!InpEnableTrading) return "trading-disabled-input";
   if(!IsDemoAllowed()) return "demo-only";
   if(!IsFullTradeSymbol()) return "symbol-not-full-access";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return "terminal-algo-disabled";
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return "ea-trading-disabled";
   if(!IsSessionOK()) return "outside-session";
   if(!IsSpreadOK()) return "spread";
   if(!DailyLossGuardOK()) return "daily-loss-stop";
   if(InpMaxConsecutiveLosses > 0 && g_consecutiveLosses >= InpMaxConsecutiveLosses) return "loss-streak-stop";
   if(InpMaxTradesPerHour > 0 && CountEntriesLastHour() >= InpMaxTradesPerHour) return "hourly-trade-cap";
   if(InpCooldownAfterExitMs > 0 && g_lastExitMs > 0 && (nowMs - g_lastExitMs) < InpCooldownAfterExitMs) return "cooldown";
   if(CountOurOpenPositions() >= InpMaxOpenPositions) return "position-cap";
   return "";
}

//--------------------------- Position sizing -------------------------
double NormalizeVolumeFloor(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;

   lots = MathMin(lots, maxLot);
   lots = MathMin(lots, InpMaxLots);
   lots = MathFloor(lots / step + 1e-9) * step;

   int digits = 2;
   if(step >= 1.0) digits = 0;
   else if(step >= 0.1) digits = 1;
   else if(step >= 0.01) digits = 2;
   else digits = 3;

   return NormalizeDouble(lots, digits);
}

double LotsForRisk(const int direction,
                   const double entryPrice,
                   const double stopPrice,
                   double &effectiveRiskPct,
                   double &minLotRiskPct)
{
   effectiveRiskPct = 0.0;
   minLotRiskPct = 0.0;
   if(direction == 0 || InpRiskPerTradePct <= 0.0) return 0.0;

   ENUM_ORDER_TYPE calcType = (direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double lossOneLot = 0.0;
   if(!OrderCalcProfit(calcType, _Symbol, 1.0, entryPrice, stopPrice, lossOneLot)) return 0.0;
   lossOneLot = MathAbs(lossOneLot);
   if(lossOneLot <= 0.0) return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return 0.0;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double desiredRiskMoney = equity * InpRiskPerTradePct / 100.0;
   double rawLots = desiredRiskMoney / lossOneLot;

   double minLotLoss = lossOneLot * minLot;
   minLotRiskPct = minLotLoss / equity * 100.0;

   if(rawLots < minLot)
   {
      if(!InpAllowMinLotFloor) return 0.0;
      if(minLotRiskPct > InpMaxEffectiveRiskPctAtMinLot) return 0.0;
      effectiveRiskPct = minLotRiskPct;
      return NormalizeVolumeFloor(minLot);
   }

   double lots = NormalizeVolumeFloor(rawLots);
   if(lots < minLot) return 0.0;
   effectiveRiskPct = (lossOneLot * lots) / equity * 100.0;
   return lots;
}

//--------------------------- Entry engine ----------------------------
int ClampInt(const int value, const int lo, const int hi)
{
   return MathMax(lo, MathMin(hi, value));
}

bool PlaceQualityLimit(const int direction,
                       const MqlTick &tick,
                       const double impulsePts,
                       const double tickRatio,
                       const int qualityScore,
                       const double m1Gap,
                       const double m5Gap,
                       const double atrPts)
{
   if(direction == 0 || !CanOrderAction(tick.time_msc)) return false;

   string gate = RiskGateReason(tick.time_msc);
   if(gate != "")
   {
      Log("ENTRY BLOCKED gate=" + gate);
      return false;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int brokerGap = MathMax(stopsLevel, freezeLevel) + InpExtraPassivePoints;
   if(brokerGap < 1) brokerGap = 1;

   int pullPts = (int)MathRound(MathAbs(impulsePts) * InpPullbackFractionOfImpulse);
   pullPts = ClampInt(pullPts, InpMinPullbackPoints, InpMaxPullbackPoints);
   pullPts = MathMax(pullPts, brokerGap);

   int stopPts = (int)MathRound(atrPts * InpStopAtrFraction);
   stopPts = ClampInt(stopPts, InpMinStopPoints, InpMaxStopPoints);
   stopPts = MathMax(stopPts, stopsLevel + 2);

   double spreadPts = CurrentSpreadPoints();
   int targetByRR = (int)MathRound(stopPts * InpRewardRisk);
   int targetByCost = (int)MathCeil(spreadPts * InpMinTargetToSpreadRatio);
   int targetPts = MathMax(targetByRR, targetByCost);
   targetPts = MathMin(targetPts, InpMaxTargetPoints);

   if(targetPts <= 0 || spreadPts <= 0.0 || ((double)targetPts / spreadPts) < InpMinTargetToSpreadRatio)
   {
      Log(StringFormat("ENTRY BLOCKED cost target=%d spread=%.1f ratio=%.2f", targetPts, spreadPts,
                       (spreadPts > 0.0 ? (double)targetPts / spreadPts : 0.0)));
      return false;
   }

   double entry = 0.0, sl = 0.0, tp = 0.0;
   if(direction > 0)
   {
      entry = NormalizeDouble(tick.bid - pullPts * _Point, digits);
      double maxAllowed = NormalizeDouble(tick.ask - brokerGap * _Point, digits);
      if(entry > maxAllowed) entry = maxAllowed;
      sl = NormalizeDouble(entry - stopPts * _Point, digits);
      tp = NormalizeDouble(entry + targetPts * _Point, digits);
   }
   else
   {
      entry = NormalizeDouble(tick.ask + pullPts * _Point, digits);
      double minAllowed = NormalizeDouble(tick.bid + brokerGap * _Point, digits);
      if(entry < minAllowed) entry = minAllowed;
      sl = NormalizeDouble(entry + stopPts * _Point, digits);
      tp = NormalizeDouble(entry - targetPts * _Point, digits);
   }

   double effectiveRiskPct = 0.0;
   double minLotRiskPct = 0.0;
   double lots = LotsForRisk(direction, entry, sl, effectiveRiskPct, minLotRiskPct);
   if(lots <= 0.0)
   {
      Log(StringFormat("ENTRY BLOCKED sizing desired=%.3f%% minLotRisk=%.3f%% cap=%.3f%%",
                       InpRiskPerTradePct, minLotRiskPct, InpMaxEffectiveRiskPctAtMinLot));
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool sent = false;
   if(direction > 0)
      sent = trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "XAU-HS4 QUALITY BUY");
   else
      sent = trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "XAU-HS4 QUALITY SELL");

   g_lastOrderActionMs = tick.time_msc;

   if(!sent)
   {
      Log(StringFormat("LIMIT FAILED dir=%s ret=%u %s entry=%.2f sl=%.2f tp=%.2f",
                       DirText(direction), trade.ResultRetcode(), trade.ResultRetcodeDescription(), entry, sl, tp));
      return false;
   }

   Log(StringFormat("PLACE %s LIMIT lot=%.2f entry=%.2f sl=%.2f tp=%.2f Q=%d impulse=%.1f ratio=%.2f pull=%d spread=%.1f risk=%.3f%% m1=%.1f m5=%.1f atr=%.1f",
                    DirText(direction), lots, entry, sl, tp, qualityScore, impulsePts, tickRatio, pullPts,
                    spreadPts, effectiveRiskPct, m1Gap, m5Gap, atrPts));
   return true;
}

void ManagePending(const int confirmedDir, const MqlTick &tick)
{
   ulong ticket = 0;
   ENUM_ORDER_TYPE type = ORDER_TYPE_BUY_LIMIT;
   double price = 0.0;
   long setupMs = 0;
   bool hasPending = GetOurPending(ticket, type, price, setupMs);
   if(!hasPending) return;

   int pendingDir = (type == ORDER_TYPE_BUY_LIMIT ? 1 : -1);
   long age = tick.time_msc - setupMs;

   if(confirmedDir != 0 && confirmedDir != pendingDir)
   {
      DeletePending(ticket, tick.time_msc, "confirmed-direction-flip");
      return;
   }

   if(age >= InpPendingMaxAgeMs)
   {
      DeletePending(ticket, tick.time_msc, "quality-limit-expired");
      return;
   }

   int score = 0;
   double m1 = 0.0, m5 = 0.0, slope = 0.0, atr = 0.0, adx = 0.0, pdi = 0.0, mdi = 0.0, body = 0.0;
   if(!QualityRegime(pendingDir, InpMinDirectionalRatio, score, m1, m5, slope, atr, adx, pdi, mdi, body))
      DeletePending(ticket, tick.time_msc, "regime-no-longer-valid");
}

//--------------------------- Position management --------------------
bool CloseOurPosition(const ulong ticket, const string reason)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePointsForClose);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok = trade.PositionClose(ticket);
   if(ok)
   {
      Log(StringFormat("CLOSE #%I64u reason=%s", ticket, reason));
      return true;
   }

   Log(StringFormat("Close failed #%I64u ret=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   return false;
}

bool ModifyOurPosition(const ulong ticket, const double newSL, const double tp, const long nowMs, const string reason)
{
   if(g_lastModifyMs > 0 && (nowMs - g_lastModifyMs) < InpMinModifyIntervalMs) return false;

   trade.SetExpertMagicNumber(InpMagicNumber);
   bool ok = trade.PositionModify(ticket, newSL, tp);
   g_lastModifyMs = nowMs;

   if(ok)
   {
      Log(StringFormat("MODIFY #%I64u SL=%.2f reason=%s", ticket, newSL, reason));
      return true;
   }

   Log(StringFormat("Modify failed #%I64u ret=%u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   return false;
}

void ManageOpenPosition(const int confirmedDir, const MqlTick &tick)
{
   ulong ticket = 0;
   ENUM_POSITION_TYPE type = POSITION_TYPE_BUY;
   double openPrice = 0.0, sl = 0.0, tp = 0.0;
   long openMs = 0;

   if(!GetOurPosition(ticket, type, openPrice, sl, tp, openMs))
   {
      g_trackedPositionTicket = 0;
      g_peakProfitPoints = 0.0;
      g_positionRiskPoints = 0.0;
      return;
   }

   if(g_trackedPositionTicket != ticket)
   {
      g_trackedPositionTicket = ticket;
      g_peakProfitPoints = 0.0;
      g_positionRiskPoints = (sl > 0.0 ? MathAbs(openPrice - sl) / _Point : (double)InpMinStopPoints);
      if(g_positionRiskPoints < 1.0) g_positionRiskPoints = (double)InpMinStopPoints;
      Log(StringFormat("TRACK #%I64u open=%.2f risk=%.1fpts", ticket, openPrice, g_positionRiskPoints));
   }

   double profitPts = (type == POSITION_TYPE_BUY)
                      ? (tick.bid - openPrice) / _Point
                      : (openPrice - tick.ask) / _Point;
   if(profitPts > g_peakProfitPoints) g_peakProfitPoints = profitPts;

   long heldMs = tick.time_msc - openMs;

   // Break-even protection: server-side SL, not a virtual promise.
   if(InpBreakEvenAtR > 0.0 && profitPts >= g_positionRiskPoints * InpBreakEvenAtR)
   {
      double desiredSL = (type == POSITION_TYPE_BUY)
                         ? openPrice + InpBreakEvenLockPoints * _Point
                         : openPrice - InpBreakEvenLockPoints * _Point;
      desiredSL = NormalizeDouble(desiredSL, _Digits);

      bool improves = (type == POSITION_TYPE_BUY ? (sl <= 0.0 || desiredSL > sl) : (sl <= 0.0 || desiredSL < sl));
      if(improves)
         ModifyOurPosition(ticket, desiredSL, tp, tick.time_msc, "break-even");
   }

   // Trail only after a meaningful fraction of R is earned.
   if(InpTrailStartR > 0.0 && g_peakProfitPoints >= g_positionRiskPoints * InpTrailStartR)
   {
      double desiredSL = (type == POSITION_TYPE_BUY)
                         ? tick.bid - InpTrailDistancePoints * _Point
                         : tick.ask + InpTrailDistancePoints * _Point;
      desiredSL = NormalizeDouble(desiredSL, _Digits);

      bool improves = (type == POSITION_TYPE_BUY ? (sl <= 0.0 || desiredSL > sl) : (sl <= 0.0 || desiredSL < sl));
      if(improves)
         ModifyOurPosition(ticket, desiredSL, tp, tick.time_msc, "quality-trail");
   }

   if(InpStaleLossSeconds > 0 && heldMs >= (long)InpStaleLossSeconds * 1000 &&
      profitPts <= -(g_positionRiskPoints * InpStaleLossR))
   {
      CloseOurPosition(ticket, "stale-loss");
      return;
   }

   if(InpMaxHoldSeconds > 0 && heldMs >= (long)InpMaxHoldSeconds * 1000)
   {
      CloseOurPosition(ticket, "time-exit");
      return;
   }

   if(InpExitOnConfirmedReversal && confirmedDir != 0 && heldMs >= InpMinHoldBeforeReversalMs)
   {
      if(type == POSITION_TYPE_BUY && confirmedDir < 0)
      {
         CloseOurPosition(ticket, "confirmed-reversal");
         return;
      }
      if(type == POSITION_TYPE_SELL && confirmedDir > 0)
      {
         CloseOurPosition(ticket, "confirmed-reversal");
         return;
      }
   }
}

//--------------------------- Diagnostics -----------------------------
void Heartbeat(const MqlTick &tick,
               const int rawDir,
               const int confirmedDir,
               const double netPts,
               const double ratio,
               const double thresholdPts)
{
   if(!InpVerboseLogging || InpHeartbeatSeconds <= 0) return;
   if(g_lastHeartbeatMs > 0 && (tick.time_msc - g_lastHeartbeatMs) < (long)InpHeartbeatSeconds * 1000) return;
   g_lastHeartbeatMs = tick.time_msc;

   ulong pt = 0;
   ENUM_POSITION_TYPE ptype = POSITION_TYPE_BUY;
   double po = 0.0, psl = 0.0, ptp = 0.0;
   long pms = 0;
   bool hasPos = GetOurPosition(pt, ptype, po, psl, ptp, pms);

   ulong ot = 0;
   ENUM_ORDER_TYPE otype = ORDER_TYPE_BUY_LIMIT;
   double op = 0.0;
   long oms = 0;
   bool hasPending = GetOurPending(ot, otype, op, oms);

   string state = hasPos ? "POSITION" : (hasPending ? "PENDING" : "FLAT");
   string gate = RiskGateReason(tick.time_msc);
   if(gate == "") gate = "OK";

   Log(StringFormat("HB state=%s raw=%s confirmed=%s cand=%d/%d net=%.1f th=%.1f ratio=%.2f spread=%.1f gate=%s",
                    state, DirText(rawDir), DirText(confirmedDir), g_candidateCount, InpConfirmationsRequired,
                    netPts, thresholdPts, ratio, CurrentSpreadPoints(), gate));
}

//--------------------------- MT5 events ------------------------------
int OnInit()
{
   if(InpRiskPerTradePct <= 0.0 || InpRiskPerTradePct > 1.0)
   {
      Print("[XAU-HS4] Risk per trade must be > 0 and <= 1.0%.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpMaxEffectiveRiskPctAtMinLot <= 0.0 || InpMaxEffectiveRiskPctAtMinLot > 1.0)
   {
      Print("[XAU-HS4] Effective min-lot risk cap must be > 0 and <= 1.0%.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpLookbackTicks < 4 || InpLookbackTicks > MAX_TICK_BUFFER ||
      InpMinTickWindowMs <= 0 || InpMaxTickWindowMs <= InpMinTickWindowMs ||
      InpMinDirectionalRatio < 0.50 || InpMinDirectionalRatio > 1.0 ||
      InpStrongDirectionalRatio < InpMinDirectionalRatio || InpStrongDirectionalRatio > 1.0)
   {
      Print("[XAU-HS4] Invalid tick impulse configuration.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpMinStopPoints <= 0 || InpMaxStopPoints < InpMinStopPoints || InpRewardRisk <= 0.0)
   {
      Print("[XAU-HS4] Invalid stop/target configuration.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!IsDemoAllowed())
   {
      Print("[XAU-HS4] Demo-only guard blocked initialization on a real account.");
      return INIT_FAILED;
   }

   if(!IsFullTradeSymbol())
   {
      Print("[XAU-HS4] Symbol is not FULL ACCESS. Use the broker's fully tradable gold symbol (for example XAUUSD.a). ");
      return INIT_FAILED;
   }

   g_emaFastM1 = iMA(_Symbol, PERIOD_M1, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowM1 = iMA(_Symbol, PERIOD_M1, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_emaFastM5 = iMA(_Symbol, PERIOD_M5, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowM5 = iMA(_Symbol, PERIOD_M5, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_atrM1     = iATR(_Symbol, PERIOD_M1, InpAtrPeriod);
   g_adxM1     = iADX(_Symbol, PERIOD_M1, InpAdxPeriod);

   if(g_emaFastM1 == INVALID_HANDLE || g_emaSlowM1 == INVALID_HANDLE ||
      g_emaFastM5 == INVALID_HANDLE || g_emaSlowM5 == INVALID_HANDLE ||
      g_atrM1 == INVALID_HANDLE || g_adxM1 == INVALID_HANDLE)
   {
      Print("[XAU-HS4] Indicator handle creation failed. Error=", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePointsForClose);
   trade.SetTypeFillingBySymbol(_Symbol);

   RefreshDayStartEquity();
   RebuildLossStreak();

   Log(StringFormat("Initialized V4 on %s. QUALITY-FIRST engine risk=%.2f%% effectiveMinLotCap=%.2f%% maxTrades/hr=%d",
                    _Symbol, InpRiskPerTradePct, InpMaxEffectiveRiskPctAtMinLot, InpMaxTradesPerHour));
   Log("Signal path: adaptive tick impulse -> confirmation -> M1/M5 regime + slope + ADX + candle score -> passive broker LIMIT.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteAllPending("ea-deinit");

   if(g_emaFastM1 != INVALID_HANDLE) IndicatorRelease(g_emaFastM1);
   if(g_emaSlowM1 != INVALID_HANDLE) IndicatorRelease(g_emaSlowM1);
   if(g_emaFastM5 != INVALID_HANDLE) IndicatorRelease(g_emaFastM5);
   if(g_emaSlowM5 != INVALID_HANDLE) IndicatorRelease(g_emaSlowM5);
   if(g_atrM1     != INVALID_HANDLE) IndicatorRelease(g_atrM1);
   if(g_adxM1     != INVALID_HANDLE) IndicatorRelease(g_adxM1);
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   RefreshDayStartEquity();
   PushTick(tick);

   double netPts = 0.0, ratio = 0.0, recentPts = 0.0, thresholdPts = 0.0;
   long ageMs = 0;
   int rawDir = RawImpulse(netPts, ratio, ageMs, recentPts, thresholdPts);
   int confirmedDir = ConfirmSignal(rawDir, tick.time_msc);

   if(CountOurOpenPositions() > 0)
   {
      DeleteAllPending("position-open");
      ManageOpenPosition(confirmedDir, tick);
      Heartbeat(tick, rawDir, confirmedDir, netPts, ratio, thresholdPts);
      return;
   }

   g_trackedPositionTicket = 0;
   g_peakProfitPoints = 0.0;
   g_positionRiskPoints = 0.0;

   string gate = RiskGateReason(tick.time_msc);
   if(gate != "")
   {
      DeleteAllPending("risk-gate-" + gate);
      Heartbeat(tick, rawDir, confirmedDir, netPts, ratio, thresholdPts);
      return;
   }

   ManagePending(confirmedDir, tick);

   ulong pendingTicket = 0;
   ENUM_ORDER_TYPE pendingType = ORDER_TYPE_BUY_LIMIT;
   double pendingPrice = 0.0;
   long pendingMs = 0;
   bool hasPending = GetOurPending(pendingTicket, pendingType, pendingPrice, pendingMs);

   if(confirmedDir != 0 && !hasPending)
   {
      int score = 0;
      double m1 = 0.0, m5 = 0.0, slope = 0.0, atr = 0.0, adx = 0.0, pdi = 0.0, mdi = 0.0, body = 0.0;
      bool quality = QualityRegime(confirmedDir, ratio, score, m1, m5, slope, atr, adx, pdi, mdi, body);

      if(!quality)
      {
         Log(StringFormat("REJECT %s Q=%d/%d m1=%.1f m5=%.1f slope=%.1f atr=%.1f adx=%.1f +DI=%.1f -DI=%.1f body=%.2f impulse=%.1f ratio=%.2f",
                          DirText(confirmedDir), score, InpMinQualityScore, m1, m5, slope, atr, adx, pdi, mdi, body, netPts, ratio));
      }
      else
      {
         PlaceQualityLimit(confirmedDir, tick, netPts, ratio, score, m1, m5, atr);
      }
   }

   Heartbeat(tick, rawDir, confirmedDir, netPts, ratio, thresholdPts);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT) return;

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   g_lastExitMs = (long)HistoryDealGetInteger(trans.deal, DEAL_TIME_MSC);
   if(pnl < 0.0) g_consecutiveLosses++;
   else g_consecutiveLosses = 0;

   g_trackedPositionTicket = 0;
   g_peakProfitPoints = 0.0;
   g_positionRiskPoints = 0.0;

   Log(StringFormat("EXIT pnl=%.2f consecutiveLosses=%d", pnl, g_consecutiveLosses));
}
//+------------------------------------------------------------------+
