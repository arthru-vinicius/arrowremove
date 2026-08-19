# arrowremove

Tira a seta de atalho dos ícones do Windows, por uma linha:

```powershell
irm https://arrowremove.arthru.com | iex          # aplica
irm https://arrowremove.arthru.com/revert | iex   # reverte
irm https://arrowremove.arthru.com/insist | iex   # reaplica sozinho a cada boot
```

O script pede elevação (a chave fica em `HKLM`), escreve o valor, reinicia o
Explorer e termina. Não baixa mais nada e não faz nenhuma outra chamada de rede.

Este repositório é o servidor por trás daquela URL: os três scripts, a
configuração do nginx que os entrega em texto puro, e a imagem de container que
junta as quatro coisas. O endereço é servido pelo homelab, atrás de um Cloudflare
Tunnel.

## O achado que motivou tudo

A técnica conhecida para isso é apontar `Shell Icons\29` -- o índice da
sobreposição de atalho -- para um ícone transparente. **A parte que quase toda
receita na internet erra é a fonte do ícone.**

Testado ao vivo num Dell Latitude 5420 com Windows 11 build 26200:

Apontar para um arquivo `.ico` próprio **funciona, e depois falha.** O ícone é
aceito, a seta some, e depois de alguns reboots o Windows passa a desenhar um
**quadrado preto** no lugar dela. Reproduzido com máscara clássica AND/XOR e com
PNG multi-resolução com canal alfa puro, e relatado por outras pessoas usando a
mesma técnica -- não é um `.ico` mal formado nem uma máquina específica.

Apontar para um recurso **já embutido num DLL do sistema** resolve de forma
estável:

```
%SystemRoot%\System32\shell32.dll,-50
```

Validado programaticamente: extraído com `ExtractIconEx`, dá 0 de 1024 pixels
opacos -- é transparente de verdade, não "quase".

**A regra que fica:** para sobreposição de ícone, sempre um índice dentro de um
DLL do sistema, nunca um arquivo externo. Se você veio parar aqui procurando por
que a sua seta virou um quadrado preto, é isso.

## Maquinas que insistem (insist)

O `/` acima resolve a maioria das máquinas de forma permanente. Em algumas,
porém, a seta (ou o quadrado preto) **volta sozinha depois de um boot**,
mesmo já com a correção aplicada -- normalmente porque alguma política de
grupo, utilitário do fabricante ou reimagem de driver reescreve a chave
`Shell Icons` de novo. Não há como descobrir de fora quem está reescrevendo;
o `/insist` não tenta -- ele só reaplica a correção com frequência
suficiente para ganhar a corrida:

```powershell
irm https://arrowremove.arthru.com/insist | iex
```

Isso cria uma tarefa agendada (`ArrowRemove-Insist`, rodando como
`NT AUTHORITY\SYSTEM`) que dispara **no boot e a cada vez que a máquina
identifica uma rede nova** -- cabo, Wi-Fi ou VPN -- e chama o `/` de novo a
cada disparo -- **inclusive reiniciando o Explorer todas as vezes.** Parece
caro, mas é deliberado: o quadrado preto pode voltar por cache de ícone
obsoleto, não só por registro reescrito, e o registro já estar correto não
prova que o ícone está renderizando certo agora. Sem jeito confiável de
inspecionar o cache de fora, reaplicar sempre é o único jeito de o `/insist`
funcionar de verdade. É a única exceção deliberada à regra "sem outra
chamada de rede" logo abaixo: a tarefa criada continua contatando o
servidor para sempre, para que uma correção publicada depois chegue
automaticamente nas máquinas que já têm a tarefa instalada. Ver
[`docs/insist.md`](docs/insist.md) para o que exatamente a tarefa faz, como
inspecioná-la e como remover na mão.

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
segurança da coisa. (A tarefa que o [`/insist`](#maquinas-que-insistem-insist)
cria é a única exceção conhecida e deliberada -- ela chama o `/` de novo a
cada disparo, para sempre. Ver `docs/insist.md`.)

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
seta, e caro de regerar.

**O revert apaga o valor, não escreve a seta de volta.** A seta padrão não vem de
uma entrada em `Shell Icons`; ela é o comportamento do Windows na ausência de
qualquer entrada. Escrever algo ali, mesmo imitando o original, deixaria a
máquina fora do estado de fábrica.

## Arquivos

```
install.ps1     servido em /
revert.ps1      servido em /revert
insist.ps1      servido em /insist
site.conf       server block do nginx, vai para conf.d/default.conf
Dockerfile      nginx:1.30.4-alpine + os tres scripts acima
docs/insist.md  referencia completa da tarefa agendada que o /insist cria
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
