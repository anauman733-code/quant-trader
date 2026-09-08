//+------------------------------------------------------------------+
//| XAU_HyperScalper_V6_1R.mq5                                      |
//| Reversed V6.1: micro-range breakout exhaustion / fade engine     |
//| Demo-first research EA. No martingale, grid or averaging.        |
//+------------------------------------------------------------------+
#property strict
#property version   "6.11"
#property description "Demo-first XAUUSD V6.1 reverse: detect micro-breakout burst, then fade it with immediate opposite market entry."

#include <Trade/Trade.mqh>
CTrade trade;

#define TICK_BUF 256

input group "Safety"
input bool   InpDemoOnly                    = true;
input bool   InpEnableTrading               = true;
input long   InpMagicNumber                 = 26090862;
input double InpFixedLots                   = 0.01;
input double InpMaxEffectiveRiskPct         = 0.20;
input double InpDailyLossStopPct            = 1.50;
input int    InpMaxConsecutiveLosses        = 5;
input int    InpMaxTradesPerHour            = 180;
input int    InpCooldownAfterExitMs         = 500;
input int    InpSameDirectionPauseMs        = 1000;

input group "Rolling Micro Range"
input int    InpMicroRangeTicks             = 16;
input double InpMinMicroRangePoints         = 3.0;
input double InpMaxMicroRangePoints         = 120.0;
input double InpBreakoutBufferPoints        = 1.0;
input double InpMaxChasePoints              = 25.0;
input int    InpSignalValidTicks            = 24;

input group "Burst + Momentum (detect original breakout)"
input int    InpBurstTicks                  = 2;
input double InpBurstMinPoints              = 1.5;
input double InpMinVelocityPointsPerSec     = 3.0;
input int    InpMomentumWindowTicks         = 6;
input double InpMinMomentumNetPoints        = 2.0;
input double InpMinTickBias                 = 0.55;
input double InpMinPressurePct              = 10.0;

input group "Reverse Market Execution"
input int    InpMaxSpreadPoints             = 20;
input double InpMinTargetToSpreadRatio      = 4.0;
input int    InpMaxFillSlippagePoints       = 15;
input int    InpCloseSlippagePoints         = 20;

input group "Stop / Target"
input int    InpStopLossPoints              = 80;
input int    InpTakeProfitPoints            = 100;
input int    InpBreakEvenTriggerPoints      = 35;
input int    InpBreakEvenLockPoints         = 3;
input int    InpTrailStartPoints            = 55;
input int    InpTrailDistancePoints         = 20;
input int    InpMaxHoldSeconds              = 20;

input group "Diagnostics"
input bool   InpVerboseLogging              = true;
input int    InpHeartbeatSeconds            = 3;

//--------------------------- State ----------------------------------
double g_bid[TICK_BUF];
long   g_ms[TICK_BUF];
int    g_count = 0;
int    g_head = 0;
long   g_tickSerial = 0;

int    g_armDir = 0;             // direction of detected breakout, not trade
 double g_breakoutLevel = 0.0;
long   g_armSerial = 0;

long   g_lastExitMs = 0;
long   g_lastEntryMs = 0;
int    g_lastEntryDir = 0;       // actual trade direction
long   g_lastHeartbeatMs = 0;
long   g_lastModifyMs = 0;
int    g_consecutiveLosses = 0;

double g_dayStartEquity = 0.0;
string g_dayKey = "";

double g_expectedEntry = 0.0;
int    g_expectedDir = 0;
bool   g_forceBadFillClose = false;

//--------------------------- Helpers --------------------------------
void Log(const string s)
{
   if(InpVerboseLogging) Print("[XAU-HS61R] ",s);
}

string DirText(const int d)
{
   if(d>0) return "BUY";
   if(d<0) return "SELL";
   return "NONE";
}

bool IsDemoAllowed()
{
   if(!InpDemoOnly) return true;
   if(MQLInfoInteger(MQL_TESTER)) return true;
   ENUM_ACCOUNT_TRADE_MODE mode=(ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   return (mode==ACCOUNT_TRADE_MODE_DEMO || mode==ACCOUNT_TRADE_MODE_CONTEST);
}

bool IsFullTradeSymbol()
{
   return ((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE)==SYMBOL_TRADE_MODE_FULL);
}

double SpreadPts()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return 999999.0;
   return (t.ask-t.bid)/_Point;
}

