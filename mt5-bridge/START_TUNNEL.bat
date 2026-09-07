@echo off
cd /d %~dp0
if not exist cloudflared.exe (
  powershell -NoProfile -Command "Invoke-WebRequest -Uri https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe -OutFile cloudflared.exe"
)
cloudflared.exe tunnel --url http://127.0.0.1:8765
pause
