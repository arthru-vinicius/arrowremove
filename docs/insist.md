# `/insist` -- para máquinas que voltam ao quadrado preto sozinhas

```powershell
irm https://arrowremove.arthru.com/insist | iex   # instala
irm https://arrowremove.arthru.com/revert | iex   # desinstala (e reverte a seta)
```

Este documento é a referência completa do que o `/insist` cria na máquina.
Para o resumo de uma tela, veja a saída do próprio `irm | iex` ou a seção
["Máquinas que insistem"](../README.md#maquinas-que-insistem-insist) do
README.

## O problema que isso resolve

O `/` (aplicar) resolve a maioria das máquinas de forma permanente -- é o que
a seção "O achado que motivou tudo" do README documenta. Só que em algumas
máquinas a seta (ou o quadrado preto) **volta sozinha depois de um boot**,
mesmo com a correção já aplicada uma vez. A causa varia por máquina --
política de grupo de domínio, utilitário do fabricante, reimagem de driver de
vídeo -- e não dá para descobrir de fora qual é o agente que reescreve a
chave `Shell Icons`.

O `/insist` não tenta identificar a causa. Ele aceita que alguma coisa vai
desfazer a correção de tempos em tempos, e cria uma tarefa agendada que
reaplica o `/` (a chamada padrão) sozinha, com frequência suficiente para
ganhar a corrida contra o que estiver desfazendo.

## O que a tarefa criada faz, exatamente

Nome: **`ArrowRemove-Insist`**, visível na raiz da Biblioteca do Agendador de
Tarefas (não numa subpasta).

| Campo | Valor | Por quê |
|---|---|---|
| Ação | `powershell.exe -NoProfile -WindowStyle Hidden -Command "... irm https://arrowremove.arthru.com \| iex"` | Chama de novo o `/` (aplicar), não uma cópia colada da lógica. Uma correção publicada depois de instalado o `/insist` chega automaticamente no próximo disparo. |
| Gatilho 1 | No boot (`AtStartup`) | Cobre o caso comum. |
| Gatilho 2 | Evento 10000 do log `Microsoft-Windows-NetworkProfile/Operational` | Disparado pelo Windows toda vez que identifica uma rede (cabo, Wi-Fi ou VPN). Cobre o caso em que o boot dispara a ação antes da rede subir -- a tentativa do boot falha (sem rede, o `irm` não completa), e este segundo gatilho tenta de novo assim que há rede. |
| Executar como | `NT AUTHORITY\SYSTEM`, nível mais alto | A chave que a tarefa mantém é `HKLM` -- vale para a máquina inteira, não para uma conta. SYSTEM já conta como Administrator para o `Test-IsAdmin` do `install.ps1`, então cada disparo aplica a correção direto, sem passar pela dança de elevação (UAC) a cada boot. Funciona também sem ninguém logado. |
| Múltiplas instâncias | `IgnoreNew` | Se os dois gatilhos dispararem quase juntos (boot e rede em sequência rápida, comum em SSD), a segunda execução é descartada em vez de rodar em paralelo. |
| Limite de execução | 5 minutos | O script normalmente termina em segundos; o limite existe só para não deixar uma cópia travada seguindo dona da tarefa para sempre. |

## Nem todo disparo reinicia o Explorer -- e essa é uma troca aceita, não uma garantia

A tarefa dispara com frequência -- todo boot, toda troca de rede -- mas o
`install.ps1` (a ação que ela chama) só reinicia o Explorer **quando o valor
do registro está diferente do esperado**. Se já está correto, o script sai
sem tocar no cache de ícones nem no Explorer.

Essa checagem já causou uma regressão uma vez (`v1.1.1`): em pelo menos uma
máquina, o quadrado preto voltou por **cache de ícone obsoleto**, não por
registro reescrito. Com o registro já correto, a checagem dizia "nada a
fazer" e pulava a única coisa que de fato resolve, que é derrubar o Explorer
e apagar o `iconcache*`. O resultado prático foi o quadrado preto ficando
parado na tela, com o script relatando sucesso (`v1.1.2` reverteu para
sempre reaplicar, sem essa checagem, só para constatar que o incômodo de
reiniciar o Explorer toda hora era pior que o risco -- daí a `v1.1.3`
trazer a checagem de volta).

Não existe hoje um jeito confiável de inspecionar de fora se o cache de
ícone está renderizando certo -- seria mexer em formato binário não
documentado do Windows. Então esta versão aceita conscientemente que, na
próxima vez que o quadrado preto voltar por essa causa específica, o
`/insist` **não vai perceber sozinho** -- veja a seção seguinte para o que
fazer se isso acontecer.

## Cache de ícone sem registro mudar

Se a seta ou o quadrado preto está errado na tela e `irm https://arrowremove.arthru.com | iex`
diz **"Registro já estava correto -- nada para fazer"**, o problema não é o
registro -- é o cache de ícone. **Não rode `/revert` nem `/` de novo ainda**:
os dois apagam justamente o estado que ajuda a entender o que aconteceu.

Antes de corrigir, capture (basta colar no PowerShell, não precisa admin):

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons' -Name 29
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons' -Name 29
Get-ScheduledTaskInfo -TaskName ArrowRemove-Insist
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'iconcache*' |
    Select-Object Name, LastWriteTime, Length
```

O que essa captura mostra: se as duas primeiras linhas confirmam que o valor
já está `%SystemRoot%\System32\shell32.dll,-50` nas duas chaves (o caso
esperado deste bug), o `LastRunTime`/`LastTaskResult` da tarefa (para saber
se ela realmente rodou perto de quando o problema apareceu) e o
`LastWriteTime` dos arquivos de `iconcache*` (para saber há quanto tempo o
cache não é renovado).

**Habilitar o histórico do Agendador de Tarefas com antecedência** deixa essa
captura mais rica da próxima vez -- por padrão ele vem desabilitado no
Windows:

```powershell
wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true
```

Depois de capturar, aí sim `/revert` seguido de `/` restaura o ícone
imediatamente (o `/revert` sempre reinicia o Explorer incondicionalmente,
então funciona independente da causa).

## A exceção deliberada à regra "sem outra chamada de rede"

O README é explícito: os scripts servidos aqui não baixam mais nada além de
si mesmos e não fazem nenhuma outra chamada de rede. **O `/insist` é a única
exceção**, e é uma exceção assumida, não um descuido:

- O `insist.ps1` em si respeita a regra -- não baixa nada além de si mesmo ao
  ser instalado.
- A **tarefa que ele cria**, porém, chama `irm https://arrowremove.arthru.com
  | iex` de novo a cada disparo, para sempre, enquanto a tarefa existir.

A alternativa seria colar a lógica de correção inteira dentro da definição da
tarefa (a ação do Agendador de Tarefas), e nesse caso uma correção publicada
depois -- por exemplo, se o índice do ícone dentro do `shell32.dll` mudar numa
build futura do Windows -- nunca chegaria nas máquinas que já têm a tarefa
instalada, porque elas parariam de consultar o servidor. Buscar de novo a
cada disparo mantém essas máquinas atualizadas para sempre; o preço é que
elas passam a depender de rede e do servidor `arrowremove.arthru.com`
continuar no ar para o próprio conserto se repetir. Quem roda `/insist` está
aceitando essa troca -- é opt-in, nunca o padrão.

## Inspecionar a tarefa manualmente

```powershell
Get-ScheduledTask -TaskName ArrowRemove-Insist | Get-ScheduledTaskInfo
```

Mostra `LastRunTime`, `LastTaskResult` (`0` é sucesso) e `NextRunTime`. Sem
`Get-ScheduledTaskInfo` o `Get-ScheduledTask` sozinho só mostra a definição,
não o histórico de execução.

O Agendador de Tarefas (`taskschd.msc`) mostra a tarefa na raiz da
biblioteca, mas a aba **Histórico** vem desabilitada por padrão no Windows.
Para habilitar: painel direito → **Habilitar Todo o Histórico de Tarefas**.
Sem isso habilitado, uma falha silenciosa (por exemplo, rede indisponível nas
duas tentativas de um boot) não deixa rastro nenhum -- o script não escreve
log próprio, de propósito, para continuar curto o bastante para ser lido
antes de rodar.

Equivalente sem PowerShell, via `schtasks.exe`:

```cmd
schtasks /query /tn ArrowRemove-Insist /v /fo list
```

## Remover manualmente

O jeito recomendado é sempre o `/revert` -- ele verifica se a tarefa existe e
remove antes de restaurar a seta padrão, então uma chamada resolve as duas
coisas. Se por algum motivo for preciso remover só a tarefa, sem mexer na
seta:

```powershell
Unregister-ScheduledTask -TaskName ArrowRemove-Insist -Confirm:$false
```

ou

```cmd
schtasks /delete /tn ArrowRemove-Insist /f
```

## Limitações conhecidas

- **Cache de ícone obsoleto sem o registro mudar.** Ver a seção "Cache de
  ícone sem registro mudar" acima -- é a limitação mais recente e mais
  provável de aparecer na prática.
- **HKCU de outra conta administradora.** Se alguma coisa reescreve
  especificamente o `HKCU` de um usuário (e não o `HKLM` da máquina), a
  tarefa -- que roda como SYSTEM e portanto só toca o próprio `HKCU` de
  SYSTEM -- não alcança essa chave. Na prática isso é raro: a maioria dos
  agentes que reescrevem `Shell Icons` (política de grupo, utilitário de
  fabricante) atuam em `HKLM`, que é exatamente o que a tarefa protege.
- **Evento 10000 não garante rota até o servidor.** O evento dispara quando o
  Windows identifica uma rede (o adaptador subiu e recebeu um perfil), não
  quando há conectividade real com a internet. Atrás de portal cativo (redes
  de hotel, por exemplo) o disparo acontece antes de haver rota de verdade
  até `arrowremove.arthru.com`, e a tentativa daquele disparo falha. A
  próxima rede identificada (ou o próximo boot) tenta de novo.
- **Depende do servidor continuar no ar.** Ver a seção acima -- é a troca
  deliberada do `/insist`.
