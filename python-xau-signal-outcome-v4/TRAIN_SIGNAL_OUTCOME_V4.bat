@echo off
cd /d "%~dp0"
"%LOCALAPPDATA%\Programs\Python\Python311\python.exe" -m pip install -q MetaTrader5 numpy scikit-learn joblib
"%LOCALAPPDATA%\Programs\Python\Python311\python.exe" train_signal_outcome_v4.py --days 30 --candidate-gap-ms 1200 --horizon-sec 12 --sl-points 100 --tp-points 130 --commission-points 7 --train-cap 50000 --val-cap 20000 --hold-cap 30000
pause
