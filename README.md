# arrowremove

Tira a seta de atalho dos ícones do Windows, por uma linha:

```powershell
irm https://arrowremove.arthru.com | iex          # aplica
irm https://arrowremove.arthru.com/revert | iex   # reverte
irm https://arrowremove.arthru.com/insist | iex   # reaplica sozinho a cada boot
```

O script pede elevação (a chave fica em `HKLM`), gera um ícone praticamente
transparente em `%ProgramFiles%\arrowremove\sem-seta.ico`, aponta a seta de
atalho para ele, limpa o cache de ícones, reinicia o Explorer e termina. Não
baixa mais nada e não faz nenhuma outra chamada de rede.

Este repositório é o servidor por trás daquela URL: os três scripts, a
configuração do nginx que os entrega em texto puro, e a imagem de container que
junta as quatro coisas. O endereço é servido pelo homelab, atrás de um Cloudflare
Tunnel.

## O achado que motivou tudo

A técnica conhecida para isso é apontar `Shell Icons\29` -- o índice da
sobreposição de atalho -- para um ícone transparente. **A parte que quase toda
receita na internet erra é a fonte do ícone.**

A receita clássica funciona, e depois falha: a seta some, e no boot seguinte
(ou no próximo reinício do Explorer, ou depois de instalar algum programa) o
Windows passa a desenhar um **quadrado preto** no lugar dela. Acontece com
`.ico` próprio de qualquer formato **e** com o `shell32.dll,-50`, que este
projeto usou até a `v1.1.3` achando que era imune.

**A causa, medida:** todo ícone "totalmente transparente" tem alfa 0 em todo
pixel. Extraído fresco, ele é desenhado pela máscara e fica invisível. Mas o
Explorer guarda o overlay no cache de ícones (`iconcache_*.db`), e na volta do
cache a imagem chega com alfa 0 **e máscara opaca** -- o Windows conclui
"imagem sem canal alfa" e pinta a cor crua, que é preta. Qualquer recarga do
cache dispara isso: boot, reinício do Explorer, ou instalação que avisa o
shell de mudança de associação. Por isso o quadrado preto parecia ligado a
"cada boot" e, em outros dias, a "instalei o WSL/Docker/um app da Store".

Medido em Windows 11 build 26300, lendo a lista de imagens do sistema pela API
documentada (`SHGetImageList` + `GetOverlayImage`, ver
[`tools/diagnostico-overlay.ps1`](tools/diagnostico-overlay.ps1)):

| Overlay (depois de recarregar do cache) | 16px | 32px | 48px |
|---|---|---|---|
| `shell32.dll,-50` (alfa 0) | 256/256 pixels pretos | 1024/1024 | 2304/2304 |
| ícone com alfa 1 em todo pixel | 0 visíveis | 0 | 0 |

**A correção:** um ícone com alfa **1** (de 255) em todo pixel. São 0,4% de
opacidade -- desenhado sobre um atalho real, muda no máximo 2/255 de algum
canal, imperceptível --, mas o canal alfa sobrevive ao cache e o Windows passa
a misturar pelo alfa em vez de pintar a máscara. Nenhum ícone do Windows é
assim, então o script gera o seu, byte a byte, sem arquivo binário embutido.

**A regra que fica:** para sobreposição de ícone, nunca um ícone de alfa 0, de
lugar nenhum. Se você veio parar aqui procurando por que a sua seta virou um
quadrado preto, é isso.

## Maquinas que insistem (insist)

O quadrado preto que voltava a cada boot **não** precisa do `/insist`: era o
ícone de alfa 0 quebrando no cache (seção acima), e o `/` sozinho resolve
isso de vez desde a `v1.2.0`. O `/insist` é para o caso que sobra: máquina em
que alguma política de grupo, utilitário do fabricante ou reimagem de driver
reescreve a chave `Shell Icons` ou apaga o ícone. Não há como descobrir de
fora quem faz isso; o `/insist` não tenta -- ele só confere e reaplica:

```powershell
irm https://arrowremove.arthru.com/insist | iex
```

Isso cria uma tarefa agendada (`ArrowRemove-Insist`, rodando como
`NT AUTHORITY\SYSTEM`) que dispara **no boot e a cada vez que a máquina
identifica uma rede nova** -- cabo, Wi-Fi ou VPN -- e chama o `/` de novo a
cada disparo. **O Explorer só é reiniciado se o ícone ou o `HKLM` estavam
diferentes do esperado**; num boot normal, nada acontece. Isso só é seguro
porque o ícone de alfa 1 não quebra no cache -- com o de alfa 0, essa mesma
checagem já deixou o quadrado preto na tela com o script dizendo "nada a
fazer" (`v1.1.1`). Ver [`docs/insist.md`](docs/insist.md). É a única exceção deliberada à
regra "sem outra chamada de rede" logo abaixo: a tarefa criada continua
contatando o servidor para sempre, para que uma correção publicada depois
chegue automaticamente nas máquinas que já têm a tarefa instalada.

Para desfazer, o `/revert` já cuida de tudo -- ele verifica se a tarefa
existe e remove antes de restaurar a seta padrão:

```powershell
irm https://arrowremove.arthru.com/revert | iex
```

## Decisões de desenho que parecem detalhe e não são

