@echo off
cd /d "%~dp0"
"%LOCALAPPDATA%\Programs\Python\Python311\python.exe" -m pip install -q MetaTrader5 numpy scikit-learn joblib
"%LOCALAPPDATA%\Programs\Python\Python311\python.exe" train_60s_forecast.py --days 14 --sample-ms 1000 --horizon-sec 60 --target-points 20 --max-samples 250000
pause
