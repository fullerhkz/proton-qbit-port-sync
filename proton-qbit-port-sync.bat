@echo off
setlocal

REM proton-qbit-port-sync.bat
REM Executa o script PowerShell no mesmo diretorio deste .bat.
REM Uso:
REM   - Duplo clique para rodar com os parametros padrao
REM   - Ou passe argumentos adicionais (serao encaminhados ao .ps1)
REM Exemplo:
REM   proton-qbit-port-sync.bat -SkipRestartIfSame

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%proton-qbit-port-sync.ps1"

if not exist "%PS1%" (
  echo ERRO: script nao encontrado em "%PS1%"
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
endlocal
