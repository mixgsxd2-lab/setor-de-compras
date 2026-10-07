@echo off
chcp 65001 >nul
title Compras - Hospital Rio Grande
cd /d "%~dp0"

echo ============================================
echo   Compras - Hospital Rio Grande (demonstracao)
echo ============================================
echo.

where python >nul 2>nul
if errorlevel 1 (
  echo [ERRO] O Python nao foi encontrado.
  echo Instale o Python 3.12 ou mais novo em https://www.python.org/downloads/
  echo Na instalacao, marque a opcao "Add python.exe to PATH".
  echo.
  pause
  exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
  echo [1/3] Criando ambiente do programa ^(so na primeira vez^)...
  python -m venv .venv
  if errorlevel 1 ( echo [ERRO] Nao foi possivel criar o ambiente. & pause & exit /b 1 )
)

if not exist ".venv\instalado.ok" (
  echo [2/3] Instalando dependencias ^(so na primeira vez, pode levar alguns minutos^)...
  ".venv\Scripts\python.exe" -m pip install --quiet --upgrade pip
  ".venv\Scripts\python.exe" -m pip install -r backend\requirements-dev.txt
  if errorlevel 1 ( echo [ERRO] Falha ao instalar as dependencias. & pause & exit /b 1 )
  echo ok> ".venv\instalado.ok"
)

echo [3/3] Iniciando o sistema...
echo.
echo   Quando aparecer "Running on http://127.0.0.1:8000", o sistema esta no ar.
echo   Ele abre sozinho no navegador. Para encerrar, feche esta janela.
echo.
start "" /b cmd /c "timeout /t 12 /nobreak >nul & start http://127.0.0.1:8000"
cd backend
"..\.venv\Scripts\python.exe" dev.py
echo.
pause
