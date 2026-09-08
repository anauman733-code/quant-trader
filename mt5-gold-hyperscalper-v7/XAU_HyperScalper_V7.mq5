//+------------------------------------------------------------------+
//| XAU_HyperScalper_V7.mq5                                         |
//| Evidence-driven XAUUSD tick breakout EA                          |
//| Derived from 90k+ V7 DATA observations. Demo-first research.     |
//+------------------------------------------------------------------+
#property strict
#property version   "7.10"
#property description "Evidence-driven XAUUSD breakout EA using low-cost/high-activity gates learned from V7 DATA. Demo-first."

#include <Trade/Trade.mqh>
CTrade trade;

#define TICK_BUF 256

input group "Safety"
input bool   InpDemoOnly                    = true;
input bool   InpEnableTrading               = true;
input long   InpMagicNumber                 = 26090870;
input double InpFixedLots                   = 0.01;
input double InpMaxEffectiveRiskPct         = 0.10;
input double InpDailyLossStopPct            = 1.50;
input int    InpMaxConsecutiveLosses        = 12;
input int    InpMaxTradesPerHour            = 30;
input int    InpCooldownAfterExitMs         = 500;
input int    InpSameDirectionPauseMs        = 1500;

input group "V6 Candidate Engine"
input int    InpRangeLookbackBars           = 2;
input int    InpMinRangePoints              = 70;
input int    InpMaxRangePoints              = 450;
input int    InpBreakoutBufferPoints        = 8;
input int    InpMaxChasePoints              = 45;
input int    InpSignalValidTicks            = 60;
input int    InpBurstTicks                  = 3;
input double InpBurstMinPoints              = 5.0;
input double InpMinVelocityPointsPerSec     = 7.0;
input int    InpMomentumWindowTicks         = 10;
input double InpMinMomentumNetPoints        = 9.0;
input double InpMinTickBias                 = 0.60;
input double InpMinPressurePct              = 25.0;

input group "V7 Evidence Gate"
input int    InpStatsWindowTicks            = 32;
input int    InpCoreMaxSpreadPoints         = 7;
input double InpCoreMinRangePoints          = 284.0;
input double InpCoreMinAvgAbsDelta32        = 5.0;
input int    InpExpansionMaxSpreadPoints    = 8;
input double InpExpansionMinRangePoints     = 322.0;
input double InpExpansionMinAvgAbsDelta32   = 4.0;

input group "Execution / Exit"
input int    InpMaxEntrySlippagePoints      = 10;
input int    InpBadFillClosePoints          = 12;
input int    InpCloseSlippagePoints         = 15;
input int    InpStopLossPoints              = 15;
input int    InpTakeProfitPoints            = 400;
input int    InpMaxHoldSeconds              = 20;
input double InpCommissionEstimatePts       = 7.0;

input group "Diagnostics"
input bool   InpVerboseLogging              = true;
input int    InpHeartbeatSeconds            = 5;

//--------------------------- Tick state ------------------------------
double g_bid[TICK_BUF];
long   g_ms[TICK_BUF];
int    g_count=0;
int    g_head=0;
long   g_tickSerial=0;

int    g_armDir=0;
double g_breakoutLevel=0.0;
long   g_armSerial=0;

long   g_lastExitMs=0;
long   g_lastEntryMs=0;
int    g_lastEntryDir=0;
long   g_lastSignalMs=0;
long   g_lastBuySignalMs=0;
long   g_lastSellSignalMs=0;
long   g_lastHeartbeatMs=0;
int    g_consecutiveLosses=0;

double g_dayStartEquity=0.0;
string g_dayKey="";

double g_expectedEntry=0.0;
int    g_expectedDir=0;
bool   g_forceBadFillClose=false;
bool   g_realignProtection=false;