bool CostOK()
{
   double s=SpreadPts();
   if(s<=0.0) return false;
   if(InpMaxSpreadPoints>0 && s>InpMaxSpreadPoints) return false;
   if(InpTakeProfitPoints>0 && ((double)InpTakeProfitPoints/s)<InpMinTargetToSpreadRatio) return false;
   return true;
}

string MakeDayKey()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   long login=(long)AccountInfoInteger(ACCOUNT_LOGIN);
   return StringFormat("XAUHS61R_%I64d_%I64d_%04d%02d%02d",login,InpMagicNumber,dt.year,dt.mon,dt.day);
}

void RefreshDayEquity()
{
   string key=MakeDayKey();
   if(key==g_dayKey && g_dayStartEquity>0.0) return;
   g_dayKey=key;
   if(MQLInfoInteger(MQL_TESTER))
   {
      g_dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      return;
   }
   if(GlobalVariableCheck(key)) g_dayStartEquity=GlobalVariableGet(key);
   else
   {
      g_dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(key,g_dayStartEquity);
   }
   Log(StringFormat("Day-start equity %.2f",g_dayStartEquity));
}

bool DailyLossOK()
{
   RefreshDayEquity();
   if(InpDailyLossStopPct<=0.0 || g_dayStartEquity<=0.0) return true;
   double floorEq=g_dayStartEquity*(1.0-InpDailyLossStopPct/100.0);
   return AccountInfoDouble(ACCOUNT_EQUITY)>floorEq;
}

int CountEntriesLastHour()
{
   datetime now=TimeCurrent();
   if(!HistorySelect(now-3600,now)) return 0;
   int c=0;
   for(int i=0;i<HistoryDealsTotal();++i)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0) continue;
      if((long)HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagicNumber) continue;
      if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT) c++;
   }
   return c;
}

void RebuildLossStreak()
{
   g_consecutiveLosses=0;
   g_lastExitMs=0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); dt.hour=0;dt.min=0;dt.sec=0;
   datetime start=StructToTime(dt);
   if(!HistorySelect(start,TimeCurrent())) return;
   for(int i=HistoryDealsTotal()-1;i>=0;--i)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d==0) continue;
      if((long)HistoryDealGetInteger(d,DEAL_MAGIC)!=InpMagicNumber) continue;
      if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
      ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY);
      if(e!=DEAL_ENTRY_OUT && e!=DEAL_ENTRY_OUT_BY && e!=DEAL_ENTRY_INOUT) continue;
      if(g_lastExitMs==0) g_lastExitMs=(long)HistoryDealGetInteger(d,DEAL_TIME_MSC);
      double pnl=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION);
      if(pnl<0.0) g_consecutiveLosses++; else break;
   }
}

string GateReason(const long nowMs)
{
   if(!InpEnableTrading) return "input-disabled";
   if(!IsDemoAllowed()) return "demo-only";
   if(!IsFullTradeSymbol()) return "symbol-not-full";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return "terminal-algo-off";
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return "ea-trade-off";
   if(!CostOK()) return "spread-cost";
   if(!DailyLossOK()) return "daily-loss-stop";
   if(InpMaxConsecutiveLosses>0 && g_consecutiveLosses>=InpMaxConsecutiveLosses) return "loss-streak-stop";
   if(InpMaxTradesPerHour>0 && CountEntriesLastHour()>=InpMaxTradesPerHour) return "hourly-cap";
   if(InpCooldownAfterExitMs>0 && g_lastExitMs>0 && nowMs-g_lastExitMs<InpCooldownAfterExitMs) return "cooldown";
   return "";
}

//--------------------------- Tick engine -----------------------------
void PushBid(const MqlTick &t)
{
   g_bid[g_head]=t.bid;
   g_ms[g_head]=t.time_msc;
   g_head=(g_head+1)%TICK_BUF;
   if(g_count<TICK_BUF) g_count++;
   g_tickSerial++;
}

