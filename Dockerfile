# Ramo 'stable' do nginx, nao o 'mainline': aqui so se serve arquivo estatico,
# nao ha um recurso sequer do mainline que interesse, e o stable troca de
# versao menos vezes. Versao fixa, nunca faixa aberta -- subir de versao e um
# commit, com diff e possibilidade de revert.
FROM nginx:1.30.4-alpine

# Por cima do default.conf da imagem, nao ao lado. Ver o cabecalho do site.conf.
COPY site.conf /etc/nginx/conf.d/default.conf

# Os tres arquivos que este servidor inteiro existe para entregar.
COPY install.ps1 revert.ps1 insist.ps1 /usr/share/nginx/html/

# Sem HEALTHCHECK aqui, de proposito. Ele mora no docker-compose.yml que o
# Ansible escreve no homelab (roles/apps/templates/arrowremove-compose.yml.j2),
# porque quem depende dele e a CLI 'homelab update' -- e um contrato de
# implantacao, nao uma propriedade da imagem. Declarar nos dois lugares criaria
# duas verdades que podem divergir.
#
# Sem USER tambem: o master do nginx precisa de root para abrir a porta 80 e
# larga os workers no uid 101 sozinho. Quem enrijece o resto e o compose do
# homelab, com read_only, tmpfs e no-new-privileges.