**O script é autocontido.** Não baixa mais nada além de si mesmo, não faz outra
chamada de rede, não tem dependência. Quem roda `irm | iex` está executando
código de um servidor sem tela de login na frente -- a única defesa que sobra é
o arquivo ser curto o bastante para ser lido inteiro antes. Isso é requisito, não
estilo: um PR que introduza uma dependência externa está mudando o modelo de
segurança da coisa. O ícone que substitui a seta é montado byte a byte dentro
do próprio script (alfa 1 em todo pixel, máscara toda transparente) -- dá para
conferir lendo, sem confiar num binário. (A tarefa que o
[`/insist`](#maquinas-que-insistem-insist) cria é a única exceção conhecida e
deliberada à regra de rede -- ela chama o `/` de novo a cada disparo, para
sempre. Ver `docs/insist.md`.)

**O que está aqui é byte a byte o que a URL entrega.** Não há template nem etapa
de geração entre este repositório e a resposta HTTP. Ler o arquivo no GitHub
equivale a ler o que vai executar.

**Os scripts são ASCII puro.** O corpo vai como `text/plain; charset=utf-8` e o
PowerShell 5.1 decodifica pelo charset anunciado no cabeçalho. O nginx anuncia
certo, mas se algum intermediário raspar o cabeçalho o PS assume ISO-8859-1 -- e
os bytes chegam trocados no meio de um script que roda elevado. A CI reprova o
commit que introduzir um byte acima de 127.

**O Explorer volta sozinho.** O script derruba o Explorer para soltar o cache de
ícones, mas **não** o reabre incondicionalmente: o Winlogon faz isso por conta
própria (`AutoRestartShell=1`). Um `Start-Process explorer.exe` disparado do
processo elevado abriria o shell com token de administrador, e todo programa
aberto por ele depois viria elevado junto. O script só força se o Winlogon não
trouxer o shell de volta em 3 segundos.

**A limpeza de cache é `iconcache*`, não `*cache*`.** O filtro largo levaria
junto o `thumbcache`, que são as miniaturas de foto e vídeo -- nada a ver com a
seta, e caro de regerar. E é de **todos os perfis locais**, não só do processo:
o overlay vem do `HKLM` e vale para a máquina toda, mas o cache é por usuário
-- e rodando como SYSTEM (tarefa do `/insist`) o `%LOCALAPPDATA%` do processo
nem é o de uma pessoa.

**O `HKLM` é o que conta.** O script escreve o mesmo valor em `HKLM` e `HKCU`,
mas medido com os dois diferentes, o Explorer usa o do `HKLM`. O `HKCU` só
recebe o valor para não sobrar ali um resto de outra receita.

**O revert apaga o valor, não escreve a seta de volta.** A seta padrão não vem de
uma entrada em `Shell Icons`; ela é o comportamento do Windows na ausência de
qualquer entrada. Escrever algo ali, mesmo imitando o original, deixaria a
máquina fora do estado de fábrica. Pelo mesmo motivo ele apaga também a pasta
`%ProgramFiles%\arrowremove`.

## Arquivos

```
install.ps1     servido em /
revert.ps1      servido em /revert
insist.ps1      servido em /insist
site.conf       server block do nginx, vai para conf.d/default.conf
Dockerfile      nginx:1.30.4-alpine + os tres scripts acima
docs/insist.md  referencia completa da tarefa agendada que o /insist cria
tools/diagnostico-overlay.ps1
                mede o overlay de atalho como o Explorer o recebe do cache;
                nao e servido, so para investigar
```

O `healthcheck` e o enrijecimento do container (`read_only`, tmpfs,
`no-new-privileges`) **não** estão aqui: moram no `docker-compose.yml` que o
Ansible escreve no homelab, porque são contrato de implantação e não propriedade
da imagem. A CI, porém, sobe o container com exatamente aquela postura antes de
publicar -- é onde um caminho de escrita novo do nginx apareceria, e não em
produção.

## Rodar local

```bash
docker build -t arrowremove .
docker run --rm -p 8080:80 \
  --read-only --tmpfs /var/cache/nginx --tmpfs /run --tmpfs /tmp \
  arrowremove

curl -i http://127.0.0.1:8080/
curl -i http://127.0.0.1:8080/revert
curl -i http://127.0.0.1:8080/insist
```

O `content-type` tem de sair como `text/plain; charset=utf-8`. Se sair outra
coisa, o `irm | iex` quebra em campo.

## Publicar uma versão

```bash
git tag v1.0.1
git push origin v1.0.1
```

A tag dispara a CI, que testa e publica em
`ghcr.io/arthru-vinicius/arrowremove:v1.0.1`.

**O formato `vX.Y.Z` não é convenção solta.** A CLI `homelab update` descarta
qualquer tag que não case com esse padrão ao procurar "a versão mais nova" --
uma tag `1.0.1` sem o `v`, ou `release-1`, faz o app aparecer no `homelab
status` sem nunca ter atualização disponível.

Depois de publicar, no servidor:

```bash
ssh homelab
homelab update arrowremove
```

A CLI baixa a imagem, troca a tag, recria o container, espera o healthcheck, e
desfaz sozinha se ele não ficar saudável em 60s.

### Na primeira publicação

O pacote nasce **privado** no GitHub. Vá em Packages → `arrowremove` → Package
settings → Change visibility → **Public**. Sem isso o servidor precisaria de um
token de leitura configurado no vault do homelab (ver `docs/homelab-cli.md` lá,
seção "Apps públicos vs. privados") -- o que funciona, mas é peso desnecessário
para conteúdo que já é público por definição.

## O lado da infraestrutura

Ingress do túnel, política do Cloudflare Access e implantação estão no
repositório `homelab`, em `docs/arrowremove.md`.

O ponto que vale saber aqui: **este é o único hostname daquele túnel sem
Cloudflare Access na frente**, e isso é requisito, não descuido. O `irm` não é
navegador -- atrás do Access ele receberia o HTML da tela de login e o `iex`
tentaria executar HTML, com um erro que não menciona login em momento algum.