//--------------------------- Helpers --------------------------------
void Log(const string s)
{
   if(InpVerboseLogging) Print("[XAU-HS7] ",s);
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

string MakeDayKey()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   long login=(long)AccountInfoInteger(ACCOUNT_LOGIN);
   return StringFormat("XAUHS7_%I64d_%I64d_%04d%02d%02d",login,InpMagicNumber,dt.year,dt.mon,dt.day);
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
   for(int i=0;i<HistoryDealsTotal();i++)
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
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); dt.hour=0; dt.min=0; dt.sec=0;
   datetime start=StructToTime(dt);
   if(!HistorySelect(start,TimeCurrent())) return;
   for(int i=HistoryDealsTotal()-1;i>=0;i--)
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
   if(!DailyLossOK()) return "daily-loss-stop";
   if(InpMaxConsecutiveLosses>0 && g_consecutiveLosses>=InpMaxConsecutiveLosses) return "loss-streak-stop";
   if(InpMaxTradesPerHour>0 && CountEntriesLastHour()>=InpMaxTradesPerHour) return "hourly-cap";
   if(InpCooldownAfterExitMs>0 && g_lastExitMs>0 && nowMs-g_lastExitMs<InpCooldownAfterExitMs) return "cooldown";
   return "";
}

//--------------------------- Tick analytics --------------------------
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

bool GetRange(double &hi,double &lo,double &widthPts)
{
   hi=-DBL_MAX; lo=DBL_MAX; widthPts=0.0;
   if(InpRangeLookbackBars<1) return false;
   for(int s=1;s<=InpRangeLookbackBars;s++)
   {
      double h=iHigh(_Symbol,PERIOD_M1,s);
      double l=iLow(_Symbol,PERIOD_M1,s);
      if(h<=0.0 || l<=0.0 || h<=l) return false;
      if(h>hi) hi=h;
      if(l<lo) lo=l;
   }
   widthPts=(hi-lo)/_Point;
   return (widthPts>=InpMinRangePoints && widthPts<=InpMaxRangePoints);
}

bool BurstConfirm(const int dir,double &burstPts,double &velocity)
{
   burstPts=0.0; velocity=0.0;
   if(InpBurstTicks<2 || g_count<InpBurstTicks) return false;
   double newest=0.0,oldest=0.0; long newestMs=0,oldestMs=0;
   if(!TickAt(0,newest,newestMs) || !TickAt(InpBurstTicks-1,oldest,oldestMs)) return false;
   for(int off=InpBurstTicks-1;off>=1;off--)
   {
      double a=0.0,b=0.0; long ta=0,tb=0;
      if(!TickAt(off,a,ta) || !TickAt(off-1,b,tb)) return false;
      if(dir>0 && b<=a) return false;
      if(dir<0 && b>=a) return false;
   }
   burstPts=(dir>0 ? newest-oldest : oldest-newest)/_Point;
   long dt=newestMs-oldestMs;
   if(dt<=0) return false;
   velocity=burstPts/((double)dt/1000.0);
   return (burstPts>=InpBurstMinPoints && velocity>=InpMinVelocityPointsPerSec);
}

bool DirectionalStats(const int n,const int dir,double &netPts,double &bias,double &pressure,double &rangePts,double &avgAbsDeltaPts)
{
   netPts=0.0; bias=0.0; pressure=0.0; rangePts=0.0; avgAbsDeltaPts=0.0;
   if(n<3 || g_count<n) return false;
   double newest=0.0,oldest=0.0; long tn=0,to=0;
   if(!TickAt(0,newest,tn) || !TickAt(n-1,oldest,to)) return false;
   double rawNet=(newest-oldest)/_Point;
   netPts=(dir>0 ? rawNet : -rawNet);

   int up=0,down=0,meaningful=0;
   double hi=-DBL_MAX,lo=DBL_MAX,absSum=0.0;
   for(int off=n-1;off>=0;off--)
   {
      double p=0.0; long tm=0;
      if(!TickAt(off,p,tm)) return false;
      if(p>hi) hi=p;
      if(p<lo) lo=p;
      if(off>=1)
      {
         double q=0.0; long tq=0;
         if(!TickAt(off-1,q,tq)) return false;
         double d=(q-p)/_Point;
         absSum+=MathAbs(d);
         if(d>0.0){up++;meaningful++;}
         else if(d<0.0){down++;meaningful++;}
      }
   }
   if(meaningful<=0) return false;
   double upBias=(double)up/(double)meaningful;
   double dnBias=(double)down/(double)meaningful;
   bias=(dir>0 ? upBias : dnBias);
   pressure=100.0*MathAbs((double)(up-down))/(double)meaningful;
   rangePts=(hi-lo)/_Point;
   avgAbsDeltaPts=absSum/(double)(n-1);
   return true;
}

