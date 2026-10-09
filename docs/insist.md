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

**Não é o quadrado preto a cada boot.** Esse era o ícone de alfa 0 quebrando
no cache de ícones, e o `/` sozinho resolve de vez desde a `v1.2.0` -- ver
"O achado que motivou tudo" no README. Antes disso, o `/insist` existia em
boa parte para remediar esse sintoma, e nunca conseguiu: reaplicar o mesmo
ícone de alfa 0 só adiava o quadrado preto até a próxima recarga do cache.

O que sobra para o `/insist` é a máquina em que **alguma coisa reescreve a
configuração**: política de grupo de domínio, utilitário do fabricante ou
reimagem de driver que muda a chave `Shell Icons`, ou algo que apaga o ícone
em `%ProgramFiles%\arrowremove`. Não dá para descobrir de fora qual é o agente,
e o `/insist` não tenta: cria uma tarefa agendada que confere e, se preciso,
reaplica o `/` sozinha.

## O que a tarefa criada faz, exatamente

Nome: **`ArrowRemove-Insist`**, visível na raiz da Biblioteca do Agendador de
Tarefas (não numa subpasta).

| Campo | Valor | Por quê |
|---|---|---|
| Ação | `powershell.exe -NoProfile -WindowStyle Hidden -Command "... irm https://arrowremove.arthru.com \| iex"` | Chama de novo o `/` (aplicar), não uma cópia colada da lógica. Uma correção publicada depois de instalado o `/insist` chega automaticamente no próximo disparo. |
| Gatilho 1 | No boot (`AtStartup`) | Cobre o caso comum. |
| Gatilho 2 | Evento 10000 do log `Microsoft-Windows-NetworkProfile/Operational` | Disparado pelo Windows toda vez que identifica uma rede (cabo, Wi-Fi ou VPN). Cobre o caso em que o boot dispara a ação antes da rede subir -- a tentativa do boot falha (sem rede, o `irm` não completa), e este segundo gatilho tenta de novo assim que há rede. |
| Executar como | `NT AUTHORITY\SYSTEM`, nível mais alto | O que a tarefa mantém é o `HKLM` e o ícone em Program Files -- valem para a máquina inteira, não para uma conta. O `install.ps1` reconhece SYSTEM e cai no ramo que só confere (abaixo), sem passar por UAC. Funciona também sem ninguém logado. |
| Múltiplas instâncias | `IgnoreNew` | Se os dois gatilhos dispararem quase juntos (boot e rede em sequência rápida, comum em SSD), a segunda execução é descartada em vez de rodar em paralelo. |
| Limite de execução | 5 minutos | O script normalmente termina em segundos; o limite existe só para não deixar uma cópia travada seguindo dona da tarefa para sempre. |

## Só mexe no Explorer se precisou mudar algo

A tarefa dispara com frequência -- todo boot, toda troca de rede --, mas
rodando como SYSTEM o `install.ps1` só apaga o cache de ícones e reinicia o
Explorer **quando o ícone em Program Files ou o valor no `HKLM` estavam
diferentes do esperado**. Num boot normal, a tarefa roda, confere e sai sem
encostar no Explorer. No boot, antes do logon, nem há Explorer para derrubar:
se precisar limpar o cache, limpa direto nos perfis.

Essa checagem já causou uma regressão uma vez (`v1.1.1`), e vale saber por
quê: com o ícone de alfa 0 da época, registro correto **não** significava
overlay correto -- o cache transformava o ícone em quadrado preto com o
registro intacto, e a checagem dizia "nada a fazer". Com o ícone de alfa 1
(`v1.2.0`), o cache não tem mais como estragá-lo, então arquivo e registro
corretos passam a significar, de fato, overlay invisível. Testado nos três
caminhos: manual (sempre reinicia), SYSTEM sem nada a mudar (Explorer
intocado) e SYSTEM com o `HKLM` antigo (migra e reinicia uma vez).

A `v1.1.4` tentou fechar o mesmo buraco por outro lado: manteve o ícone de
alfa 0 e passou a **detectar** o quadrado preto (lendo até três atalhos com
`SHGetFileInfo`) para então resetar o cache. A detecção funcionava, mas o
reset só durava até a próxima recarga do cache -- no boot seguinte o preto
voltava e ela dispararia de novo, reiniciando o Explorer no boot, que é o que
o `/insist` não deve fazer. E rodando como SYSTEM ela lia o cache do SYSTEM,
não o de quem está logado. Com o ícone de alfa 1 não há mais o que detectar,
e ela saiu na `v1.2.0`; a medição ficou em `tools/diagnostico-overlay.ps1`.

Quem roda o `/` **na mão** continua tendo o Explorer reiniciado sempre: é
uma ação deliberada, e é o reset que tira do cache um quadrado preto gravado
por versão anterior.

## Diagnóstico

Se a seta ou um quadrado preto aparecer de novo, **antes de rodar qualquer
coisa** meça o que o Explorer está recebendo do cache com o
[`tools/diagnostico-overlay.ps1`](../tools/diagnostico-overlay.ps1) do
repositório -- como o usuário que vê o problema, sem elevar:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\diagnostico-overlay.ps1
```

Ele lê a lista de imagens do sistema montada a partir do cache gravado em
disco (o mesmo caminho do Explorer no boot) e diz, por tamanho, quantos
pixels do overlay de atalho o Windows desenharia. "Invisível em todos os
tamanhos" com a seta na tela aponta para outra coisa que não o overlay; pixels
visíveis com alfa máximo 0 e máscara opaca é a assinatura do quadrado preto
de alfa 0 -- algum valor antigo voltou ao `HKLM`. A linha do `HKLM` no fim
mostra qual ícone está configurado.

Depois de medir, `irm https://arrowremove.arthru.com | iex` resolve: na mão,
ele sempre reaplica e limpa o cache.

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
depois nunca chegaria nas máquinas que já têm a tarefa instalada, porque elas
parariam de consultar o servidor. Exemplo real: a troca do ícone de alfa 0
pelo de alfa 1 (`v1.2.0`) chegou sozinha, no boot seguinte, em toda máquina
com a tarefa -- e o ramo SYSTEM do `install.ps1` faz a migração reiniciando
o Explorer uma única vez. Buscar de novo a
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

- **Só confere arquivo e registro, não o desenho.** A tarefa roda como SYSTEM
  e não enxerga o cache de ícones de quem está logado, então não mede o
  overlay -- quem mede é o [`tools/diagnostico-overlay.ps1`](../tools/diagnostico-overlay.ps1).
  Com o ícone de alfa 1, arquivo e registro corretos bastam; se um dia
  aparecer um jeito novo de o overlay quebrar com os dois intactos, a tarefa
  não vai perceber, e o `/` na mão continua resolvendo.
- **Evento 10000 não garante rota até o servidor.** O evento dispara quando o
  Windows identifica uma rede (o adaptador subiu e recebeu um perfil), não
  quando há conectividade real com a internet. Atrás de portal cativo (redes
  de hotel, por exemplo) o disparo acontece antes de haver rota de verdade
  até `arrowremove.arthru.com`, e a tentativa daquele disparo falha. A
  próxima rede identificada (ou o próximo boot) tenta de novo.
- **Depende do servidor continuar no ar.** Ver a seção acima -- é a troca
  deliberada do `/insist`.