bool TickAt(const int offset,double &bid,long &ms)
{
   if(offset<0 || offset>=g_count) return false;
   int idx=g_head-1-offset;
   while(idx<0) idx+=TICK_BUF;
   idx%=TICK_BUF;
   bid=g_bid[idx]; ms=g_ms[idx];
   return true;
}

bool GetMicroRange(double &hi,double &lo,double &widthPts)
{
   hi=-DBL_MAX; lo=DBL_MAX; widthPts=0.0;
   int n=InpMicroRangeTicks;
   if(n<3 || g_count<n+1) return false;

   // Current tick is excluded; it is the potential breakout tick.
   for(int off=1;off<=n;++off)
   {
      double b=0.0; long ms=0;
      if(!TickAt(off,b,ms)) return false;
      if(b>hi) hi=b;
      if(b<lo) lo=b;
   }

   widthPts=(hi-lo)/_Point;
   return (widthPts>=InpMinMicroRangePoints && widthPts<=InpMaxMicroRangePoints);
}

bool BurstConfirm(const int breakoutDir,double &burstPts,double &velocity)
{
   burstPts=0.0; velocity=0.0;
   if(InpBurstTicks<2 || g_count<InpBurstTicks) return false;
   double newest=0.0,oldest=0.0; long newestMs=0,oldestMs=0;
   TickAt(0,newest,newestMs);
   TickAt(InpBurstTicks-1,oldest,oldestMs);

   for(int off=InpBurstTicks-1;off>=1;--off)
   {
      double a=0.0,b=0.0; long ta=0,tb=0;
      TickAt(off,a,ta); TickAt(off-1,b,tb);
      if(breakoutDir>0 && b<=a) return false;
      if(breakoutDir<0 && b>=a) return false;
   }

   burstPts=(breakoutDir>0?(newest-oldest):(oldest-newest))/_Point;
   long dt=newestMs-oldestMs;
   if(dt<=0) return false;
   velocity=burstPts/((double)dt/1000.0);
   return (burstPts>=InpBurstMinPoints && velocity>=InpMinVelocityPointsPerSec);
}

bool MomentumConfirm(const int breakoutDir,double &netPts,double &bias,double &pressure)
{
   netPts=0.0; bias=0.0; pressure=0.0;
   int n=InpMomentumWindowTicks;
   if(n<3 || g_count<n) return false;

   double newest=0.0,oldest=0.0; long tn=0,to=0;
   TickAt(0,newest,tn); TickAt(n-1,oldest,to);
   netPts=(newest-oldest)/_Point;

   int up=0,down=0,meaningful=0;
   for(int off=n-1;off>=1;--off)
   {
      double a=0.0,b=0.0; long ta=0,tb=0;
      TickAt(off,a,ta); TickAt(off-1,b,tb);
      if(b>a){up++;meaningful++;}
      else if(b<a){down++;meaningful++;}
   }
   if(meaningful<=0) return false;

   double upBias=(double)up/(double)meaningful;
   double dnBias=(double)down/(double)meaningful;
   bias=(breakoutDir>0?upBias:dnBias);
   pressure=100.0*MathAbs((double)(up-down))/(double)meaningful;

   if(breakoutDir>0 && netPts<InpMinMomentumNetPoints) return false;
   if(breakoutDir<0 && netPts>-InpMinMomentumNetPoints) return false;
   return (bias>=InpMinTickBias && pressure>=InpMinPressurePct);
}

void ResetArm(const string why)
{
   if(g_armDir!=0) Log("ARM reset reason="+why);
   g_armDir=0; g_breakoutLevel=0.0; g_armSerial=0;
}

//--------------------------- Position logic --------------------------
int CountOurPositions()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      c++;
   }
   return c;
}

