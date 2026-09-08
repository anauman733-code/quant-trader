from __future__ import annotations
import argparse, math, sys, time
from collections import deque
from dataclasses import dataclass
from datetime import datetime
import MetaTrader5 as mt5

SYMBOL='XAUUSD.a'; MAGIC=26090901; LOT=0.01
MAX_SPREAD_POINTS=15.0; STOP_LOSS_POINTS=100; TAKE_PROFIT_POINTS=130
MAX_HOLD_SECONDS=12.0; COOLDOWN_MS=350; MAX_TRADES_PER_HOUR=120
MAX_CONSECUTIVE_LOSSES=5; DAILY_LOSS_LIMIT=12.0
TICK_BUFFER=120; POLL_SLEEP=0.01; MIN_TICKS_READY=55
MOMENTUM_NET_8=10.0; MOMENTUM_BIAS_8=0.70
TREND_NET_30=22.0; TREND_BIAS_30=0.62; PULLBACK_RETRACE_5=4.0
REVERSION_Z=1.65; REVERSION_STALL_4=3.0

@dataclass
class Tick:
    t_ms:int; bid:float; ask:float
@dataclass
class Signal:
    direction:int; mode:str; score:float; reason:str

class XAUScalper:
    def __init__(self, execute_demo=False):
        self.execute_demo=execute_demo
        self.ticks=deque(maxlen=TICK_BUFFER)
        self.last_tick_ms=0; self.last_exit_ms=0; self.last_entry_ms=0
        self.consecutive_losses=0; self.day_start_balance=0.0; self.day_key=''
    def log(self,msg): print(f"{datetime.now().strftime('%H:%M:%S.%f')[:-3]} | {msg}",flush=True)
    def initialize(self):
        if not mt5.initialize(): raise RuntimeError(f'MT5 initialize failed: {mt5.last_error()}')
        term=mt5.terminal_info(); acc=mt5.account_info(); sym=mt5.symbol_info(SYMBOL)
        if term is None or acc is None or sym is None: raise RuntimeError('terminal/account/symbol unavailable')
        if not term.connected: raise RuntimeError('MT5 terminal disconnected')
        if self.execute_demo and getattr(acc,'trade_mode',2)==2: raise RuntimeError('EXECUTION BLOCKED: real account detected')
        if not mt5.symbol_select(SYMBOL,True): raise RuntimeError(f'Could not select {SYMBOL}')
        if sym.volume_min>LOT+1e-12: raise RuntimeError(f'Lot {LOT} below minimum {sym.volume_min}')
        self.day_start_balance=float(acc.balance); self.day_key=datetime.now().strftime('%Y%m%d')
        self.log(f'CONNECTED {SYMBOL} execute_demo={self.execute_demo} minLot={sym.volume_min} step={sym.volume_step} stops={sym.trade_stops_level} filling_flags={sym.filling_mode}')
        self.log('Modes: MOMENTUM + PULLBACK + MEAN_REVERSION; one position max.')
    def shutdown(self): mt5.shutdown()
    def _series(self,n): return list(self.ticks)[-n:] if len(self.ticks)>=n else []
    @staticmethod
    def _bias(series):
        up=down=0
        for a,b in zip(series[:-1],series[1:]):
            if b.bid>a.bid: up+=1
            elif b.bid<a.bid: down+=1
        tot=up+down
        return (up/tot,down/tot) if tot else (0.5,0.5)
    def signal(self,point):
        if len(self.ticks)<MIN_TICKS_READY: return None
        s8=self._series(8); s30=self._series(30); s50=self._series(50); s5=self._series(5); s4=self._series(4)
        net8=(s8[-1].bid-s8[0].bid)/point; net30=(s30[-1].bid-s30[0].bid)/point
        net5=(s5[-1].bid-s5[0].bid)/point; net4=(s4[-1].bid-s4[0].bid)/point
        up8,dn8=self._bias(s8); up30,dn30=self._bias(s30)
        if net8>=MOMENTUM_NET_8 and up8>=MOMENTUM_BIAS_8: return Signal(1,'momentum',net8*up8,f'net8={net8:.1f} upBias8={up8:.2f}')
        if net8<=-MOMENTUM_NET_8 and dn8>=MOMENTUM_BIAS_8: return Signal(-1,'momentum',(-net8)*dn8,f'net8={net8:.1f} dnBias8={dn8:.2f}')
        last_delta=(s5[-1].bid-s5[-2].bid)/point
        if net30>=TREND_NET_30 and up30>=TREND_BIAS_30 and net5<=-PULLBACK_RETRACE_5 and last_delta>0:
            return Signal(1,'pullback',net30*up30+abs(net5),f'net30={net30:.1f} retrace5={net5:.1f}')
        if net30<=-TREND_NET_30 and dn30>=TREND_BIAS_30 and net5>=PULLBACK_RETRACE_5 and last_delta<0:
            return Signal(-1,'pullback',(-net30)*dn30+abs(net5),f'net30={net30:.1f} retrace5={net5:.1f}')
        bids=[x.bid for x in s50]; mean=sum(bids)/len(bids); var=sum((x-mean)**2 for x in bids)/len(bids); sd=math.sqrt(var)
        if sd>0:
            z=(s50[-1].bid-mean)/sd
            if z>=REVERSION_Z and net4<=REVERSION_STALL_4: return Signal(-1,'mean_reversion',abs(z)*10,f'z={z:.2f} net4={net4:.1f}')
            if z<=-REVERSION_Z and net4>=-REVERSION_STALL_4: return Signal(1,'mean_reversion',abs(z)*10,f'z={z:.2f} net4={net4:.1f}')
        return None
    def our_positions(self):
        p=mt5.positions_get(symbol=SYMBOL)
        return [] if not p else [x for x in p if getattr(x,'magic',0)==MAGIC]
    def recent_entries_last_hour(self):
        end=datetime.now(); start=datetime.fromtimestamp(end.timestamp()-3600)
        deals=mt5.history_deals_get(start,end) or []
        return sum(1 for d in deals if getattr(d,'symbol','')==SYMBOL and getattr(d,'magic',0)==MAGIC and getattr(d,'entry',-1) in (mt5.DEAL_ENTRY_IN,mt5.DEAL_ENTRY_INOUT))
    def safety_ok(self,raw,spread):
        acc=mt5.account_info(); term=mt5.terminal_info()
        if acc is None or term is None or not term.connected: return False
        if self.execute_demo and getattr(acc,'trade_mode',2)==2: return False
        if spread<=0 or spread>MAX_SPREAD_POINTS: return False
        if self.last_exit_ms and raw.time_msc-self.last_exit_ms<COOLDOWN_MS: return False
        if self.consecutive_losses>=MAX_CONSECUTIVE_LOSSES: return False
        if self.recent_entries_last_hour()>=MAX_TRADES_PER_HOUR: return False
        if self.day_start_balance-float(acc.balance)>=DAILY_LOSS_LIMIT: return False
        return True
    def order_request(self,direction,raw,point):
        sym=mt5.symbol_info(SYMBOL); price=raw.ask if direction>0 else raw.bid
        sl=price-STOP_LOSS_POINTS*point if direction>0 else price+STOP_LOSS_POINTS*point
        tp=price+TAKE_PROFIT_POINTS*point if direction>0 else price-TAKE_PROFIT_POINTS*point
        return {'action':mt5.TRADE_ACTION_DEAL,'symbol':SYMBOL,'volume':LOT,'type':mt5.ORDER_TYPE_BUY if direction>0 else mt5.ORDER_TYPE_SELL,
                'price':round(price,sym.digits),'sl':round(sl,sym.digits),'tp':round(tp,sym.digits),'deviation':15,'magic':MAGIC,
                'comment':'PY-XAU-MR1','type_time':mt5.ORDER_TIME_GTC,'type_filling':mt5.ORDER_FILLING_IOC}
    def submit(self,sig,raw,point):
        req=self.order_request(sig.direction,raw,point); check=mt5.order_check(req)
        if check is None or getattr(check,'retcode',-1)!=0:
            self.log(f'ORDER_CHECK reject {check if check else mt5.last_error()}'); return
        if not self.execute_demo:
            self.log(f"DRY SIGNAL {sig.mode.upper()} {'BUY' if sig.direction>0 else 'SELL'} score={sig.score:.1f} | {sig.reason}"); return
        result=mt5.order_send(req)
        if result is None or result.retcode!=mt5.TRADE_RETCODE_DONE:
            self.log(f'ORDER reject {result if result else mt5.last_error()}'); return
        self.log(f"OPEN {sig.mode.upper()} {'BUY' if sig.direction>0 else 'SELL'} lot={LOT:.2f} fill={result.price:.2f} score={sig.score:.1f} | {sig.reason}")
    def close_position(self,p,why):
        raw=mt5.symbol_info_tick(SYMBOL)
        if raw is None or not self.execute_demo: return
        req={'action':mt5.TRADE_ACTION_DEAL,'symbol':SYMBOL,'position':p.ticket,'volume':p.volume,
             'type':mt5.ORDER_TYPE_SELL if p.type==mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY,
             'price':raw.bid if p.type==mt5.POSITION_TYPE_BUY else raw.ask,'deviation':20,'magic':MAGIC,
             'comment':f'PY-XAU {why}','type_time':mt5.ORDER_TIME_GTC,'type_filling':mt5.ORDER_FILLING_IOC}
        r=mt5.order_send(req)
        if r is not None and r.retcode==mt5.TRADE_RETCODE_DONE:
            self.last_exit_ms=int(time.time()*1000); self.log(f'CLOSE #{p.ticket} reason={why} fill={r.price:.2f}')
    def manage(self):
        for p in self.our_positions():
            if time.time()-float(p.time)>=MAX_HOLD_SECONDS: self.close_position(p,'time-exit')
    def update_loss_streak(self):
        end=datetime.now(); start=datetime.fromtimestamp(end.timestamp()-86400); deals=mt5.history_deals_get(start,end) or []
        exits=[d for d in deals if getattr(d,'symbol','')==SYMBOL and getattr(d,'magic',0)==MAGIC and getattr(d,'entry',-1) in (mt5.DEAL_ENTRY_OUT,mt5.DEAL_ENTRY_OUT_BY)]
        exits.sort(key=lambda d:getattr(d,'time_msc',0),reverse=True); streak=0
        for d in exits:
            pnl=float(getattr(d,'profit',0))+float(getattr(d,'commission',0))+float(getattr(d,'swap',0))
            if pnl<0: streak+=1
            else: break
        self.consecutive_losses=streak
    def run(self):
        sym=mt5.symbol_info(SYMBOL); point=sym.point; last_streak=0.0
        self.log('RUNNING. Ctrl+C stops the bot.')
        while True:
            raw=mt5.symbol_info_tick(SYMBOL)
            if raw is None: time.sleep(POLL_SLEEP); continue
            if raw.time_msc==self.last_tick_ms: self.manage(); time.sleep(POLL_SLEEP); continue
            self.last_tick_ms=raw.time_msc; self.ticks.append(Tick(raw.time_msc,raw.bid,raw.ask))
            if time.time()-last_streak>2: self.update_loss_streak(); last_streak=time.time()
            if self.our_positions(): self.manage(); continue
            spread=(raw.ask-raw.bid)/point
            if not self.safety_ok(raw,spread): continue
            sig=self.signal(point)
            if sig: self.submit(sig,raw,point)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--execute-demo',action='store_true'); args=ap.parse_args()
    bot=XAUScalper(args.execute_demo)
    try: bot.initialize(); bot.run()
    except KeyboardInterrupt: bot.log('Stopped by user.')
    finally: bot.shutdown()
if __name__=='__main__': main()
