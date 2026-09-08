from __future__ import annotations
import argparse, os, random
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import joblib
import MetaTrader5 as mt5
import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import balanced_accuracy_score, classification_report, confusion_matrix

from forecast_features import make_features, FEATURE_NAMES

SYMBOL='XAUUSD.a'
MODEL_FILE='xau_signal_outcome_v4.joblib'
MODES=('momentum','pullback','mean_reversion')

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


def all_candidates(bids, point):
    if len(bids)<50: return []
    out=[]
    s8=bids[-8:]; s30=bids[-30:]; s50=bids[-50:]; s5=bids[-5:]; s4=bids[-4:]
    net8=(s8[-1]-s8[0])/point; net30=(s30[-1]-s30[0])/point
    net5=(s5[-1]-s5[0])/point; net4=(s4[-1]-s4[0])/point
    up8,dn8=bias(s8); up30,dn30=bias(s30)

    if net8>=MOMENTUM_NET_8 and up8>=MOMENTUM_BIAS_8:
        out.append((1,'momentum',net8*up8))
    elif net8<=-MOMENTUM_NET_8 and dn8>=MOMENTUM_BIAS_8:
        out.append((-1,'momentum',(-net8)*dn8))

    last=(s5[-1]-s5[-2])/point
    if net30>=TREND_NET_30 and up30>=TREND_BIAS_30 and net5<=-PULLBACK_RETRACE_5 and last>0:
        out.append((1,'pullback',net30*up30+abs(net5)))
    elif net30<=-TREND_NET_30 and dn30>=TREND_BIAS_30 and net5>=PULLBACK_RETRACE_5 and last<0:
        out.append((-1,'pullback',(-net30)*dn30+abs(net5)))

    sd=float(np.std(s50))
    if sd>0:
        z=(s50[-1]-float(np.mean(s50)))/sd
        if z>=REVERSION_Z and net4<=REVERSION_STALL_4:
            out.append((-1,'mean_reversion',abs(z)*10.0))
        elif z<=-REVERSION_Z and net4>=-REVERSION_STALL_4:
            out.append((1,'mean_reversion',abs(z)*10.0))
    return out


def simulate_trade(i,direction,times,bids,asks,point,horizon_ms,sl_pts,tp_pts,commission_pts):
    entry=asks[i] if direction>0 else bids[i]
    j_end=min(int(np.searchsorted(times,int(times[i])+horizon_ms,side='left')),len(times)-1)
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
    return float(gross)-commission_pts,int(times[exit_idx])


def reservoir_add(store,key,row,seen,cap,rng):
    seen[key]+=1
    n=seen[key]
    if len(store[key])<cap:
        store[key].append(row); return
    j=rng.randrange(n)
    if j<cap: store[key][j]=row


def build_dataset(ticks,point,horizon_ms,sl_pts,tp_pts,commission_pts,gap_ms,cap_train,cap_val,cap_hold):
    times=ticks['time_msc'].astype(np.int64)
    bids=ticks['bid'].astype(float); asks=ticks['ask'].astype(float)
    good=(bids>0)&(asks>0)&(asks>=bids)
    times,bids,asks=times[good],bids[good],asks[good]
    start=int(times[0]); end=int(times[-1]); span=max(end-start,1)
    t70=start+int(span*0.70); t85=start+int(span*0.85)
    print('Strict time cuts:')
    print(' train <',datetime.fromtimestamp(t70/1000,timezone.utc))
    print(' validation <',datetime.fromtimestamp(t85/1000,timezone.utc))
    print(' holdout >=',datetime.fromtimestamp(t85/1000,timezone.utc))

    store=defaultdict(list); seen=defaultdict(int)
    last_time={m:-10**18 for m in MODES}
    rng=random.Random(20260908)

    for i in range(50,len(times)-1):
        if i and i%500000==0:
            print(f'Scan {100*i/len(times):.1f}% | raw counts:',{k:seen[k] for k in sorted(seen)})
        cands=all_candidates(bids[i-49:i+1],point)
        if not cands: continue
        t=int(times[i])
        split='train' if t<t70 else ('val' if t<t85 else 'hold')
        cap=cap_train if split=='train' else (cap_val if split=='val' else cap_hold)
        feat=None
        for direction,mode,score in cands:
            if t-last_time[mode]<gap_ms: continue
            if feat is None:
                feat=make_features(bids[i-49:i+1],asks[i-49:i+1],times[i-49:i+1],point)
                if feat is None: break
            net,exit_t=simulate_trade(i,direction,times,bids,asks,point,horizon_ms,sl_pts,tp_pts,commission_pts)
            x=np.concatenate([feat,np.asarray([float(direction),float(score)],dtype=np.float64)])
            row=(t,exit_t,mode,direction,score,x,net,1 if net>0 else 0)
            key=(split,mode)
            reservoir_add(store,key,row,seen,cap,rng)
            last_time[mode]=t

    print('\nRAW candidate counts across FULL PERIOD')
    for split in ('train','val','hold'):
        for mode in MODES:
            print(f'{split:5s} {mode:14s}: raw={seen[(split,mode)]:,} sampled={len(store[(split,mode)]):,}')
    return store,t70,t85