bool GetOurPosition(ulong &ticket,ENUM_POSITION_TYPE &type,double &open,double &sl,double &tp,long &openMs)
{
   ticket=0;open=sl=tp=0.0;openMs=0;
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      ticket=t;
      type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      open=PositionGetDouble(POSITION_PRICE_OPEN);
      sl=PositionGetDouble(POSITION_SL);
      tp=PositionGetDouble(POSITION_TP);
      openMs=(long)PositionGetInteger(POSITION_TIME_MSC);
      return true;
   }
   return false;
}

bool EffectiveRiskOK(const int tradeDir,const double entry,const double sl)
{
   double loss=0.0;
   ENUM_ORDER_TYPE typ=(tradeDir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   if(!OrderCalcProfit(typ,_Symbol,InpFixedLots,entry,sl,loss)) return false;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0.0) return false;
   double pct=100.0*MathAbs(loss)/eq;
   if(pct>InpMaxEffectiveRiskPct)
   {
      Log(StringFormat("Entry blocked effectiveRisk=%.3f%% cap=%.3f%%",pct,InpMaxEffectiveRiskPct));
      return false;
   }
   return true;
}

bool PlaceReverseMarketEntry(const int breakoutDir,const MqlTick &tick)
{
   int tradeDir=-breakoutDir;
   if(tradeDir==0) return false;

   if(g_lastEntryDir==tradeDir && InpSameDirectionPauseMs>0 && g_lastEntryMs>0 && tick.time_msc-g_lastEntryMs<InpSameDirectionPauseMs)
   {
      Log("Entry blocked same-direction-pause");
      return false;
   }

   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int stopPts=MathMax(InpStopLossPoints,stops+2);
   int tpPts=MathMax(InpTakeProfitPoints,stops+2);

   double expected=(tradeDir>0?tick.ask:tick.bid);
   double sl=NormalizeDouble((tradeDir>0?expected-stopPts*_Point:expected+stopPts*_Point),digits);
   double tp=NormalizeDouble((tradeDir>0?expected+tpPts*_Point:expected-tpPts*_Point),digits);
   if(!EffectiveRiskOK(tradeDir,expected,sl)) return false;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxFillSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok=false;
   if(tradeDir>0) ok=trade.Buy(InpFixedLots,_Symbol,0.0,sl,tp,"XAU-HS61R BUY FADE");
   else           ok=trade.Sell(InpFixedLots,_Symbol,0.0,sl,tp,"XAU-HS61R SELL FADE");

   if(!ok)
   {
      Log(StringFormat("ENTRY failed signal=%s reverse=%s ret=%u %s",DirText(breakoutDir),DirText(tradeDir),trade.ResultRetcode(),trade.ResultRetcodeDescription()));
      return false;
   }

   g_expectedEntry=expected;
   g_expectedDir=tradeDir;
   Log(StringFormat("REVERSE ENTRY breakout=%s -> trade=%s expected=%.2f sl=%.2f tp=%.2f spread=%.1f",
                    DirText(breakoutDir),DirText(tradeDir),expected,sl,tp,SpreadPts()));
   return true;
}

bool ClosePosition(const ulong ticket,const string why)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpCloseSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   if(trade.PositionClose(ticket))
   {
      Log(StringFormat("CLOSE #%I64u reason=%s",ticket,why));
      return true;
   }
   Log(StringFormat("Close failed #%I64u ret=%u %s",ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription()));
   return false;
}

