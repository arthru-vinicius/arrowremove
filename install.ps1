#Requires -Version 5.0
<#
  arrowremove -- tira a seta de atalho dos icones do Windows.

      Aplicar:  irm https://arrowremove.arthru.com | iex
      Reverter: irm https://arrowremove.arthru.com/revert | iex
      Insistir: irm https://arrowremove.arthru.com/insist | iex

  O QUE VOCE LE AQUI E O QUE EXECUTA. Este arquivo e servido byte a byte em
  https://arrowremove.arthru.com -- nao ha template, nao ha geracao, nao ha
  etapa intermediaria entre o que esta no GitHub e o que o 'irm' baixa.

  O QUE ELE FAZ: gera um icone praticamente transparente em
  %ProgramFiles%\arrowremove\sem-seta.ico, aponta 'Shell Icons\29' para ele,
  apaga o cache de icones e deixa o Explorer voltar. O porque de gerar um
  icone em vez de usar um do Windows esta logo abaixo, em $IconDir.

  AUTOCONTIDO POR DECISAO, NAO POR FALTA DE IDEIA. Ele nao baixa mais nada
  alem de si mesmo e nao faz nenhuma outra chamada de rede -- o icone e
  montado byte a byte aqui, sem arquivo binario embutido. Quem roda
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

# O ICONE QUE SUBSTITUI A SETA E GERADO AQUI MESMO, e nao vem de DLL nenhuma.
# Todo icone "totalmente transparente" -- alfa 0 em todo pixel, seja um .ico
# proprio, seja o shell32.dll,-50 que este script usou ate a v1.1.3 -- vira
# um QUADRADO PRETO na primeira vez que o Explorer o recarrega do cache de
# icones: na volta, o cache entrega mascara opaca e alfa zerado, o Windows
# conclui "imagem sem canal alfa" e pinta a cor crua, que e preta. Recarga
# do cache acontece a cada boot, a cada reinicio do Explorer e depois de
# qualquer instalacao que mexa no shell. Medido e reproduzido -- ver o README.
#
# A saida e alfa 1 (de 255) em todo pixel: 0,4% de opacidade, invisivel a
# olho (medido: no maximo 2/255 de diferenca no desenho), mas o canal alfa
# sobrevive ao cache e o Windows passa a misturar pelo alfa em vez de pintar
# a mascara. NAO troque por um icone de alfa 0, de lugar nenhum.
$IconDir = Join-Path $env:ProgramFiles 'arrowremove'
$IconPath = Join-Path $IconDir 'sem-seta.ico'
$IconValue = "$IconPath,0"

# 29 e o indice da sobreposicao de atalho na tabela 'Shell Icons'.
$OverlayIndex = '29'

# O HKLM e o que o Explorer usa: medido com os dois definidos e diferentes,
# vale o do HKLM. O HKCU recebe o mesmo valor so para nao sobrar ali um valor
# antigo (de versao anterior ou de outra receita) apontando para outro icone.
$ShellIconsKeys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons'
)

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsSystem {
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
}

function New-OverlayIconBytes {
    # Um .ico com um BMP de 32 bits por tamanho. Tamanhos explicitos para o
    # Windows nao precisar redimensionar; e alfa 1 em TODOS os pixels, e nao
    # num pixel so, para que nenhum redimensionamento (DPI fora do padrao)
    # consiga zerar o alfa de novo. Mascara AND toda transparente (bit 1).
    $sizes = 16, 20, 24, 32, 40, 48, 64, 96, 128, 256
    $images = foreach ($s in $sizes) {
        $pixels = [byte[]]::new($s * $s * 4)
        for ($i = 3; $i -lt $pixels.Length; $i += 4) { $pixels[$i] = 1 }
        $mask = [byte[]]::new([int]([math]::Ceiling($s / 32) * 4) * $s)
        for ($i = 0; $i -lt $mask.Length; $i++) { $mask[$i] = 0xFF }

        $ms = New-Object IO.MemoryStream
        $bw = New-Object IO.BinaryWriter $ms
        # BITMAPINFOHEADER: altura dobrada porque cor e mascara vem empilhadas.
        $bw.Write([int]40); $bw.Write([int]$s); $bw.Write([int]($s * 2))
        $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]0)
        $bw.Write([int]($pixels.Length + $mask.Length))
        $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
        $bw.Write($pixels); $bw.Write($mask); $bw.Flush()
        , $ms.ToArray()
    }

    $out = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $out
    $w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        # No diretorio do .ico, 256 se escreve 0 -- o campo tem um byte so.
        $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([int16]1); $w.Write([int16]32)
        $w.Write([int]$images[$i].Length); $w.Write([int]$offset)
        $offset += $images[$i].Length
    }
    foreach ($img in $images) { $w.Write($img) }
    $w.Flush()
    $out.ToArray()
}

function Install-OverlayIcon {
    # Devolve $true se precisou escrever. Em Program Files, e nao em pasta de
    # usuario, porque quem nao e administrador nao deve poder trocar o icone
    # que o HKLM aponta para a maquina inteira.
    $novo = New-OverlayIconBytes
    if (Test-Path $IconPath) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $hashAtual = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($IconPath)))
        if ($hashAtual -eq [BitConverter]::ToString($sha.ComputeHash($novo))) {
            return $false
        }
    }
    New-Item -ItemType Directory -Path $IconDir -Force | Out-Null
    [IO.File]::WriteAllBytes($IconPath, $novo)
    return $true
}

