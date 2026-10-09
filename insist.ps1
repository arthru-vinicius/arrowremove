#Requires -Version 5.0
<#
  arrowremove /insist -- cria uma tarefa agendada que reaplica a correcao
  sozinha, a cada boot e a cada vez que a maquina conecta numa rede.

      Instalar: irm https://arrowremove.arthru.com/insist | iex
      Desfazer: irm https://arrowremove.arthru.com/revert | iex   (remove a
                tarefa e restaura a seta padrao, as duas coisas na mesma
                chamada)

  PARA QUE SERVE. O quadrado preto que voltava a cada boot NAO e o caso
  desta tarefa: era o icone de alfa 0 quebrando no cache de icones, e isso
  foi corrigido no proprio '/' (v1.2.0) -- uma chamada unica la basta. Esta
  tarefa e para o que sobra: politica de grupo, utilitario do fabricante ou
  reimagem de driver que reescreve 'Shell Icons' ou apaga o icone. Nao ha
  como descobrir de fora quem faz isso; a tarefa nao tenta -- so confere e
  reaplica, no boot e ao conectar na rede. Ver docs/insist.md.

  SO MEXE NO EXPLORER SE PRECISOU MUDAR ALGO. Rodando como SYSTEM, o
  install.ps1 so apaga o cache e reinicia o Explorer quando o icone ou o
  HKLM estavam diferentes do esperado. Com o icone de alfa 1 isso e seguro:
  arquivo e registro corretos significam overlay invisivel, porque o cache
  nao tem mais como estraga-lo.

  O QUE VOCE LE AQUI E O QUE EXECUTA -- mesmo contrato do install.ps1 e do
  revert.ps1. Servido byte a byte em https://arrowremove.arthru.com/insist.

  A UNICA EXCECAO AO 'SEM OUTRA CHAMADA DE REDE' DO README ESTA AQUI, DE
  PROPOSITO. Este arquivo em si nao baixa nada alem de si mesmo -- mas a
  tarefa que ele cria vai chamar 'irm .../ | iex' de novo a cada disparo,
  para sempre. A alternativa seria colar a logica de correcao inteira
  dentro da definicao da tarefa, e ai uma correcao publicada depois nunca
  chegaria nas maquinas que ja tem a tarefa instalada. Exemplo real: a
  troca do icone de alfa 0 pelo de alfa 1 (v1.2.0) chegou sozinha, no boot
  seguinte, em toda maquina com esta tarefa. Buscar de novo a cada disparo mantem essas maquinas
  atualizadas; o preco e que elas passam a depender da rede para o proprio
  conserto, o que o script padrao evita de proposito. Quem roda '/insist'
  esta aceitando essa troca.

  SEM ACENTO E COM LF, pelos mesmos motivos do install.ps1 -- ver o
  cabecalho de la. A CI reprova o commit que introduzir um byte acima de
  127 ou um CR.
#>

$ErrorActionPreference = 'Stop'

$SelfUrl = 'https://arrowremove.arthru.com/insist'
$ApplyUrl = 'https://arrowremove.arthru.com'

$TaskName = 'ArrowRemove-Insist'

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-InsistTask {
    # Dois disparos, nao um so. 'AtStartup' sozinho corre o risco de disparar
    # antes da rede subir -- nesse caso o 'irm' de dentro da tarefa falha e
    # ela so tenta de novo no proximo boot. O disparo de rede cobre esse
    # caso: 'Microsoft-Windows-NetworkProfile/Operational', evento 10000, e o
    # log que o Windows escreve toda vez que identifica uma rede nova --
    # cabo, Wi-Fi ou VPN. Com os dois juntos a maquina acaba conseguindo
    # rodar a correcao com rede disponivel sem precisar de atraso arbitrario
    # no gatilho de boot.
    $atBoot = New-ScheduledTaskTrigger -AtStartup

    $eventClass = Get-CimClass -ClassName MSFT_TaskEventTrigger `
        -Namespace Root/Microsoft/Windows/TaskScheduler
    $atNetwork = New-CimInstance -CimClass $eventClass -ClientOnly -Property @{
        Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'
        Enabled      = $true
    }

    # SYSTEM, nao o usuario que rodou o /insist. O que a tarefa mantem e o
    # HKLM e o icone em Program Files -- valem para a maquina inteira, nao
    # para uma conta -- e o install.ps1 reconhece SYSTEM e cai no ramo que
    # so confere, sem tentar se elevar. Tambem funciona sem ninguem logado:
    # no boot, antes do logon, ate o cache de icones ele limpa sem derrubar
    # Explorer nenhum.
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest

    # TLS 1.2 explicito pelo mesmo motivo do 'irm' interno do install.ps1: um
    # powershell.exe novo, disparado pelo Task Scheduler, nao herda nada
    # deste processo, e em maquina mais antiga o handshake com a Cloudflare
    # falha sem isso.
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -WindowStyle Hidden -Command ' +
        '"[Net.ServicePointManager]::SecurityProtocol = ' +
        '[Net.ServicePointManager]::SecurityProtocol -bor 3072; ' +
        "irm $ApplyUrl | iex`""
    )

    # 'IgnoreNew' evita duas execucoes emendadas se os dois gatilhos
    # dispararem quase juntos (comum: a rede sobe poucos segundos depois do
    # boot). Cinco minutos de limite de execucao e generoso de sobra para um
    # script que normalmente termina em segundos, e evita uma copia travada
    # ocupando a tarefa para sempre.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger @($atBoot, $atNetwork) -Principal $principal `
        -Settings $settings -Force | Out-Null
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Precisa de administrador (a tarefa roda como SYSTEM) -- reabrindo elevado...' -ForegroundColor Yellow

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
    Install-InsistTask

    Write-Host 'Pronto: tarefa agendada criada.' -ForegroundColor Green
    Write-Host 'Ela confere a cada boot e troca de rede, e so mexe no Explorer se algo tiver mudado.' -ForegroundColor Green
    Write-Host "Detalhes da tarefa: https://github.com/arthru-vinicius/arrowremove/blob/main/docs/insist.md" -ForegroundColor DarkGray
    Write-Host "Para desfazer (remove a tarefa e restaura a seta): irm https://arrowremove.arthru.com/revert | iex" -ForegroundColor DarkGray
}