void ManagePosition(const MqlTick &tick)
{
   ulong ticket=0; ENUM_POSITION_TYPE type=POSITION_TYPE_BUY; double open=0,sl=0,tp=0; long openMs=0;
   if(!GetOurPosition(ticket,type,open,sl,tp,openMs)) return;

   if(g_forceBadFillClose)
   {
      if(ClosePosition(ticket,"bad-fill")) g_forceBadFillClose=false;
      return;
   }

   double p=(type==POSITION_TYPE_BUY?(tick.bid-open):(open-tick.ask))/_Point;
   long held=tick.time_msc-openMs;

   if(InpBreakEvenTriggerPoints>0 && p>=InpBreakEvenTriggerPoints && tick.time_msc-g_lastModifyMs>=250)
   {
      double newSL=NormalizeDouble((type==POSITION_TYPE_BUY?open+InpBreakEvenLockPoints*_Point:open-InpBreakEvenLockPoints*_Point),_Digits);
      bool improve=(type==POSITION_TYPE_BUY?(sl<=0.0 || newSL>sl):(sl<=0.0 || newSL<sl));
      if(improve && trade.PositionModify(ticket,newSL,tp)) g_lastModifyMs=tick.time_msc;
   }

   if(InpTrailStartPoints>0 && p>=InpTrailStartPoints && tick.time_msc-g_lastModifyMs>=250)
   {
      double newSL=NormalizeDouble((type==POSITION_TYPE_BUY?tick.bid-InpTrailDistancePoints*_Point:tick.ask+InpTrailDistancePoints*_Point),_Digits);
      bool improve=(type==POSITION_TYPE_BUY?(sl<=0.0 || newSL>sl):(sl<=0.0 || newSL<sl));
      if(improve && trade.PositionModify(ticket,newSL,tp)) g_lastModifyMs=tick.time_msc;
   }

   if(InpMaxHoldSeconds>0 && held>=(long)InpMaxHoldSeconds*1000)
      ClosePosition(ticket,"time-exit");
}

void Heartbeat(const MqlTick &tick,const double hi,const double lo,const double width,const bool rangeOK)
{
   if(!InpVerboseLogging || InpHeartbeatSeconds<=0) return;
   if(g_lastHeartbeatMs>0 && tick.time_msc-g_lastHeartbeatMs<(long)InpHeartbeatSeconds*1000) return;
   g_lastHeartbeatMs=tick.time_msc;
   string gate=GateReason(tick.time_msc); if(gate=="") gate="OK";
   Log(StringFormat("HB state=%s armBreakout=%s microRange=%.1f valid=%s hi=%.2f lo=%.2f spread=%.1f losses=%d gate=%s",
       (CountOurPositions()>0?"POSITION":"FLAT"),DirText(g_armDir),width,(rangeOK?"YES":"NO"),hi,lo,SpreadPts(),g_consecutiveLosses,gate));
}

