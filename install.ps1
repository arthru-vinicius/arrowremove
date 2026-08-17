#Requires -Version 5.0
<#
  arrowremove -- tira a seta de atalho dos icones do Windows.

      Aplicar:  irm https://arrowremove.arthru.com | iex
      Reverter: irm https://arrowremove.arthru.com/revert | iex
      Insistir: irm https://arrowremove.arthru.com/insist | iex

  O QUE VOCE LE AQUI E O QUE EXECUTA. Este arquivo e servido byte a byte em
  https://arrowremove.arthru.com -- nao ha template, nao ha geracao, nao ha
  etapa intermediaria entre o que esta no GitHub e o que o 'irm' baixa.

  AUTOCONTIDO POR DECISAO, NAO POR FALTA DE IDEIA. Ele nao baixa mais nada
  alem de si mesmo e nao faz nenhuma outra chamada de rede. Quem roda
  'irm | iex' esta executando codigo de um servidor sem tela de login na
  frente -- a unica defesa que sobra e o arquivo ser curto o bastante para
  ser lido inteiro antes. Manter assim e requisito, nao estilo.

  SEM ACENTO, TAMBEM POR DECISAO. O corpo vai como 'text/plain; charset=utf-8'
  e o PowerShell 5.1 decodifica pelo charset anunciado no cabecalho HTTP. O
  nginx anuncia certo (ver site.conf), mas se algum intermediario raspar esse
  cabecalho o PS assume ISO-8859-1 -- e ai os bytes chegam trocados no meio de
  um script que roda elevado. Em ASCII isso nao tem como acontecer. A CI
  reprova o commit que introduzir um byte acima de 127.
#>

$ErrorActionPreference = 'Stop'

$SelfUrl = 'https://arrowremove.arthru.com'

# Recurso JA EMBUTIDO no shell32.dll do proprio Windows: o indice -50 e um
# icone inteiramente transparente. Conferido programaticamente com
# ExtractIconEx -- 0 de 1024 pixels opacos.
#
# NAO troque por um caminho de .ico proprio. Foi a primeira tentativa e ela
# falha tarde: o icone e aceito, a seta some, e depois de alguns reboots o
# Windows 11 passa a desenhar um QUADRADO PRETO no lugar dela. Reproduzido
# tanto com mascara classica AND/XOR quanto com PNG multi-resolucao com canal
# alfa, e relatado por outras pessoas com a mesma tecnica -- nao e um .ico mal
# formado nem uma maquina especifica. Ver o README.
$IconValue = '%SystemRoot%\System32\shell32.dll,-50'

# 29 e o indice da sobreposicao de atalho na tabela 'Shell Icons'.
$OverlayIndex = '29'

# Os dois lugares, de proposito. O HKLM e o que vale para a maquina inteira e
# e por ele que este script precisa de administrador. O HKCU cobre o caso de
# um perfil ja ter a chave definida, porque ali ela tem precedencia.
#
# Detalhe do HKCU sob elevacao: se voce responder ao UAC com a senha de OUTRA
# conta de administrador, o HKCU do processo elevado sera o daquela conta, nao
# o seu. O efeito continua valendo pelo HKLM.
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

    # 'thumbcache*' fica de fora. Sao as miniaturas de foto e video, nao tem
    # relacao nenhuma com a seta, e regerar aquilo numa pasta grande custa
    # minutos de disco.

    # O Winlogon reabre o shell sozinho (AutoRestartShell=1, padrao do
    # Windows). So forcamos se ele nao voltar, e de proposito: um explorer
    # aberto DAQUI herdaria o token elevado deste processo, e todo programa
    # aberto por ele depois subiria elevado junto.
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Precisa de administrador (a chave fica em HKLM) -- reabrindo elevado...' -ForegroundColor Yellow

    # O processo elevado e novo, entao nao herda nada daqui: o TLS 1.2 precisa
    # ser religado la dentro, senao em maquina mais antiga o 'irm' do filho
    # falha no handshake com a Cloudflare. O 3072 e o valor de Tls12, e o -bor
    # preserva o que ja estiver habilitado (inclusive TLS 1.3, onde existir).
    $inner = '[Net.ServicePointManager]::SecurityProtocol = ' +
             '[Net.ServicePointManager]::SecurityProtocol -bor 3072; ' +
             "irm $SelfUrl | iex; Start-Sleep -Seconds 5"

    try {
        # O -Wait segura esta janela ate a outra terminar, e o Start-Sleep la
        # dentro da tempo de ler o resultado antes de a janela elevada fechar.
        Start-Process powershell -Verb RunAs -Wait `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`""
    } catch {
        Write-Host 'Elevacao recusada -- nada foi alterado.' -ForegroundColor Red
    }
} else {
    # Comparado ANTES de escrever, para decidir se vale a pena derrubar o
    # Explorer. Sem isso, rodar o script de novo com a chave ja correta
    # (o /insist faz isso a cada boot e a cada troca de rede) reiniciaria o
    # Explorer sempre, mesmo quando ninguem reescreveu nada -- e e exatamente
    # esse incomodo que o /insist existe para evitar causar.
    $precisaCorrigir = $false
    foreach ($key in $ShellIconsKeys) {
        $atual = (Get-ItemProperty -Path $key -Name $OverlayIndex `
            -ErrorAction SilentlyContinue).$OverlayIndex
        if ($atual -ne $IconValue) {
            $precisaCorrigir = $true
        }

        if (-not (Test-Path $key)) {
            New-Item -Path $key -Force | Out-Null
        }
        # -Force sobrescreve o valor se ele ja existir, o que torna rodar de
        # novo inofensivo.
        New-ItemProperty -Path $key -Name $OverlayIndex -Value $IconValue `
            -PropertyType String -Force | Out-Null
    }

    if ($precisaCorrigir) {
        Reset-IconCache
        Write-Host 'Pronto: setinhas removidas.' -ForegroundColor Green
    } else {
        Write-Host 'Ja estava aplicado -- nada para fazer, Explorer nao foi reiniciado.' -ForegroundColor Green
    }

    # Tela de ajuda curta com os outros dois comandos. Fica so aqui, no
    # aplicar -- e o comando padrao, entao e onde a maioria das pessoas vai
    # ler pela primeira vez que os outros dois existem.
    Write-Host ''
    Write-Host 'Outros comandos:' -ForegroundColor DarkGray
    Write-Host "  irm $SelfUrl/revert | iex" -ForegroundColor DarkGray
    Write-Host '    reverte: restaura a seta padrao do Windows.' -ForegroundColor DarkGray
    Write-Host "  irm $SelfUrl/insist | iex" -ForegroundColor DarkGray
    Write-Host '    para maquinas que voltam a mostrar o quadrado preto a' -ForegroundColor DarkGray
    Write-Host '    cada boot: cria uma tarefa agendada que reaplica esta' -ForegroundColor DarkGray
    Write-Host '    correcao sozinha, no boot e ao conectar na rede.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Detalhes: https://github.com/arthru-vinicius/arrowremove#maquinas-que-insistem-insist' -ForegroundColor DarkGray
}