def one_position_stats(rows,probs,threshold):
    pairs=sorted([(r,p) for r,p in zip(rows,probs) if p>=threshold],key=lambda z:z[0][0])
    free_at=-1; pnls=[]
    for r,p in pairs:
        if r[0]<free_at: continue
        pnls.append(float(r[6])); free_at=int(r[1])
    if not pnls: return None
    a=np.asarray(pnls,float)
    return {'trades':len(a),'win_rate':float(np.mean(a>0)),'avg':float(np.mean(a)),'total':float(np.sum(a)),'median':float(np.median(a))}


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--days',type=int,default=30)
    ap.add_argument('--candidate-gap-ms',type=int,default=1200)
    ap.add_argument('--horizon-sec',type=int,default=12)
    ap.add_argument('--sl-points',type=float,default=100.0)
    ap.add_argument('--tp-points',type=float,default=130.0)
    ap.add_argument('--commission-points',type=float,default=7.0)
    ap.add_argument('--train-cap',type=int,default=50000)
    ap.add_argument('--val-cap',type=int,default=20000)
    ap.add_argument('--hold-cap',type=int,default=30000)
    args=ap.parse_args()

    if not mt5.initialize(): raise RuntimeError(f'MT5 initialize failed: {mt5.last_error()}')
    try:
        sym=mt5.symbol_info(SYMBOL)
        if sym is None: raise RuntimeError(f'{SYMBOL} unavailable')
        ticks=fetch_ticks(args.days)
        store,t70,t85=build_dataset(ticks,sym.point,args.horizon_sec*1000,args.sl_points,args.tp_points,
                    args.commission_points,args.candidate_gap_ms,args.train_cap,args.val_cap,args.hold_cap)

        bundle={'symbol':SYMBOL,'point':sym.point,'feature_names':FEATURE_NAMES+['signal_direction','signal_score'],
                'horizon_sec':args.horizon_sec,'sl_points':args.sl_points,'tp_points':args.tp_points,
                'commission_points':args.commission_points,'models':{},'thresholds':{},
                'trained_at':datetime.now().isoformat(),'days':args.days}
        thresholds=[0.50,0.55,0.60,0.65,0.70,0.75,0.80,0.85]

        for mode in MODES:
            tr=sorted(store[('train',mode)],key=lambda r:r[0]); va=sorted(store[('val',mode)],key=lambda r:r[0]); te=sorted(store[('hold',mode)],key=lambda r:r[0])
            print('\n'+'='*80); print(mode.upper(),f'train={len(tr)} val={len(va)} holdout={len(te)}')
            if len(tr)<1500 or len(te)<300:
                print('SKIP: insufficient sampled coverage.'); continue
            Xtr=np.vstack([r[5] for r in tr]); ytr=np.asarray([r[7] for r in tr],int)
            Xva=np.vstack([r[5] for r in va]); yva=np.asarray([r[7] for r in va],int) if va else np.empty(0,int)
            Xte=np.vstack([r[5] for r in te]); yte=np.asarray([r[7] for r in te],int)
            counts=np.bincount(ytr,minlength=2).astype(float)
            if np.any(counts==0):
                print('SKIP: one training class only.'); continue
            sw=(len(ytr)/(2.0*counts))[ytr]
            model=HistGradientBoostingClassifier(max_iter=240,learning_rate=0.045,max_leaf_nodes=31,l2_regularization=3.0,random_state=41)
            model.fit(Xtr,ytr,sample_weight=sw)

            for name,Xs,ys in [('VALIDATION',Xva,yva),('HOLDOUT',Xte,yte)]:
                if len(ys)==0: continue
                pred=model.predict(Xs)
                print(name,'balanced_accuracy=',round(balanced_accuracy_score(ys,pred),4))
                print(confusion_matrix(ys,pred))
                print(classification_report(ys,pred,target_names=['LOSS/NONPOS','PROFIT'],digits=3,zero_division=0))

            pte=model.predict_proba(Xte)[:,list(model.classes_).index(1)]
            baseline=one_position_stats(te,np.ones(len(te)),0.0)
            if baseline:
                print(f'BASELINE sampled holdout: trades={baseline["trades"]} win={baseline["win_rate"]*100:.2f}% avg={baseline["avg"]:.2f} total={baseline["total"]:.2f}')
            print('threshold  trades  win%   avg_net_pts  total_net_pts  median_net_pts')
            positive=[]
            for th in thresholds:
                st=one_position_stats(te,pte,th)
                if st is None: continue
                print(f'{th:0.2f} {st["trades"]:7d} {st["win_rate"]*100:6.2f} {st["avg"]:12.2f} {st["total"]:13.2f} {st["median"]:14.2f}')
                if st['trades']>=50 and st['avg']>0 and st['total']>0: positive.append((th,st))
            if positive:
                rec=max(positive,key=lambda z:(z[1]['trades'],z[1]['avg']))
                print(f'RECOMMENDED HOLDOUT THRESHOLD {mode}: {rec[0]:.2f} | trades={rec[1]["trades"]} avg={rec[1]["avg"]:.2f} total={rec[1]["total"]:.2f}')
                bundle['thresholds'][mode]=rec[0]
            else:
                print(f'NO ROBUST POSITIVE HOLDOUT THRESHOLD for {mode}.')
            bundle['models'][mode]=model

        out=os.path.join(os.path.dirname(os.path.abspath(__file__)),MODEL_FILE)
        joblib.dump(bundle,out)
        print('\nMODEL BUNDLE SAVED:',out)
        print('V4 scanned the full period and used split/mode reservoir sampling. Review HOLDOUT tables before demo trading.')
    finally:
        mt5.shutdown()

if __name__=='__main__': main()