function Set-OverlayValue {
    # Devolve $true se o HKLM estava diferente. So o HKLM conta para a decisao
    # porque e so ele que muda o que o Explorer desenha.
    $mudou = $false
    foreach ($key in $ShellIconsKeys) {
        $atual = (Get-ItemProperty -Path $key -Name $OverlayIndex `
            -ErrorAction SilentlyContinue).$OverlayIndex
        if ($atual -ne $IconValue -and $key -like 'HKLM:*') {
            $mudou = $true
        }
        if (-not (Test-Path $key)) {
            New-Item -Path $key -Force | Out-Null
        }
        New-ItemProperty -Path $key -Name $OverlayIndex -Value $IconValue `
            -PropertyType String -Force | Out-Null
    }
    return $mudou
}

function Reset-IconCache {
    # A ORDEM IMPORTA. Com o explorer no ar os arquivos de cache ficam
    # bloqueados e o Remove-Item falha calado -- por isso apagamos
    # imediatamente depois de derrubar o shell, sem espera no meio.
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

    # O cache e por usuario, e o overlay vem do HKLM, que vale para todos:
    # apaga o de todo perfil local, nao so o deste processo. Isso tambem cobre
    # a tarefa do /insist, que roda como SYSTEM, e quem respondeu ao UAC com
    # OUTRA conta de administrador -- nos dois casos o $env:LOCALAPPDATA daqui
    # nao e o de quem esta na frente da tela.
    $locais = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
        Where-Object { $_.PSChildName -like 'S-1-5-21-*' } |
        ForEach-Object { Join-Path $_.GetValue('ProfileImagePath') 'AppData\Local' })
    foreach ($local in ($locais + $env:LOCALAPPDATA | Select-Object -Unique)) {
        Get-ChildItem "$local\Microsoft\Windows\Explorer" -Filter 'iconcache*' `
            -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item "$local\IconCache.db" -Force -ErrorAction SilentlyContinue
    }

    # 'thumbcache*' fica de fora. Sao as miniaturas de foto e video, nao tem
    # relacao nenhuma com a seta, e regerar aquilo numa pasta grande custa
    # minutos de disco.

    # O Winlogon reabre o shell sozinho (AutoRestartShell=1, padrao do
    # Windows). So forcamos se ele nao voltar, e de proposito: um explorer
    # aberto DAQUI herdaria o token elevado deste processo, e todo programa
    # aberto por ele depois subiria elevado junto. Como SYSTEM, nunca: no boot
    # ainda nao ha shell de ninguem, e um explorer como SYSTEM seria pior.
    Start-Sleep -Seconds 3
    if (-not (Test-IsSystem) -and -not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
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
} elseif (Test-IsSystem) {
    # Chamado pela tarefa do /insist, a cada boot e troca de rede. Aqui, e so
    # aqui, "nada mudou" basta para nao mexer no Explorer: com o icone de alfa
    # 1, arquivo e HKLM corretos significam overlay invisivel, porque o cache
    # nao tem mais como estraga-lo. Com o icone de alfa 0 (ate a v1.1.3) isso
    # nao era verdade, e essa mesma checagem ja causou regressao uma vez.
    $mudouIcone = Install-OverlayIcon
    $mudouRegistro = Set-OverlayValue
    if ($mudouIcone -or $mudouRegistro) {
        Reset-IconCache
    }
} else {
    Install-OverlayIcon | Out-Null
    Set-OverlayValue | Out-Null

    # Chamado por uma pessoa: sempre reinicia. Quem roda na mao quer ver o
    # efeito agora, e e o reset que tira do cache um quadrado preto gravado
    # por uma versao anterior deste script ou por outra receita.
    Reset-IconCache

    Write-Host 'Pronto: setinhas removidas.' -ForegroundColor Green

    # Tela de ajuda curta com os outros dois comandos. Fica so aqui, no
    # aplicar -- e o comando padrao, entao e onde a maioria das pessoas vai
    # ler pela primeira vez que os outros dois existem.
    Write-Host ''
    Write-Host 'Outros comandos:' -ForegroundColor DarkGray
    Write-Host "  irm $SelfUrl/revert | iex" -ForegroundColor DarkGray
    Write-Host '    reverte: restaura a seta padrao do Windows.' -ForegroundColor DarkGray
    Write-Host "  irm $SelfUrl/insist | iex" -ForegroundColor DarkGray
    Write-Host '    para maquinas em que algo desfaz a correcao: cria uma' -ForegroundColor DarkGray
    Write-Host '    tarefa que confere no boot e ao conectar na rede, e so' -ForegroundColor DarkGray
    Write-Host '    reaplica (e reinicia o Explorer) se algo tiver mudado.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Detalhes: https://github.com/arthru-vinicius/arrowremove#maquinas-que-insistem-insist' -ForegroundColor DarkGray
}
