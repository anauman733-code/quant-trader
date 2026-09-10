from __future__ import annotations
import argparse, math, os
from datetime import datetime, timedelta, timezone
import numpy as np
import joblib
import MetaTrader5 as mt5
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import balanced_accuracy_score, classification_report, confusion_matrix
from forecast_features import make_features, FEATURE_NAMES

SYMBOL='XAUUSD.a'
MODEL_FILE='xau_signal_outcome_v3.joblib'
MODES=('momentum','pullback','mean_reversion')

# Match the live V1/V2 signal engine.
MOMENTUM_NET_8=10.0; MOMENTUM_BIAS_8=0.70
TREND_NET_30=22.0; TREND_BIAS_30=0.62; PULLBACK_RETRACE_5=4.0
REVERSION_Z=1.65; REVERSION_STALL_4=3.0


def fetch_ticks(days:int):
    end=datetime.now(timezone.utc)
    start=end-timedelta(days=days)
    chunks=[]; cur=start
    while cur<end:
        nxt=min(cur+timedelta(days=1),end)
        a=mt5.copy_ticks_range(SYMBOL,cur,nxt,mt5.COPY_TICKS_ALL)
        n=0 if a is None else len(a)
        print(f'Fetched {cur.date()} -> {nxt.date()} : {n:,} ticks')
        if a is not None and len(a): chunks.append(a)
        cur=nxt
    if not chunks: raise RuntimeError('No historical ticks returned by MT5')
    return np.concatenate(chunks)


def bias(x):
    d=np.diff(x); nz=d[d!=0]
    if len(nz)==0: return 0.5,0.5
    up=float(np.mean(nz>0)); return up,1.0-up


def candidate(bids, point):
    if len(bids)<50: return None
    s8=bids[-8:]; s30=bids[-30:]; s50=bids[-50:]; s5=bids[-5:]; s4=bids[-4:]
    net8=(s8[-1]-s8[0])/point; net30=(s30[-1]-s30[0])/point
    net5=(s5[-1]-s5[0])/point; net4=(s4[-1]-s4[0])/point
    up8,dn8=bias(s8); up30,dn30=bias(s30)
    if net8>=MOMENTUM_NET_8 and up8>=MOMENTUM_BIAS_8:
        return 1,'momentum',net8*up8
    if net8<=-MOMENTUM_NET_8 and dn8>=MOMENTUM_BIAS_8:
        return -1,'momentum',(-net8)*dn8
    last=(s5[-1]-s5[-2])/point
    if net30>=TREND_NET_30 and up30>=TREND_BIAS_30 and net5<=-PULLBACK_RETRACE_5 and last>0:
        return 1,'pullback',net30*up30+abs(net5)
    if net30<=-TREND_NET_30 and dn30>=TREND_BIAS_30 and net5>=PULLBACK_RETRACE_5 and last<0:
        return -1,'pullback',(-net30)*dn30+abs(net5)
    sd=float(np.std(s50))
    if sd>0:
        z=(s50[-1]-float(np.mean(s50)))/sd
        if z>=REVERSION_Z and net4<=REVERSION_STALL_4:
            return -1,'mean_reversion',abs(z)*10.0
        if z<=-REVERSION_Z and net4>=-REVERSION_STALL_4:
            return 1,'mean_reversion',abs(z)*10.0
    return None


def simulate_trade(i, direction, times, bids, asks, point, horizon_ms, sl_pts, tp_pts, commission_pts):
    entry=asks[i] if direction>0 else bids[i]
    end_t=int(times[i])+horizon_ms
    j_end=int(np.searchsorted(times,end_t,side='left'))
    j_end=min(j_end,len(times)-1)
    exit_idx=j_end
    if direction>0:
        sl=entry-sl_pts*point; tp=entry+tp_pts*point
        for j in range(i+1,j_end+1):
            px=bids[j]
            if px<=sl or px>=tp:
                exit_idx=j; break
        gross=(bids[exit_idx]-entry)/point
    else:
        sl=entry+sl_pts*point; tp=entry-tp_pts*point
        for j in range(i+1,j_end+1):
            px=asks[j]
            if px>=sl or px<=tp:
                exit_idx=j; break
        gross=(entry-asks[exit_idx])/point
    net=float(gross)-commission_pts
    return net,int(times[exit_idx])


def build_dataset(ticks, point, candidate_gap_ms, horizon_ms, sl_pts, tp_pts, commission_pts, max_candidates):
    times=ticks['time_msc'].astype(np.int64)
    bids=ticks['bid'].astype(float); asks=ticks['ask'].astype(float)
    good=(bids>0)&(asks>0)&(asks>=bids)
    times,bids,asks=times[good],bids[good],asks[good]
    out=[]; last_candidate=-10**18
    for i in range(50,len(times)-1):
        t=int(times[i])
        if t-last_candidate<candidate_gap_ms: continue
        c=candidate(bids[i-49:i+1],point)
        if c is None: continue
        direction,mode,score=c
        f=make_features(bids[i-49:i+1],asks[i-49:i+1],times[i-49:i+1],point)
        if f is None: continue
        net,exit_t=simulate_trade(i,direction,times,bids,asks,point,horizon_ms,sl_pts,tp_pts,commission_pts)
        x=np.concatenate([f,np.asarray([float(direction),float(score)],dtype=np.float64)])
        out.append((t,exit_t,mode,direction,score,x,net,1 if net>0 else 0))
        last_candidate=t
        if len(out)>=max_candidates: break
    if len(out)<5000: raise RuntimeError(f'Only {len(out)} candidate samples; increase --days or --max-candidates')
    print('Candidate samples:',len(out))
    for m in MODES:
        print(f'  {m}:',sum(1 for r in out if r[2]==m))
    return out