bool CoreMomentumConfirm(const int dir,double &net,double &bias,double &pressure)
{
   double rangePts=0.0,avgAbs=0.0;
   if(!DirectionalStats(InpMomentumWindowTicks,dir,net,bias,pressure,rangePts,avgAbs)) return false;
   return (net>=InpMinMomentumNetPoints && bias>=InpMinTickBias && pressure>=InpMinPressurePct);
}

bool EvidenceGate(const int dir,const double width,double &avgAbs32,string &tier)
{
   tier="NONE";
   double net32=0.0,bias32=0.0,pressure32=0.0,range32=0.0;
   if(!DirectionalStats(InpStatsWindowTicks,dir,net32,bias32,pressure32,range32,avgAbs32)) return false;
   double s=SpreadPts();

   bool core=(s<=InpCoreMaxSpreadPoints && width>=InpCoreMinRangePoints && avgAbs32>=InpCoreMinAvgAbsDelta32);
   bool expansion=(s<=InpExpansionMaxSpreadPoints && width>=InpExpansionMinRangePoints && avgAbs32>=InpExpansionMinAvgAbsDelta32);
   if(core){tier="CORE"; return true;}
   if(expansion){tier="EXPANSION"; return true;}
   return false;
}

void ResetArm(const string why)
{
   if(g_armDir!=0) Log("ARM reset reason="+why);
   g_armDir=0; g_breakoutLevel=0.0; g_armSerial=0;
}

void MarkCandidate(const int dir,const long nowMs)
{
   g_lastSignalMs=nowMs;
   if(dir>0) g_lastBuySignalMs=nowMs;
   else if(dir<0) g_lastSellSignalMs=nowMs;
}

bool CandidateThrottleOK(const int dir,const long nowMs)
{
   if(InpCooldownAfterExitMs>0 && g_lastSignalMs>0 && nowMs-g_lastSignalMs<InpCooldownAfterExitMs) return false;
   long dms=(dir>0 ? g_lastBuySignalMs : g_lastSellSignalMs);
   if(InpSameDirectionPauseMs>0 && dms>0 && nowMs-dms<InpSameDirectionPauseMs) return false;
   return true;
}

//--------------------------- Positions -------------------------------
int CountOurPositions()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
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
   ticket=0; open=sl=tp=0.0; openMs=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
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

bool EffectiveRiskOK(const int dir,const double entry,const double sl)
{
   double loss=0.0;
   ENUM_ORDER_TYPE typ=(dir>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(typ,_Symbol,InpFixedLots,entry,sl,loss)) return false;
   loss=MathAbs(loss);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0.0) return false;
   double pct=100.0*loss/eq;
   if(pct>InpMaxEffectiveRiskPct)
   {
      Log(StringFormat("Entry blocked effectiveRisk=%.3f%% cap=%.3f%%",pct,InpMaxEffectiveRiskPct));
      return false;
   }
   return true;
}

bool PlaceMarketEntry(const int dir,const MqlTick &tick,const string tier,const double avgAbs32)
{
   if(dir==0) return false;
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int freeze=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   int minDist=MathMax(stops,freeze)+2;
   if(minDist>InpStopLossPoints)
   {
      Log(StringFormat("ENTRY blocked broker min distance=%d > tested SL=%d",minDist,InpStopLossPoints));
      return false;
   }

   double ref=(dir>0 ? tick.ask : tick.bid);
   double sl=NormalizeDouble((dir>0 ? ref-InpStopLossPoints*_Point : ref+InpStopLossPoints*_Point),_Digits);
   double tp=NormalizeDouble((dir>0 ? ref+InpTakeProfitPoints*_Point : ref-InpTakeProfitPoints*_Point),_Digits);
   if(!EffectiveRiskOK(dir,ref,sl)) return false;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(InpMaxEntrySlippagePoints);

   bool ok=(dir>0 ? trade.Buy(InpFixedLots,_Symbol,0.0,sl,tp,"XAU-HS7 BUY")
                  : trade.Sell(InpFixedLots,_Symbol,0.0,sl,tp,"XAU-HS7 SELL"));
   if(!ok)
   {
      Log(StringFormat("ENTRY failed %s ret=%u %s",DirText(dir),trade.ResultRetcode(),trade.ResultRetcodeDescription()));
      return false;
   }

   g_expectedEntry=ref;
   g_expectedDir=dir;
   Log(StringFormat("ENTRY %s tier=%s lots=%.2f ref=%.2f sl=%.2f tp=%.2f spread=%.1f avgAbs32=%.2f",
                    DirText(dir),tier,InpFixedLots,ref,sl,tp,SpreadPts(),avgAbs32));
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
   Log(StringFormat("CLOSE failed #%I64u ret=%u %s",ticket,trade.ResultRetcode(),trade.ResultRetcodeDescription()));
   return false;
}

