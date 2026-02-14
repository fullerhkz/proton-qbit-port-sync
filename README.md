# proton-qbit-port-sync

Sincroniza a porta encaminhada do Proton VPN com o qBittorrent no Windows. O script:
1. Le a porta encaminhada nos logs do Proton VPN
2. Atualiza `Session\Port` no `qBittorrent.ini`
3. Reinicia o qBittorrent para aplicar a nova porta

Este repositorio contem um unico script PowerShell: `proton-qbit-port-sync.ps1`.

## Requisitos

- Windows 10/11
- Proton VPN com Port Forwarding habilitado
- qBittorrent instalado
- PowerShell 5.1+ (ja incluso no Windows)

## Instalacao

1. Crie uma pasta para o script, por exemplo:
   - `C:\Scripts\proton-qbit-port-sync`
2. Coloque `proton-qbit-port-sync.ps1` dentro dessa pasta.
3. (Opcional) Crie o diretorio de logs (o script cria automaticamente):
   - `%ProgramData%\ProtonQbitPortSync`

## Uso

Execute manualmente para validar:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\proton-qbit-port-sync\proton-qbit-port-sync.ps1"
```

### Parametros opcionais

- `-ProtonVpnLogDir`
  Padrao: `%LOCALAPPDATA%\Proton\Proton VPN\Logs`
- `-QbitConfigPath`
  Padrao: `%APPDATA%\qBittorrent\qBittorrent.ini`
- `-QbitExePath`
  Padrao: auto-detect (Program Files, PATH, registry)
- `-LogPath`
  Padrao: `%ProgramData%\ProtonQbitPortSync\proton-qbit-port-sync.log`
- `-LogTailLines`
  Padrao: `2000`
- `-SkipRestartIfSame`
  Nao reinicia se a porta nao mudou
- `-WhatIf`
  Simulacao (nao escreve arquivo, nao reinicia)

Exemplo com caminhos explicitos:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\proton-qbit-port-sync\proton-qbit-port-sync.ps1" `
  -QbitExePath "C:\Program Files\qBittorrent\qbittorrent.exe" `
  -LogPath "C:\Logs\proton-qbit-port-sync.log"
```

## Agendador de Tarefas (Windows)

### Opcao A: importar o XML

1. Abra o Agendador de Tarefas.
2. No painel da direita, clique em **Importar Tarefa...**
3. Selecione `task-scheduler-example.xml` deste repositorio.
4. Edite a tarefa:
   - Aba **Acoes**: atualize o caminho do script em Arguments.
   - Aba **Geral**: defina seu usuario e marque **Executar com privilegios mais altos**.
5. Salve.

### Opcao B: criar manualmente

1. Abra o Agendador de Tarefas e clique em **Criar Tarefa...**
2. Aba **Geral**:
   - Nome: `Proton qBittorrent Port Sync`
   - Executar esteja o usuario conectado ou nao
   - Executar com privilegios mais altos
3. Aba **Disparadores**:
   - Novo... -> Iniciar a tarefa: **Ao fazer logon**
   - (Opcional) Atraso: **3 minutos**
4. Aba **Acoes**:
   - Novo... -> Acao: **Iniciar um programa**
   - Programa/script: `powershell.exe`
   - Adicionar argumentos:
     ```
     -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Scripts\proton-qbit-port-sync\proton-qbit-port-sync.ps1"
     ```
5. Aba **Configuracoes**:
   - Permitir que a tarefa seja executada sob demanda
   - Interromper a tarefa se estiver em execucao por mais de 10 minutos

### Validar

Execute a tarefa manualmente uma vez e confira o log:

```
%ProgramData%\ProtonQbitPortSync\proton-qbit-port-sync.log
```

## Solucao de problemas

- **Nao encontrou linha 'Port pair'**
  - Verifique se o Proton VPN esta conectado com Port Forwarding habilitado.
  - Confira `%LOCALAPPDATA%\Proton\Proton VPN\Logs`.
- **qBittorrent nao reinicia**
  - Passe `-QbitExePath` explicitamente.
- **Configuracao nao atualizada**
  - Verifique se `%APPDATA%\qBittorrent\qBittorrent.ini` existe e se ha permissao.

## Placeholders

Substitua os caminhos abaixo pelos seus valores reais:

- `C:\Scripts\proton-qbit-port-sync\proton-qbit-port-sync.ps1`
- `%LOCALAPPDATA%` / `%APPDATA%` / `%ProgramData%`
