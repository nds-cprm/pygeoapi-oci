# CLAUDE.md

Este arquivo orienta o Claude Code (claude.ai/code) no trabalho com este repositório.

## O que é

Um repositório para gerar uma imagem de contêiner OCI do [pygeoapi](https://pygeoapi.io) (servidor Python para os padrões OGC API), servido pelo uWSGI. Ainda não há workflow de CI nem testes automatizados. Licença Apache-2.0.

## Arquivos

- `Dockerfile`: build em três estágios sobre `docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}` (Debian trixie, Python oficial e GDAL instalado em `/opt/geosgb`, com o venv em `/opt/geosgb/venv` no `PATH`). Os estágios `schemas` e `wheels` usam a variante `-devel` da mesma tag, que traz `gcc`, `make`, os headers do Python e do GDAL, as bibliotecas `-dev`, além de `wget`, `curl` e `unzip`.
  - Estágio `schemas`: baixa o `SCHEMAS_OPENGIS_NET.zip` via HTTPS e extrai apenas `ogcapi/*` em `/schemas.opengis.net`, para que os schemas OGC sejam servidos localmente em vez de baixados em tempo de execução. A `-devel` já tem `wget` e `unzip`, que a imagem de runtime não tem, então não é preciso `apt-get`. O estágio fica separado do `wheels` para ter cache independente (mudar dependências não baixa o zip de novo) e para os dois serem construídos em paralelo. Pode ser gerado sozinho com `--target schemas`.
  - Estágio `wheels` (`-devel`): grava em `/wheels`, em duas camadas. Primeiro roda `pip wheel` para o `requirements.txt` e o `pygeoapi==${PYGEOAPI_VERSION}`, com as versões dos pacotes que a própria imagem já traz como restrições (`-c`, geradas no build com `pip freeze --all`). Depois roda para o `requirements-extra.txt`, com restrições também do `requirements.txt`. Como cada um tem sua camada, mudar só os extras não refaz as wheels do pygeoapi. Pacotes sem wheel binária, como o uWSGI, são compilados ali, contra o mesmo Python e GDAL do estágio final. Os demais são só baixados. Para compilar outro módulo a partir do código-fonte, como o `rasterio`, adicione `--no-binary <pacote>` a esse `pip wheel`. O `pip wheel` roda com `LDFLAGS=-s`, então tudo o que é compilado ali sai sem símbolos de depuração, como faz a imagem base. Isso precisa ser feito nesse estágio, porque a imagem de runtime não tem `strip`.
  - Estágio final:
    1. Instala as dependências com `pip install --no-index --find-links /wheels`, a partir das wheels montadas do estágio `wheels`, em dois passos. Primeiro o pygeoapi e o `requirements.txt`, com o `pip freeze --all` da imagem de runtime como restrições, para que nenhuma dependência troque o GDAL, o numpy ou outro pacote da base. Depois o `requirements-extra.txt`, com o `pip freeze --all` de tudo o que já foi instalado como restrições, para que os extras só possam adicionar pacotes, nunca mudar um. Nos dois casos, uma tentativa de troca faz o build falhar com `ResolutionImpossible`. Os bind mounts exigem BuildKit.
    2. Copia `/schemas.opengis.net` do estágio `schemas`.
    3. Copia as configurações e os scripts listados abaixo e cria `/var/lib/pygeoapi`, com escrita para o grupo 0.
    4. Define `EXPOSE 8000`, `HEALTHCHECK` e `CMD ["uwsgi", "--ini", "/var/lib/uwsgi/uwsgi.conf"]`. O `ENTRYPOINT` é herdado da imagem base.
- `requirements-extra.txt`: dependências extras, editadas à mão e com versões exatas: providers e o servidor de aplicação. Hoje são o `opensearch-dsl` (provider OpenSearch) e o `uWSGI`, que só existe como código-fonte e é compilado no estágio `wheels`. Não use o `pyuwsgi`, que é a versão em wheel binária: a preferência do projeto é compilar. O binário compilado usa `libpcre2-8`, `libssl3`, `libxml2` e `libpython3.12`, todos presentes na imagem de runtime. Ao mudar a versão do uWSGI ou da base, confira com `ldd $(command -v uwsgi)` na imagem final que nada aparece como `not found`, porque a `-devel` tem bibliotecas que o runtime não tem, como `libyaml` e `libjansson`.
- `requirements.txt`: gerado, não editado à mão. Tem a versão exata de cada dependência do pygeoapi, hoje 42 pacotes. Ficam de fora o próprio pygeoapi, fixado pelo `PYGEOAPI_VERSION`, e os pacotes que a imagem base já traz (`GDAL`, `numpy`, `pyarrow`, `packaging`, `pip`, `setuptools`, `wheel`), que são responsabilidade dela e entram como restrições no build.
- `scripts/update-requirements.sh`: gera o `requirements.txt` só com as dependências do pygeoapi, sem os extras. Resolve dentro da mesma imagem `-devel` do estágio `wheels`, com as versões lidas dos `ARG` do Dockerfile e os pacotes da base como restrições, igual ao build. Usa o Podman, ou o Docker se não houver Podman (`CONTAINER_ENGINE` força um deles).
- `.dockerignore`: lista de permissão. Ignora tudo (`*`) e libera só o que o Dockerfile copia ou monta: `requirements.txt`, `requirements-extra.txt`, `conf/`, `docker/` e `docker-entrypoint.d/`. Ao fazer o Dockerfile usar um arquivo ou diretório novo, acrescente uma linha `!caminho` ali. Senão, o build falha com arquivo não encontrado. O Podman e o Docker leem esse arquivo.
- `conf/uwsgi.conf` → `/var/lib/uwsgi/uwsgi.conf`: carrega `pygeoapi.flask_app:APP` via HTTP direto na porta 8000 (`http-socket`, sem processo roteador), pensado para ficar atrás de um proxy reverso, ingress ou balanceador. Usa `die-on-term`, porque no uWSGI 2.0 o SIGTERM recarrega em vez de parar.
- `conf/pygeoapi-config.yml` → `/etc/pygeoapi/config.yml` (`PYGEOAPI_CONFIG`): configuração padrão sem coleções (`resources: {}`), com `ogc_schemas_location: /schemas.opengis.net`. Em produção, monte outro arquivo por cima ou aponte `PYGEOAPI_CONFIG` para outro caminho. O pygeoapi substitui `${VAR:-padrão}` por variáveis de ambiente.
- `docker-entrypoint.d/20-pygeoapi-openapi.sh`: gera o OpenAPI em `PYGEOAPI_OPENAPI` (`/var/lib/pygeoapi/openapi.yml`) a cada início, para refletir a configuração montada.
- `docker/healthcheck` → `/usr/local/bin/healthcheck`: faz um GET em `http://127.0.0.1:8000/?f=json`, que é respondido por um worker do uWSGI. É o mesmo script para o `HEALTHCHECK` do Docker, para o Compose, o Quadlet e as probes do Kubernetes.

Build args e seus valores padrão: `GDAL_VERSION=3.12.4`, `PYTHON_VERSION=3.12`, `PYGEOAPI_VERSION=0.24.0`. Um comentário diz que a linha do `PYGEOAPI_VERSION` também é lida por um workflow de CI, então mantenha o formato `ARG NOME=valor` nessa linha. Esse workflow ainda não existe.

## Build e execução

```sh
podman build -t pygeoapi-oci .        # ou docker build
podman run --rm -p 8000:8000 -e PYGEOAPI_SERVER_URL=http://localhost:8000 pygeoapi-oci
podman run --rm -p 8000:8000 -v ./minha-config.yml:/etc/pygeoapi/config.yml:ro pygeoapi-oci
```

Para testar manualmente: `curl localhost:8000/?f=json`, `/conformance`, `/openapi`, `/collections`, e um schema local como `/schemas/ogcapi/features/part1/1.0/openapi/schemas/landingPage.yaml`. Também `podman exec <container> healthcheck`.

O `podman build` usa o formato OCI por padrão e avisa que vai ignorar o `HEALTHCHECK`. Para manter o `HEALTHCHECK`, use `--format docker`.

## Variáveis de ambiente

- `PYGEOAPI_SERVER_URL` (padrão `http://localhost:8000`): URL pública usada nos links gerados pela API.
- `PYGEOAPI_LOGLEVEL` (padrão `ERROR`).
- `UWSGI_PROCESSES` (padrão 4) e `UWSGI_THREADS` (padrão 2). No `uwsgi.conf`, os padrões ficam em blocos `if-not-env`, porque as opções definidas no `.ini` prevalecem sobre as variáveis `UWSGI_*`. Para mudar outras opções do uWSGI, acrescente-as ao `CMD` (`uwsgi --ini /var/lib/uwsgi/uwsgi.conf --harakiri 120`), já que as opções da linha de comando aplicadas depois do `--ini` prevalecem.

## Pendências e armadilhas

As pendências ficam no [TODO.md](TODO.md). Ao resolver uma, marque-a lá e atualize este arquivo se o comportamento da imagem mudar.

- Um `ARG` declarado antes do primeiro `FROM` só vale para as linhas `FROM`. Para usá-lo dentro de um estágio, repita `ARG NOME` depois do `FROM`, como já é feito com o `PYGEOAPI_VERSION`. Sem isso, a instalação roda como `pip install "pygeoapi=="` e falha.
- A base dá suporte a UIDs arbitrários (estilo OpenShift) com o script `10-enable-nss-wrapper.sh`, que usa `HOME=/tmp` quando o UID não existe no `/etc/passwd`. Com `--user 12345:0`, a imagem funciona, porque `/var/lib/pygeoapi` tem escrita para o grupo 0.
- Com `--read-only`, o container não sobe sem um `tmpfs` ou volume em `/var/lib/pygeoapi`, porque o OpenAPI é gerado ali a cada início.
- A imagem final tem cerca de 915 MB, dos quais 598 MB vêm da imagem base. A `-devel` tem cerca de 2,4 GB, mas só é usada no build.

## Dependências Python

A instalação tem três camadas, cada uma presa às anteriores:

1. **Base:** os pacotes da imagem base. As restrições são geradas no build e acompanham a tag da base, sem arquivo no repositório.
2. **pygeoapi:** o `requirements.txt`, gerado pelo script, mais o `PYGEOAPI_VERSION`.
3. **Extras:** o `requirements-extra.txt`, editado à mão. É instalado por último e só pode acrescentar pacotes.

Ao mudar o `PYGEOAPI_VERSION` ou a tag da imagem base, rode `./scripts/update-requirements.sh` e commite o `requirements.txt` junto. Se ele ficar desatualizado, uma dependência nova do pygeoapi que não esteja no arquivo é instalada sem versão fixa e sem aviso. Por isso, regenere sempre, mesmo quando o build passar. Regenerar também remove as dependências que o pygeoapi deixou de usar.

Para adicionar ou atualizar um extra, edite o `requirements-extra.txt`. O script não é necessário. Se o extra precisar de uma versão diferente de algo que o pygeoapi ou a base já fixam, o build falha com `ResolutionImpossible`.

As dependências transitivas que só os extras puxam não estão fixadas. Hoje são `opensearch-py`, `opensearch-protobufs`, `grpcio`, `protobuf` e `Events`. Elas seguem a versão mais recente compatível a cada build. Para fixá-las, liste-as com versão no `requirements-extra.txt`.

O script resolve as dependências na arquitetura da máquina em que roda. Hoje nenhum pacote tem dependência condicionada à plataforma, mas, se algum passar a ter, confira o resultado nas duas arquiteturas.

## Convenções

- Fixe a versão exata de toda dependência, tanto a tag da imagem base quanto os pacotes Python. As dependências do pygeoapi ficam no `requirements.txt` gerado, e os extras, no `requirements-extra.txt`.
- Mantenha as imagens portáveis entre Docker, Podman/Quadlet e Kubernetes. O Podman (no formato OCI) e o Kubernetes ignoram o `HEALTHCHECK`, então as verificações de saúde passam pelo script `healthcheck`, que Compose, Quadlet e probes podem chamar.
- Do estágio `-devel`, passe só as wheels para o estágio final, nunca o venv `/opt/geosgb/venv` inteiro. A imagem de runtime vem de um estágio da imagem base que remove os pacotes `-dev` e os símbolos de depuração: o `_gdal.so` tem 1,5 MB no runtime e 8,3 MB na `-devel`. Copiar o venv traria esses arquivos e duplicaria na nova camada os 124 MB do venv que a base já tem.
- Tudo o que precisar ser gravado em tempo de execução deve ficar em diretórios com dono do grupo 0 e `chmod g=u`, para funcionar com UIDs arbitrários.
- Scripts em `/docker-entrypoint.d`: os `*.sh` executáveis rodam num processo filho, e os não executáveis são carregados com `source`, o que permite exportar variáveis para o `CMD`. Eles rodam em ordem lexical, e uma falha impede o container de subir.