void ManagePosition(const MqlTick &tick)
{
   ulong ticket=0; ENUM_POSITION_TYPE type=POSITION_TYPE_BUY;
   double open=0.0,sl=0.0,tp=0.0; long openMs=0;
   if(!GetOurPosition(ticket,type,open,sl,tp,openMs)) return;

   if(g_forceBadFillClose)
   {
      if(ClosePosition(ticket,"bad-fill")) g_forceBadFillClose=false;
      return;
   }

   if(g_realignProtection)
   {
      double desiredSL=NormalizeDouble((type==POSITION_TYPE_BUY ? open-InpStopLossPoints*_Point : open+InpStopLossPoints*_Point),_Digits);
      double desiredTP=NormalizeDouble((type==POSITION_TYPE_BUY ? open+InpTakeProfitPoints*_Point : open-InpTakeProfitPoints*_Point),_Digits);
      if(trade.PositionModify(ticket,desiredSL,desiredTP))
      {
         g_realignProtection=false;
         Log(StringFormat("PROTECTION realigned #%I64u SL=%.2f TP=%.2f",ticket,desiredSL,desiredTP));
      }
   }

   long held=tick.time_msc-openMs;
   if(InpMaxHoldSeconds>0 && held>=(long)InpMaxHoldSeconds*1000)
      ClosePosition(ticket,"20s-time-exit");
}

//--------------------------- Diagnostics -----------------------------
void Heartbeat(const MqlTick &tick,const double width)
{
   if(!InpVerboseLogging || InpHeartbeatSeconds<=0) return;
   if(g_lastHeartbeatMs>0 && tick.time_msc-g_lastHeartbeatMs<(long)InpHeartbeatSeconds*1000) return;
   g_lastHeartbeatMs=tick.time_msc;
   string gate=GateReason(tick.time_msc); if(gate=="") gate="OK";
   Log(StringFormat("HB state=%s arm=%s range=%.1f spread=%.1f losses=%d gate=%s",
                    (CountOurPositions()>0?"POSITION":"FLAT"),DirText(g_armDir),width,SpreadPts(),g_consecutiveLosses,gate));
}

