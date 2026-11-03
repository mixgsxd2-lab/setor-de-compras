@echo off
chcp 65001 >nul
title Compras - Hospital Rio Grande
cd /d "%~dp0"

where python >nul 2>nul
if errorlevel 1 (
  echo Instale o Python 3.12+ em https://www.python.org/downloads/ e marque "Add python.exe to PATH".
  pause
  exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
  echo Preparando na primeira vez, aguarde...
  python -m venv .venv
  ".venv\Scripts\python.exe" -m pip install --quiet -r requirements.txt
)

echo Sistema em http://127.0.0.1:8000  -  para encerrar, feche esta janela.
start "" http://127.0.0.1:8000
".venv\Scripts\python.exe" app.py
pause
