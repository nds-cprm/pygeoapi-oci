# CLAUDE.md

Este arquivo orienta o Claude Code (claude.ai/code) no trabalho com este repositório.

## O que é

Um repositório para gerar uma imagem de contêiner OCI do [pygeoapi](https://pygeoapi.io) (servidor Python para os padrões OGC API). O projeto está no início: os únicos insumos do build são o `Dockerfile` e o `requirements.txt`. Ainda não há código de aplicação, configuração do pygeoapi, workflow de CI nem testes. Licença Apache-2.0.

## Arquivos

- `Dockerfile`: build em dois estágios, ambos sobre `docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}` (Debian trixie, Python oficial e GDAL instalado em `/opt/geosgb`).
  - Estágio `schemas`: baixa o `SCHEMAS_OPENGIS_NET.zip` via HTTPS e extrai apenas `ogcapi/*` em `/schemas.opengis.net`, para que os schemas OGC sejam servidos localmente em vez de baixados em tempo de execução. Como a imagem base não tem `wget` nem `unzip`, eles são instalados via apt só nesse estágio, que é descartado. Esse estágio pode ser gerado sozinho com `--target schemas`.
  - Estágio final:
    1. Instala o `requirements.txt` com pip, usando o próprio arquivo como arquivo de restrições (`-c`). Como ele é montado via bind mount, o build exige BuildKit.
    2. Instala `pygeoapi==${PYGEOAPI_VERSION}`.
    3. Copia `/schemas.opengis.net` do estágio `schemas`.
- `requirements.txt`: dependências Python extras para os providers do pygeoapi, com versões exatas (hoje, `opensearch-dsl` para o provider OpenSearch).

Build args e seus valores padrão: `GDAL_VERSION=3.12.4`, `PYTHON_VERSION=3.12`, `PYGEOAPI_VERSION=0.24.0`. Um comentário diz que a linha do `PYGEOAPI_VERSION` também é lida por um workflow de CI, então mantenha o formato `ARG NOME=valor` nessa linha. Esse workflow ainda não existe.

## Build

```sh
docker build -t pygeoapi-oci .
docker build --build-arg PYGEOAPI_VERSION=0.24.0 -t pygeoapi-oci .
# ou: podman build -t pygeoapi-oci .
```

## Problemas conhecidos e partes inacabadas

- Um `ARG` declarado antes do primeiro `FROM` só vale para as linhas `FROM`. Para usá-lo dentro de um estágio, repita `ARG NOME` depois do `FROM`, como já é feito com o `PYGEOAPI_VERSION`. Sem isso, a instalação roda como `pip install "pygeoapi=="` e falha.
- Partes do Dockerfile vieram de uma imagem do MapProxy e estão comentadas: `WORKDIR`, a instalação do `gettext-base`, `EXPOSE 8000`, um `HEALTHCHECK` que chama um script `healthcheck` e um `CMD` que roda o uWSGI com `/var/lib/uwsgi/uwsgi.conf`. Um comentário que sobrou ainda chama o arg de versão de "MapProxy version". Ainda não há comando de execução, configuração do pygeoapi (`PYGEOAPI_CONFIG`, `PYGEOAPI_OPENAPI`) nem porta exposta. Segundo os comentários, o `ENTRYPOINT` da imagem base (`/docker-entrypoint.sh`) executa os scripts em `/docker-entrypoint.d` e depois o `CMD`.
- O pip instala as wheels binárias do `rasterio`, que trazem um GDAL próprio (3.12.2), diferente do GDAL 3.12.4 da imagem base usado pelo `osgeo`. Para que o `rasterio` use o GDAL da base, compile-o a partir do código-fonte (`--no-binary rasterio`). O `pyproj` também traz um PROJ próprio.
- Nenhum servidor WSGI/ASGI (uWSGI, Gunicorn) é instalado.
- A imagem base roda como root por padrão. O script `10-enable-nss-wrapper.sh` dá suporte a UIDs arbitrários (estilo OpenShift), usando `HOME=/tmp` quando o UID não existe no `/etc/passwd`.

## Convenções

- Fixe a versão exata de toda dependência, tanto a tag da imagem base quanto os pacotes Python.
- Mantenha as imagens portáveis entre Docker, Podman/Quadlet e Kubernetes. O `HEALTHCHECK` comentado observa que o Podman e o Kubernetes o ignoram, então as verificações de saúde devem passar por um script que Compose, Quadlet e probes possam chamar.