//--------------------------- MT5 events ------------------------------
int OnInit()
{
   if(InpFixedLots<=0.0 || InpStopLossPoints<=0 || InpTakeProfitPoints<=0) return INIT_PARAMETERS_INCORRECT;
   if(InpRangeLookbackBars<1 || InpBurstTicks<2 || InpMomentumWindowTicks<3 || InpStatsWindowTicks<3 || InpStatsWindowTicks>=TICK_BUF)
      return INIT_PARAMETERS_INCORRECT;
   if(!IsDemoAllowed())
   {
      Print("[XAU-HS7] Demo-only guard blocked real-account initialization.");
      return INIT_FAILED;
   }
   if(!IsFullTradeSymbol())
   {
      Print("[XAU-HS7] Symbol is not FULL ACCESS. Use the broker's tradable gold symbol, e.g. XAUUSD.a.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   RefreshDayEquity();
   RebuildLossStreak();

   Log(StringFormat("Initialized V7 on %s. DATA-DRIVEN EDGE engine lots=%.2f",_Symbol,InpFixedLots));
   Log(StringFormat("Evidence gates: CORE spread<=%d range>=%.0f avgAbs32>=%.2f | EXP spread<=%d range>=%.0f avgAbs32>=%.2f",
                    InpCoreMaxSpreadPoints,InpCoreMinRangePoints,InpCoreMinAvgAbsDelta32,
                    InpExpansionMaxSpreadPoints,InpExpansionMinRangePoints,InpExpansionMinAvgAbsDelta32));
   Log(StringFormat("Exit architecture from V7 research: SL=%dpts TP=%dpts hold=%ds commission-est=%.1fpts/RT",
                    InpStopLossPoints,InpTakeProfitPoints,InpMaxHoldSeconds,InpCommissionEstimatePts));
   return INIT_SUCCEEDED;
}

void OnTick()
{
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   RefreshDayEquity();
   PushBid(tick);

   double hi=0.0,lo=0.0,width=0.0;
   bool rangeOK=GetRange(hi,lo,width);

   if(CountOurPositions()>0)
   {
      ResetArm("position-open");
      ManagePosition(tick);
      Heartbeat(tick,width);
      return;
   }

   string gate=GateReason(tick.time_msc);
   if(gate!="")
   {
      ResetArm("gate-"+gate);
      Heartbeat(tick,width);
      return;
   }

   if(!rangeOK)
   {
      ResetArm("range-invalid");
      Heartbeat(tick,width);
      return;
   }

   if(g_armDir==0)
   {
      if(tick.bid>=hi+InpBreakoutBufferPoints*_Point)
      {
         g_armDir=1; g_breakoutLevel=hi; g_armSerial=g_tickSerial;
         Log(StringFormat("ARM BUY level=%.2f range=%.1f",hi,width));
      }
      else if(tick.bid<=lo-InpBreakoutBufferPoints*_Point)
      {
         g_armDir=-1; g_breakoutLevel=lo; g_armSerial=g_tickSerial;
         Log(StringFormat("ARM SELL level=%.2f range=%.1f",lo,width));
      }
   }

   if(g_armDir!=0)
   {
      int dir=g_armDir;
      long ageTicks=g_tickSerial-g_armSerial;
      double chase=(dir>0 ? tick.bid-g_breakoutLevel : g_breakoutLevel-tick.bid)/_Point;

      if(ageTicks>InpSignalValidTicks) ResetArm("signal-expired");
      else if(chase>InpMaxChasePoints) ResetArm("max-chase");
      else if(dir>0 && tick.bid<g_breakoutLevel-InpBreakoutBufferPoints*_Point) ResetArm("failed-breakout");
      else if(dir<0 && tick.bid>g_breakoutLevel+InpBreakoutBufferPoints*_Point) ResetArm("failed-breakout");
      else
      {
         double burst=0.0,velocity=0.0,net10=0.0,bias10=0.0,pressure10=0.0;
         bool b=BurstConfirm(dir,burst,velocity);
         bool m=CoreMomentumConfirm(dir,net10,bias10,pressure10);
         if(b && m && CandidateThrottleOK(dir,tick.time_msc))
         {
            double avgAbs32=0.0; string tier="NONE";
            bool edge=EvidenceGate(dir,width,avgAbs32,tier);
            MarkCandidate(dir,tick.time_msc);
            Log(StringFormat("CONFIRM %s burst=%.1f vel=%.1f mom10=%.1f bias=%.2f pressure=%.0f chase=%.1f range=%.1f spread=%.1f avgAbs32=%.2f edge=%s",
                             DirText(dir),burst,velocity,net10,bias10,pressure10,chase,width,SpreadPts(),avgAbs32,(edge?tier:"REJECT")));
            ResetArm("consumed");
            if(edge) PlaceMarketEntry(dir,tick,tier,avgAbs32);
         }
      }
   }

   Heartbeat(tick,width);
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
      int dir=(dt==DEAL_TYPE_BUY ? 1 : (dt==DEAL_TYPE_SELL ? -1 : 0));
      double fill=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
      long tms=(long)HistoryDealGetInteger(trans.deal,DEAL_TIME_MSC);
      g_lastEntryMs=tms; g_lastEntryDir=dir;
      g_realignProtection=true;

      if(g_expectedEntry>0.0 && dir==g_expectedDir)
      {
         double slip=(dir>0 ? fill-g_expectedEntry : g_expectedEntry-fill)/_Point;
         Log(StringFormat("FILL %s price=%.2f expected=%.2f adverseSlippage=%.1fpts",DirText(dir),fill,g_expectedEntry,slip));
         if(InpBadFillClosePoints>0 && slip>InpBadFillClosePoints)
         {
            g_forceBadFillClose=true;
            Log(StringFormat("BAD FILL %.1fpts > %dpts; close next tick",slip,InpBadFillClosePoints));
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
      g_realignProtection=false;
      Log(StringFormat("EXIT dealPnl=%.2f consecutiveLosses=%d",pnl,g_consecutiveLosses));
   }
}
//+------------------------------------------------------------------+