//--------------------------- MT5 events ------------------------------
int OnInit()
{
   if(InpFixedLots<=0.0 || InpStopLossPoints<=0 || InpTakeProfitPoints<=0) return INIT_PARAMETERS_INCORRECT;
   if(InpMicroRangeTicks<3 || InpMicroRangeTicks>=TICK_BUF || InpBurstTicks<2 || InpMomentumWindowTicks<3) return INIT_PARAMETERS_INCORRECT;
   if(!IsDemoAllowed())
   {
      Print("[XAU-HS61R] Demo-only guard blocked real account initialization.");
      return INIT_FAILED;
   }
   if(!IsFullTradeSymbol())
   {
      Print("[XAU-HS61R] Symbol not FULL ACCESS. Use your broker's tradable gold symbol, e.g. XAUUSD.a.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   RefreshDayEquity();
   RebuildLossStreak();
   Log(StringFormat("Initialized V6.1R on %s. REVERSED MICRO-RANGE FADE lots=%.2f maxTrades/hr=%d",_Symbol,InpFixedLots,InpMaxTradesPerHour));
   Log("Signal path: micro-range breakout + burst + momentum -> IMMEDIATE OPPOSITE MARKET TRADE.");
   return INIT_SUCCEEDED;
}

void OnTick()
{
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   RefreshDayEquity();
   PushBid(tick);

   double hi=0.0,lo=0.0,width=0.0;
   bool rangeOK=GetMicroRange(hi,lo,width);

   if(CountOurPositions()>0)
   {
      ResetArm("position-open");
      ManagePosition(tick);
      Heartbeat(tick,hi,lo,width,rangeOK);
      return;
   }

   string gate=GateReason(tick.time_msc);
   if(gate!="")
   {
      ResetArm("gate-"+gate);
      Heartbeat(tick,hi,lo,width,rangeOK);
      return;
   }

   if(!rangeOK)
   {
      ResetArm("micro-range-invalid");
      Heartbeat(tick,hi,lo,width,rangeOK);
      return;
   }

   if(g_armDir==0)
   {
      if(tick.bid>=hi+InpBreakoutBufferPoints*_Point)
      {
         g_armDir=1; g_breakoutLevel=hi; g_armSerial=g_tickSerial;
         Log(StringFormat("ARM BREAKOUT BUY microHi=%.2f width=%.1f",hi,width));
      }
      else if(tick.bid<=lo-InpBreakoutBufferPoints*_Point)
      {
         g_armDir=-1; g_breakoutLevel=lo; g_armSerial=g_tickSerial;
         Log(StringFormat("ARM BREAKOUT SELL microLo=%.2f width=%.1f",lo,width));
      }
   }

   if(g_armDir!=0)
   {
      long ageTicks=g_tickSerial-g_armSerial;
      double chase=(g_armDir>0?(tick.bid-g_breakoutLevel):(g_breakoutLevel-tick.bid))/_Point;

      if(ageTicks>InpSignalValidTicks) ResetArm("signal-expired");
      else if(chase>InpMaxChasePoints) ResetArm("max-chase");
      else if(g_armDir>0 && tick.bid<g_breakoutLevel-InpBreakoutBufferPoints*_Point) ResetArm("failed-breakout-before-confirm");
      else if(g_armDir<0 && tick.bid>g_breakoutLevel+InpBreakoutBufferPoints*_Point) ResetArm("failed-breakout-before-confirm");
      else
      {
         double burst=0.0,vel=0.0,net=0.0,bias=0.0,pressure=0.0;
         bool b=BurstConfirm(g_armDir,burst,vel);
         bool m=MomentumConfirm(g_armDir,net,bias,pressure);
         if(b && m)
         {
            int breakoutDir=g_armDir;
            Log(StringFormat("CONFIRM EXHAUSTION breakout=%s burst=%.1f vel=%.1f net=%.1f bias=%.2f pressure=%.0f chase=%.1f -> FADE %s",
                             DirText(breakoutDir),burst,vel,net,bias,pressure,chase,DirText(-breakoutDir)));
            ResetArm("consumed-reverse");
            PlaceReverseMarketEntry(breakoutDir,tick);
         }
      }
   }

   Heartbeat(tick,hi,lo,width,rangeOK);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((long)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol) return;

   ENUM_DEAL_ENTRY e=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(e==DEAL_ENTRY_IN || e==DEAL_ENTRY_INOUT)
   {
      ENUM_DEAL_TYPE dt=(ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal,DEAL_TYPE);
      int dir=(dt==DEAL_TYPE_BUY?1:(dt==DEAL_TYPE_SELL?-1:0));
      double fill=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
      long tms=(long)HistoryDealGetInteger(trans.deal,DEAL_TIME_MSC);
      g_lastEntryMs=tms; g_lastEntryDir=dir;

      if(g_expectedEntry>0.0 && dir==g_expectedDir)
      {
         double slip=(dir>0?(fill-g_expectedEntry):(g_expectedEntry-fill))/_Point;
         Log(StringFormat("FILL %s price=%.2f expected=%.2f slippage=%.1fpts",DirText(dir),fill,g_expectedEntry,slip));
         if(InpMaxFillSlippagePoints>0 && slip>InpMaxFillSlippagePoints)
         {
            g_forceBadFillClose=true;
            Log(StringFormat("BAD FILL %.1fpts > %dpts; close on next tick",slip,InpMaxFillSlippagePoints));
         }
      }
      g_expectedEntry=0.0; g_expectedDir=0;
      return;
   }

   if(e==DEAL_ENTRY_OUT || e==DEAL_ENTRY_OUT_BY)
   {
      double pnl=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)+HistoryDealGetDouble(trans.deal,DEAL_SWAP)+HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
      g_lastExitMs=(long)HistoryDealGetInteger(trans.deal,DEAL_TIME_MSC);
      if(pnl<0.0) g_consecutiveLosses++; else g_consecutiveLosses=0;
      g_forceBadFillClose=false;
      Log(StringFormat("EXIT pnl=%.2f consecutiveLosses=%d",pnl,g_consecutiveLosses));
   }
}
//+------------------------------------------------------------------+
