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

# Deteccao ao vivo do quadrado preto, sem depender do registro. A tecnica:
# pedir ao Shell (SHGetFileInfo, API publica, mesma familia do ExtractIconEx
# usado acima para validar o icone) o icone de um atalho .lnk que JA EXISTE no
# disco -- isso passa pelo mesmo cache que o Explorer usa pra desenhar a area
# de trabalho. Um atalho criado agora nao serve: ganharia uma entrada de cache
# nova e nao revelaria nada sobre o cache velho que esta quebrado.
#
# Verificado ao vivo numa maquina com o bug: todo atalho ja existente no disco
# veio com o icone inteiro preto opaco, enquanto o .exe alvo (sem overlay) e
# pastas comuns vieram limpos -- o problema e do overlay de atalho
# especificamente, nao da extracao em si. Ver docs/insist.md.
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace ArrowRemoveShell -Name Icone -MemberDefinition @'
    [StructLayout(LayoutKind.Sequential)]
    public struct SHFILEINFO {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
        public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SHGetFileInfo(string pszPath,
        uint dwFileAttributes, ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
'@

$SHGFI_ICON = 0x100
$SHGFI_LARGEICON = 0x0

function Test-IconeInteiramentePreto([string]$caminho) {
    $info = New-Object ArrowRemoveShell.Icone+SHFILEINFO
    $tamanho = [Runtime.InteropServices.Marshal]::SizeOf($info)
    $ok = [ArrowRemoveShell.Icone]::SHGetFileInfo($caminho, 0, [ref]$info,
        $tamanho, $SHGFI_ICON -bor $SHGFI_LARGEICON)
    if ($ok -eq [IntPtr]::Zero -or $info.hIcon -eq [IntPtr]::Zero) {
        return $null
    }
    try {
        $bmp = [Drawing.Icon]::FromHandle($info.hIcon).ToBitmap()
        $pretos = 0
        $total = $bmp.Width * $bmp.Height
        for ($y = 0; $y -lt $bmp.Height; $y++) {
            for ($x = 0; $x -lt $bmp.Width; $x++) {
                $p = $bmp.GetPixel($x, $y)
                if ($p.A -gt 200 -and $p.R -lt 30 -and $p.G -lt 30 -and $p.B -lt 30) {
                    $pretos++
                }
            }
        }
        $bmp.Dispose()
        return ($pretos / $total) -ge 0.9
    } finally {
        [ArrowRemoveShell.Icone]::DestroyIcon($info.hIcon) | Out-Null
    }
}

function Test-OverlayQuebrado {
    # Ate 3 atalhos existentes -- nunca um criado agora, ver comentario acima.
    # Sem nenhum atalho no disco pra testar, nao ha como checar ao vivo; o
    # registro continua sendo o unico sinal disponivel nesse caso raro.
    $candidatos = @(
        "$env:USERPROFILE\Desktop\*.lnk",
        "$env:PUBLIC\Desktop\*.lnk",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\*.lnk"
    ) | ForEach-Object { Get-ChildItem $_ -ErrorAction SilentlyContinue } |
        Select-Object -First 3

    if (-not $candidatos) {
        return $false
    }

    $resultados = $candidatos | ForEach-Object {
        Test-IconeInteiramentePreto $_.FullName
    } | Where-Object { $null -ne $_ }

    if (-not $resultados) {
        return $false
    }

    $quebrados = ($resultados | Where-Object { $_ }).Count
    return $quebrados -ge [Math]::Ceiling($resultados.Count / 2.0)
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
    # So reaplicamos de verdade (com o reinicio do Explorer que isso implica)
    # quando o registro esta diferente do esperado OU quando a checagem ao
    # vivo (Test-OverlayQuebrado, acima) pega um atalho ja existente
    # renderizando com o icone inteiro preto. A primeira versao desse
    # comportamento condicional (v1.1.1) so olhava o registro e regrediu:
    # o quadrado preto voltava por cache de icone obsoleto SEM o registro
    # mudar, e a checagem dizia "nada a fazer" as cegas. A checagem ao vivo
    # existe exatamente pra fechar esse buraco sem voltar a reiniciar o
    # Explorer sempre (v1.1.2) nem aceitar o risco as cegas (v1.1.3). Ver
    # docs/insist.md para o historico completo e os limites do que a
    # checagem ao vivo cobre.
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

    $motivoOverlay = $false
    if (-not $precisaCorrigir -and (Test-OverlayQuebrado)) {
        $precisaCorrigir = $true
        $motivoOverlay = $true
    }

    if ($precisaCorrigir) {
        Reset-IconCache
        if ($motivoOverlay) {
            Write-Host 'Pronto: o registro ja estava certo, mas o icone de atalho estava preto -- cache de icone resetado.' -ForegroundColor Green
        } else {
            Write-Host 'Pronto: setinhas removidas.' -ForegroundColor Green
        }
    } else {
        Write-Host 'Registro ja estava correto e o icone de atalho renderiza certo -- nada para fazer, Explorer nao foi reiniciado.' -ForegroundColor Green
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
