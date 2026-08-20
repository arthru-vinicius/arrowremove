#Requires -Version 5.0
<#
  arrowremove /insist -- cria uma tarefa agendada que reaplica a correcao
  sozinha, a cada boot e a cada vez que a maquina conecta numa rede.

      Instalar: irm https://arrowremove.arthru.com/insist | iex
      Desfazer: irm https://arrowremove.arthru.com/revert | iex   (remove a
                tarefa e restaura a seta padrao, as duas coisas na mesma
                chamada)

  PARA QUE SERVE. A maioria das maquinas fica boa com uma chamada unica em
  https://arrowremove.arthru.com/. Algumas nao: alguma politica de grupo,
  utilitario do fabricante ou reimagem de driver reescreve a chave 'Shell
  Icons' de novo depois do boot, e a seta (ou o quadrado preto) volta. Nao
  ha como descobrir de fora quem reescreve a chave; esta tarefa nao tenta --
  ela so reaplica a correcao com frequencia suficiente para ganhar a
  corrida. Ver docs/insist.md para os detalhes da tarefa criada.

  NEM TODO DISPARO REINICIA O EXPLORER. O install.ps1 so reinicia o Explorer
  quando o valor do registro esta diferente do esperado OU quando a checagem
  ao vivo do icone (SHGetFileInfo num atalho .lnk que ja existe no disco,
  ver install.ps1 e docs/insist.md) pega o icone renderizando preto de
  verdade. Ja aconteceu uma vez de o registro estar certo e o quadrado preto
  persistir por cache obsoleto (ver docs/insist.md) -- a checagem ao vivo
  existe exatamente para pegar esse caso sem precisar reiniciar o Explorer
  toda hora.

  O QUE VOCE LE AQUI E O QUE EXECUTA -- mesmo contrato do install.ps1 e do
  revert.ps1. Servido byte a byte em https://arrowremove.arthru.com/insist.

  A UNICA EXCECAO AO 'SEM OUTRA CHAMADA DE REDE' DO README ESTA AQUI, DE
  PROPOSITO. Este arquivo em si nao baixa nada alem de si mesmo -- mas a
  tarefa que ele cria vai chamar 'irm .../ | iex' de novo a cada disparo,
  para sempre. A alternativa seria colar a logica de correcao inteira
  dentro da definicao da tarefa, e ai uma correcao publicada depois (por
  exemplo se o indice do icone dentro do shell32.dll mudar numa build
  futura do Windows) nunca chegaria nas maquinas que ja tem a tarefa
  instalada. Buscar de novo a cada disparo mantem essas maquinas
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

    # SYSTEM, nao o usuario que rodou o /insist. A chave que a tarefa mantem
    # e HKLM -- vale para a maquina inteira, nao para uma conta -- e SYSTEM
    # ja e Administrator para o 'Test-IsAdmin' do script padrao, entao a
    # tarefa cai direto no ramo que aplica a correcao a cada disparo, sem
    # tentar se elevar de novo. Tambem funciona sem ninguem logado.
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
    Write-Host 'A correcao vai rodar sozinha a cada boot e a cada troca de rede.' -ForegroundColor Green
    Write-Host "Detalhes da tarefa: https://github.com/arthru-vinicius/arrowremove/blob/main/docs/insist.md" -ForegroundColor DarkGray
    Write-Host "Para desfazer (remove a tarefa e restaura a seta): irm https://arrowremove.arthru.com/revert | iex" -ForegroundColor DarkGray
}
