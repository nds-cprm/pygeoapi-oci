# CLAUDE.md

Este arquivo orienta o Claude Code (claude.ai/code) no trabalho com este repositório.

## O que é

Um repositório para gerar uma imagem de contêiner OCI do [pygeoapi](https://pygeoapi.io) (servidor Python para os padrões OGC API), servido pelo uWSGI. O único workflow é o que mantém os locks (`.github/workflows/update-locks.yml`). Ainda não há CI de build nem testes automatizados. Licença Apache-2.0.

## Arquivos

- `Dockerfile`: build em três estágios sobre `docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}` (Debian trixie, Python oficial e GDAL instalado em `/opt/geosgb`, com o venv em `/opt/geosgb/venv` no `PATH`). Os estágios `schemas` e `wheels` usam a variante `-devel` da mesma tag, que traz `gcc`, `make`, os headers do Python e do GDAL, as bibliotecas `-dev`, além de `wget`, `curl` e `unzip`.
  - Estágio `schemas`: baixa o `SCHEMAS_OPENGIS_NET.zip` via HTTPS e extrai apenas `ogcapi/*` em `/schemas.opengis.net`, para que os schemas OGC sejam servidos localmente em vez de baixados em tempo de execução. A `-devel` já tem `wget` e `unzip`, que a imagem de runtime não tem, então não é preciso `apt-get`. O estágio fica separado do `wheels` para ter cache independente (mudar dependências não baixa o zip de novo) e para os dois serem construídos em paralelo. Pode ser gerado sozinho com `--target schemas`.
  - Estágio `wheels` (`-devel`): grava em `/wheels`, em duas camadas. Primeiro escolhe o lock `requirements/pygeoapi/${PYGEOAPI_VERSION}.txt` e, se ele não existir, para com uma mensagem mandando rodar o script para aquela versão. Depois roda `pip wheel --require-hashes --no-deps` para o lock, com as versões dos pacotes que a própria imagem já traz como restrições (`-c`, geradas no build com `pip freeze --all`). O `--no-deps` faz o pip baixar só o que está no lock, sem buscar de novo o numpy e os outros pacotes da base. Por último roda para o `requirements/extra/requirements.txt`, também restrito às versões do lock. Nessa restrição, os hashes são removidos com `sed`: se ficassem, o pip ativaria o modo de hashes também para os extras, que ainda não têm hash. Como cada um tem sua camada, mudar só os extras não refaz as wheels do pygeoapi. Pacotes sem wheel binária, como o uWSGI, são compilados ali, contra o mesmo Python e GDAL do estágio final. Os demais são só baixados. Para compilar outro módulo a partir do código-fonte, como o `rasterio`, adicione `--no-binary <pacote>` a esse `pip wheel`. Se o módulo estiver no lock, a wheel compilada não vai bater com nenhum hash no estágio final. Nesse caso, compile-o como extra ou deixe de verificar os hashes no `pip install` final. O `pip wheel` roda com `LDFLAGS=-s`, então tudo o que é compilado ali sai sem símbolos de depuração, como faz a imagem base. Isso precisa ser feito nesse estágio, porque a imagem de runtime não tem `strip`.
  - Estágio final:
    1. Instala as dependências com `pip install --no-index --find-links /wheels`, a partir das wheels montadas do estágio `wheels`, em dois passos. Primeiro o lock do `PYGEOAPI_VERSION`, usando `--require-hashes` e o `pip freeze --all` da imagem de runtime como restrições, para que nenhuma dependência troque o GDAL, o numpy ou outro pacote da base. Esse passo resolve as dependências, então falha se o lock estiver incompleto. Os hashes são verificados de novo aqui porque o estágio `wheels` mantém os arquivos do PyPI intactos. Depois o `requirements/extra/requirements.txt`, com o `pip freeze --all` de tudo o que já foi instalado como restrições, para que os extras só possam adicionar pacotes, nunca mudar um. Nos dois casos, uma tentativa de troca faz o build falhar com `ResolutionImpossible`. Os bind mounts exigem BuildKit.
    2. Copia `/schemas.opengis.net` do estágio `schemas`.
    3. Copia as configurações e os scripts listados abaixo e cria `/var/lib/pygeoapi`, com escrita para o grupo 0.
    4. Define `EXPOSE 8000`, `HEALTHCHECK` e `CMD ["uwsgi", "--ini", "/var/lib/uwsgi/uwsgi.conf"]`. O `ENTRYPOINT` é herdado da imagem base.
- `requirements/extra/requirements.txt`: dependências extras, editadas à mão e com versões exatas: providers e o servidor de aplicação. Hoje são o `opensearch-dsl` (provider OpenSearch) e o `uWSGI`, que só existe como código-fonte e é compilado no estágio `wheels`. Não use o `pyuwsgi`, que é a versão em wheel binária: a preferência do projeto é compilar. O binário compilado usa `libpcre2-8`, `libssl3`, `libxml2` e `libpython3.12`, todos presentes na imagem de runtime. Ao mudar a versão do uWSGI ou da base, confira com `ldd $(command -v uwsgi)` na imagem final que nada aparece como `not found`, porque a `-devel` tem bibliotecas que o runtime não tem, como `libyaml` e `libjansson`.
- `requirements/pygeoapi/<versão>.txt`: um lock por versão do pygeoapi, gerado e não editado à mão. O build escolhe o arquivo pelo `PYGEOAPI_VERSION`. Cada lock tem o pygeoapi e a árvore completa de dependências dele (hoje, 43 pacotes para a 0.24.0), com versão exata e o SHA-256 dos arquivos do PyPI. Ficam de fora os pacotes da imagem base (`GDAL`, `numpy`, `pyarrow`, `packaging`, `pip`, `setuptools`, `wheel`): a base já os fixa e verifica os hashes deles, e aqui eles entram só como restrições. Como cada versão tem seu lock, gerar o de uma versão nova não muda o que as outras instalam, e um rebuild de qualquer versão usa sempre as mesmas dependências.
- `requirements/update-requirements.sh`: gera o lock de uma ou mais versões, sem os extras. Sem argumento, usa o `PYGEOAPI_VERSION` do Dockerfile. Também aceita versões (`0.25.0`) ou caminhos de lock (`requirements/pygeoapi/*`, para regenerar todos depois de trocar a base). Grava em `requirements/pygeoapi/`. Caminhos só são aceitos quando o nome do arquivo é `<versão>.txt`, começando por um dígito. Os demais são pulados com uma mensagem. Resolve dentro da mesma imagem `-devel` do estágio `wheels`, com `pip install --dry-run --ignore-installed --report`, as versões lidas dos `ARG` do Dockerfile e os pacotes da base como restrições, igual ao build. Os hashes vêm da API JSON do PyPI e cobrem o sdist e as wheels que a imagem consegue instalar: Python puro, ou cp312/`abi3` em `manylinux`, de qualquer arquitetura. Assim, o mesmo arquivo serve para amd64 e arm64. Usa o Podman, ou o Docker se não houver Podman (`CONTAINER_ENGINE` força um deles).
- `.github/workflows/update-locks.yml`: mantém os locks fora do build e propõe as mudanças como PR. Roda em push no `main` que altere o Dockerfile. Se o `GDAL_VERSION` ou o `PYTHON_VERSION` mudaram em relação ao `github.event.before`, regenera todos os locks. Se a última versão do pygeoapi no PyPI não tem lock, gera o lock e a torna o `PYGEOAPI_VERSION` padrão. Havendo mudança, abre um PR do branch `update-locks/<sha>` com o `gh`, sem actions de terceiros. Depois do merge, o workflow roda de novo, não encontra nada a mudar e não abre outro PR. É preciso habilitar "Allow GitHub Actions to create and approve pull requests" em Settings > Actions > General. PRs abertos com o `GITHUB_TOKEN` não disparam outros workflows.
- `.dockerignore`: lista de permissão. Ignora tudo (`*`) e libera só o que o Dockerfile copia ou monta: `requirements/` (`pygeoapi/` com os locks e `extra/` com os extras; o `update-requirements.sh` fica de fora com `requirements/*.sh`), `conf/`, `docker/` e `docker-entrypoint.d/`. Ao fazer o Dockerfile usar um arquivo ou diretório novo, acrescente uma linha `!caminho` ali. Senão, o build falha com arquivo não encontrado. O Podman e o Docker leem esse arquivo.
- `conf/uwsgi.conf` → `/var/lib/uwsgi/uwsgi.conf`: carrega `pygeoapi.flask_app:APP` via HTTP direto na porta 8000 (`http-socket`, sem processo roteador), pensado para ficar atrás de um proxy reverso, ingress ou balanceador. Usa `die-on-term`, porque no uWSGI 2.0 o SIGTERM recarrega em vez de parar.
- `conf/pygeoapi-config.yml` → `/etc/pygeoapi/config.yml` (`PYGEOAPI_CONFIG`): configuração padrão sem coleções (`resources: {}`), com `ogc_schemas_location: /schemas.opengis.net`. Em produção, monte outro arquivo por cima ou aponte `PYGEOAPI_CONFIG` para outro caminho. O pygeoapi substitui `${VAR:-padrão}` por variáveis de ambiente.
- `docker-entrypoint.d/20-pygeoapi-openapi.sh`: gera o OpenAPI em `PYGEOAPI_OPENAPI` (`/var/lib/pygeoapi/openapi.yml`) a cada início, para refletir a configuração montada.
- `docker/healthcheck` → `/usr/local/bin/healthcheck`: faz um GET em `http://127.0.0.1:8000/?f=json`, que é respondido por um worker do uWSGI. É o mesmo script para o `HEALTHCHECK` do Docker, para o Compose, o Quadlet e as probes do Kubernetes.

Build args e seus valores padrão: `GDAL_VERSION=3.12.4`, `PYTHON_VERSION=3.12`, `PYGEOAPI_VERSION=0.24.0`. Mantenha o formato `ARG NOME=valor` nessas três linhas: o script as lê, e o workflow `update-locks` as compara entre commits e reescreve a do `PYGEOAPI_VERSION` com `sed`. O `--build-arg PYGEOAPI_VERSION=...` funciona para qualquer versão que tenha lock em `requirements/`.

## Build e execução

```sh
podman build -t pygeoapi-oci .        # ou docker build
podman build --build-arg PYGEOAPI_VERSION=0.25.0 -t pygeoapi-oci:0.25.0 .   # requer requirements/pygeoapi/0.25.0.txt
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
2. **pygeoapi:** o lock `requirements/pygeoapi/${PYGEOAPI_VERSION}.txt`, gerado pelo script, com o pygeoapi e cada dependência dele fixados e com hash. O pip roda em modo de hashes (`--require-hashes`).
3. **Extras:** o `requirements/extra/requirements.txt`, editado à mão. É instalado por último e só pode acrescentar pacotes. Ainda não tem hashes.

Fluxo (o workflow `update-locks` faz os dois primeiros casos sozinho quando o Dockerfile muda no `main`; à mão, o fluxo é o mesmo):
- **Nova versão do pygeoapi:** rode `./requirements/update-requirements.sh <versão>`, faça o build com `--build-arg PYGEOAPI_VERSION=<versão>` e commite o lock novo. Para torná-la a padrão, mude o `ARG` no Dockerfile. Os locks das versões anteriores continuam como estão.
- **Troca da tag da imagem base:** rode `./requirements/update-requirements.sh requirements/pygeoapi/*` para regenerar todos os locks, já que eles dependem dos pacotes da base.
- Não regenere um lock existente sem motivo. A ideia é que um rebuild da mesma versão instale as mesmas dependências.

No modo de hashes, um lock ausente ou incompleto faz o build falhar, em vez de deixar passar algo sem versão fixa:
- `no lock file for pygeoapi X`: falta o lock dessa versão.
- `Hashes are required in --require-hashes mode`: um pacote necessário não está no lock, por exemplo depois de trocar a base sem regenerar os locks.
- `THESE PACKAGES DO NOT MATCH THE HASHES`: um arquivo baixado do PyPI não bate com o hash. Pode ser uma versão republicada ou adulteração. Investigue antes de regenerar.

Para adicionar ou atualizar um extra, edite o `requirements/extra/requirements.txt`. O script não é necessário. Se o extra precisar de uma versão diferente de algo que o pygeoapi ou a base já fixam, o build falha com `ResolutionImpossible`. Os extras são os mesmos para todas as versões do pygeoapi, então confira que cada versão com lock ainda faz build depois de mudá-los.

As dependências transitivas que só os extras puxam não estão fixadas, e nenhum extra tem hash. Hoje são `opensearch-py`, `opensearch-protobufs`, `grpcio`, `protobuf` e `Events`. Elas seguem a versão mais recente compatível a cada build. Para estender os hashes aos extras, todas elas precisam estar listadas com versão e hash. Além disso, o uWSGI é compilado, então o hash dele só pode ser verificado no sdist, no estágio `wheels`. A wheel compilada é local e não tem hash conhecido para o `pip install` final.

O script resolve as dependências na arquitetura da máquina em que roda. Hoje nenhum pacote tem dependência condicionada à plataforma, mas, se algum passar a ter, confira o resultado nas duas arquiteturas.

## Convenções

- Fixe a versão exata de toda dependência, tanto a tag da imagem base quanto os pacotes Python. As dependências do pygeoapi ficam nos locks gerados em `requirements/`, um por versão, e os extras, no `requirements/extra/requirements.txt`. Os pacotes da imagem base não são repetidos aqui: a base já os fixa e verifica os hashes deles.
- Mantenha as imagens portáveis entre Docker, Podman/Quadlet e Kubernetes. O Podman (no formato OCI) e o Kubernetes ignoram o `HEALTHCHECK`, então as verificações de saúde passam pelo script `healthcheck`, que Compose, Quadlet e probes podem chamar.
- Do estágio `-devel`, passe só as wheels para o estágio final, nunca o venv `/opt/geosgb/venv` inteiro. A imagem de runtime vem de um estágio da imagem base que remove os pacotes `-dev` e os símbolos de depuração: o `_gdal.so` tem 1,5 MB no runtime e 8,3 MB na `-devel`. Copiar o venv traria esses arquivos e duplicaria na nova camada os 124 MB do venv que a base já tem.
- Tudo o que precisar ser gravado em tempo de execução deve ficar em diretórios com dono do grupo 0 e `chmod g=u`, para funcionar com UIDs arbitrários.
- Scripts em `/docker-entrypoint.d`: os `*.sh` executáveis rodam num processo filho, e os não executáveis são carregados com `source`, o que permite exportar variáveis para o `CMD`. Eles rodam em ordem lexical, e uma falha impede o container de subir.
