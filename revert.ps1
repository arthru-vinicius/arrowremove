#Requires -Version 5.0
<#
  arrowremove /revert -- devolve a seta de atalho padrao do Windows.

      Reverter: irm https://arrowremove.arthru.com/revert | iex
      Aplicar:  irm https://arrowremove.arthru.com | iex

  O QUE VOCE LE AQUI E O QUE EXECUTA. Este arquivo e servido byte a byte em
  https://arrowremove.arthru.com/revert.

  Ele APAGA o valor em vez de escrever a seta de volta. A seta padrao nao vem
  de uma entrada em 'Shell Icons' -- ela e o comportamento do Windows quando
  nao ha entrada nenhuma. Escrever qualquer coisa ali, mesmo tentando imitar o
  original, deixaria a maquina fora do estado de fabrica.

  Autocontido e sem acento pelos mesmos motivos do install.ps1 -- ver o
  cabecalho de la.
#>

$ErrorActionPreference = 'Stop'

$SelfUrl = 'https://arrowremove.arthru.com/revert'

$OverlayIndex = '29'

$ShellIconsKeys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons'
)

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Reset-IconCache {
    # A ORDEM IMPORTA. Com o explorer no ar os arquivos de cache ficam
    # bloqueados e o Remove-Item falha calado -- por isso apagamos
    # imediatamente depois de derrubar o shell, sem espera no meio.
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

    Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" `
        -Filter 'iconcache*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue

    # 'thumbcache*' fica de fora: sao as miniaturas de foto e video, e regerar
    # aquilo numa pasta grande custa minutos de disco.

    # O Winlogon reabre o shell sozinho (AutoRestartShell=1, padrao do
    # Windows). So forcamos se ele nao voltar: um explorer aberto DAQUI
    # herdaria o token elevado deste processo.
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Precisa de administrador (a chave fica em HKLM) -- reabrindo elevado...' -ForegroundColor Yellow

    # Processo novo nao herda a configuracao de TLS deste aqui. 3072 e Tls12;
    # o -bor preserva o que ja estiver habilitado.
    $inner = '[Net.ServicePointManager]::SecurityProtocol = ' +
             '[Net.ServicePointManager]::SecurityProtocol -bor 3072; ' +
             "irm $SelfUrl | iex; Start-Sleep -Seconds 5"

    try {
        Start-Process powershell -Verb RunAs -Wait `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`""
    } catch {
        Write-Host 'Elevacao recusada -- nada foi alterado.' -ForegroundColor Red
    }
} else {
    foreach ($key in $ShellIconsKeys) {
        if (Test-Path $key) {
            # SilentlyContinue cobre a chave que existe sem o valor 29 dentro,
            # que e o estado de quem nunca rodou o install. Rodar o revert
            # nessa maquina nao e erro, e um no-op.
            Remove-ItemProperty -Path $key -Name $OverlayIndex `
                -ErrorAction SilentlyContinue
        }
    }

    Reset-IconCache

    Write-Host 'Pronto: seta padrao restaurada.' -ForegroundColor Green
}
