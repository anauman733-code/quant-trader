@echo off
cd /d "%~dp0"
"%LOCALAPPDATA%\Programs\Python\Python311\python.exe" -m pip install -q MetaTrader5 numpy scikit-learn joblib
"%LOCALAPPDATA%\Programs\Python\Python311\python.exe" train_signal_outcome_v3.py --days 21 --candidate-gap-ms 300 --horizon-sec 12 --sl-points 100 --tp-points 130 --commission-points 7 --max-candidates 180000
pause