def one_position_stats(rows, probs, threshold):
    chosen=[]
    for r,p in zip(rows,probs):
        if p>=threshold: chosen.append((r,p))
    chosen.sort(key=lambda z:z[0][0])
    free_at=-1; pnls=[]
    for r,p in chosen:
        if r[0]<free_at: continue
        pnls.append(float(r[6])); free_at=int(r[1])
    if not pnls: return None
    a=np.asarray(pnls,float)
    return {'trades':len(a),'win_rate':float(np.mean(a>0)),'avg':float(np.mean(a)),'total':float(np.sum(a)),'median':float(np.median(a))}


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--days',type=int,default=21)
    ap.add_argument('--candidate-gap-ms',type=int,default=300)
    ap.add_argument('--horizon-sec',type=int,default=12)
    ap.add_argument('--sl-points',type=float,default=100.0)
    ap.add_argument('--tp-points',type=float,default=130.0)
    ap.add_argument('--commission-points',type=float,default=7.0)
    ap.add_argument('--max-candidates',type=int,default=180000)
    args=ap.parse_args()

    if not mt5.initialize(): raise RuntimeError(f'MT5 initialize failed: {mt5.last_error()}')
    try:
        sym=mt5.symbol_info(SYMBOL)
        if sym is None: raise RuntimeError(f'{SYMBOL} unavailable')
        ticks=fetch_ticks(args.days)
        rows=build_dataset(ticks,sym.point,args.candidate_gap_ms,args.horizon_sec*1000,args.sl_points,args.tp_points,args.commission_points,args.max_candidates)
        rows.sort(key=lambda r:r[0])
        n=len(rows); t70=rows[int(n*0.70)][0]; t85=rows[int(n*0.85)][0]
        print('Chronological cutoffs:',datetime.fromtimestamp(t70/1000,timezone.utc),datetime.fromtimestamp(t85/1000,timezone.utc))

        bundle={'symbol':SYMBOL,'point':sym.point,'feature_names':FEATURE_NAMES+['signal_direction','signal_score'],
                'horizon_sec':args.horizon_sec,'sl_points':args.sl_points,'tp_points':args.tp_points,
                'commission_points':args.commission_points,'models':{},'thresholds':{},'trained_at':datetime.now().isoformat()}
        thresholds=[0.50,0.55,0.60,0.65,0.70,0.75,0.80]

        for mode in MODES:
            mr=[r for r in rows if r[2]==mode]
            tr=[r for r in mr if r[0]<t70]; va=[r for r in mr if t70<=r[0]<t85]; te=[r for r in mr if r[0]>=t85]
            print('\n'+'='*72); print(mode.upper(),f'train={len(tr)} val={len(va)} holdout={len(te)}')
            if len(tr)<1000 or len(te)<200:
                print('SKIP: insufficient samples for a reliable per-mode model.'); continue
            Xtr=np.vstack([r[5] for r in tr]); ytr=np.asarray([r[7] for r in tr],int)
            Xva=np.vstack([r[5] for r in va]); yva=np.asarray([r[7] for r in va],int) if va else np.empty(0,int)
            Xte=np.vstack([r[5] for r in te]); yte=np.asarray([r[7] for r in te],int)
            counts=np.bincount(ytr,minlength=2).astype(float)
            if np.any(counts==0):
                print('SKIP: training set has one class only.'); continue
            weights=np.where(counts>0,len(ytr)/(2.0*counts),0.0); sw=weights[ytr]
            model=HistGradientBoostingClassifier(max_iter=220,learning_rate=0.05,max_leaf_nodes=31,l2_regularization=2.0,random_state=17)
            model.fit(Xtr,ytr,sample_weight=sw)
            for name,Xs,ys in [('VALIDATION',Xva,yva),('HOLDOUT',Xte,yte)]:
                if len(ys)==0: continue
                pred=model.predict(Xs)
                print(name,'balanced_accuracy=',round(balanced_accuracy_score(ys,pred),4))
                print(confusion_matrix(ys,pred))
                print(classification_report(ys,pred,target_names=['LOSS/NONPOS','PROFIT'],digits=3,zero_division=0))
            pte=model.predict_proba(Xte)[:,list(model.classes_).index(1)]
            print('threshold  trades  win%   avg_net_pts  total_net_pts  median_net_pts')
            candidates=[]
            for th in thresholds:
                st=one_position_stats(te,pte,th)
                if st is None: continue
                print(f'{th:0.2f} {st["trades"]:7d} {st["win_rate"]*100:6.2f} {st["avg"]:12.2f} {st["total"]:13.2f} {st["median"]:14.2f}')
                if st['trades']>=25 and st['avg']>0 and st['total']>0: candidates.append((th,st))
            if candidates:
                # Prefer the positive threshold with the most trades; tie-break by avg net.
                rec=max(candidates,key=lambda z:(z[1]['trades'],z[1]['avg']))
                print(f'RECOMMENDED HOLDOUT THRESHOLD {mode}: {rec[0]:.2f} | trades={rec[1]["trades"]} avg={rec[1]["avg"]:.2f} total={rec[1]["total"]:.2f}')
                bundle['thresholds'][mode]=rec[0]
            else:
                print(f'NO ROBUST POSITIVE HOLDOUT THRESHOLD for {mode}.')
            bundle['models'][mode]=model

        out=os.path.join(os.path.dirname(os.path.abspath(__file__)),MODEL_FILE)
        joblib.dump(bundle,out)
        print('\nMODEL BUNDLE SAVED:',out)
        print('Do NOT demo-trade from this bundle until the HOLDOUT threshold tables are reviewed.')
    finally:
        mt5.shutdown()

if __name__=='__main__': main()
