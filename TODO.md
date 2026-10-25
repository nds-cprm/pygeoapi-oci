# TODO

Pendências do projeto, por prioridade. Levantadas em 2026-10-25 com builds e execuções de teste no Podman (arm64).

## Alta: reprodutibilidade e segurança

- [x] **Fixar as dependências do pygeoapi.** O `requirements/update-requirements.sh` gera um lock por versão em `requirements/pygeoapi/<versão>.txt`, escolhido no build pelo `PYGEOAPI_VERSION`. Gerar o lock de uma versão nova não muda as anteriores. Os extras ficam no `requirements/extra/requirements.txt` e são instalados depois, sem poder mudar nada do que já foi instalado. Os pacotes da base não entram nos locks, porque a base já os fixa e verifica, e são usados só como restrições, geradas no build com `pip freeze --all`.
- [ ] **Fixar as dependências transitivas dos extras.** `opensearch-py`, `opensearch-protobufs`, `grpcio`, `protobuf` e `Events` vêm só dos extras e não estão fixados. Para fixá-los, liste-os com versão no `requirements/extra/requirements.txt`, ou crie um script que gere essa lista.
- [x] **Verificar hashes dos pacotes do pygeoapi.** Cada lock traz o SHA-256 dos arquivos do PyPI para o pygeoapi e as dependências dele (43 pacotes na 0.24.0), para amd64 e arm64. Os pacotes da base não são verificados de novo. O pip roda com `--require-hashes` no `pip wheel` e de novo no `pip install` final. Os extras ainda não são verificados: veja o item anterior. Para incluí-los, cada dependência transitiva precisa de versão e hash, e o uWSGI só pode ser verificado no sdist, no estágio `wheels`.
- [ ] **Fixar a imagem base por tag datada ou digest.** As tags `3.12.4-py3.12` e `3.12.4-py3.12-devel` são reconstruídas, e as variantes datadas também são publicadas (por exemplo, `3.12.4-py3.12-20261025`). Os estágios `-devel` e o final devem usar a mesma data.
- [ ] **Verificar o zip dos schemas OGC.** O `SCHEMAS_OPENGIS_NET.zip` é baixado sem conferência de checksum e muda no servidor sem versão. Fixe um SHA-256, guardado em `ARG` e verificado com `sha256sum -c`, ou baixe só os diretórios `ogcapi/` de uma fonte versionada.
- [ ] **Rodar como usuário sem privilégios.** Não há `USER`, então o uWSGI roda como root e avisa `you are running uWSGI as root`. A imagem já funciona com `--user 12345:0`, então basta definir `USER` com um UID numérico e o grupo 0.

## Média: comportamento em produção

- [ ] **Compilar o `rasterio` contra o GDAL da base.** A wheel binária traz um GDAL 3.12.2 próprio (66 MB em `rasterio.libs`), diferente do GDAL 3.12.4 da base. Adicione `--no-binary rasterio` ao `pip wheel` do estágio `wheels` e confira com `ldd` que ele usa `/opt/geosgb/lib`. Avalie o mesmo para o `pyproj` (PROJ embutido, 13 MB), o `shapely` (GEOS embutido) e o `fiona`, se for usado.
- [ ] **Documentar e testar o uso com sistema de arquivos somente leitura.** Com `--read-only`, o container não sobe (`Read-only file system` ao gerar `/var/lib/pygeoapi/openapi.yml`). Funciona com `--tmpfs /var/lib/pygeoapi` ou um volume. Deixe isso documentado para Kubernetes (`readOnlyRootFilesystem` com `emptyDir`) e Quadlet.
- [ ] **Tornar a porta configurável num só lugar.** A porta 8000 está repetida em `EXPOSE`, `conf/uwsgi.conf` (`http-socket`), `docker/healthcheck` e `conf/pygeoapi-config.yml` (`server.bind`). Mudar uma delas sem as outras quebra o healthcheck.
- [ ] **Configurar o `HEALTHCHECK` para o Podman.** No formato OCI, que é o padrão do Podman, o `HEALTHCHECK` é descartado no build. Defina o `--format docker` no CI ou documente o `HealthCmd=healthcheck` no Quadlet.
- [ ] **Medir o tempo de geração do OpenAPI na subida.** O `20-pygeoapi-openapi.sh` regenera o documento a cada início. Com muitas coleções, isso pode atrasar o início além do `--start-period=15s` do healthcheck e das probes.
- [ ] **Revisar os parâmetros do uWSGI para cargas reais.** Os valores atuais (`processes=4`, `threads=2`, `harakiri=60`, `buffer-size=32768`) são padrões razoáveis, mas não foram testados com carga real. Avalie também `max-requests` ou `reload-on-rss`, para limitar vazamento de memória em providers de raster.

## Baixa: limpeza e infraestrutura

- [x] **Remover os restos do MapProxy no Dockerfile.** Os blocos comentados foram removidos, e o comentário do `ARG` agora diz "default pygeoapi version".
- [ ] **Criar o workflow de CI.** O comentário do `PYGEOAPI_VERSION` cita um workflow que lê essa linha, mas ele não existe. O workflow deve fazer o build multi-arquitetura (amd64 e arm64; até agora só arm64 foi testado), o smoke test (subir o container e chamar `healthcheck`, `/conformance` e um schema local) e a publicação.
- [ ] **Adicionar labels OCI** (`org.opencontainers.image.source`, `version`, `licenses`, `base.name`...). Hoje a imagem só tem o label do Buildah.
- [ ] **Criar o `README.md`** com o uso da imagem: variáveis de ambiente, como montar a configuração, volumes e exemplos de Compose, Quadlet e Kubernetes. Hoje essa informação está só no `CLAUDE.md`.
- [x] **Criar o `.dockerignore`.** Funciona como lista de permissão: ignora tudo e libera só o que o Dockerfile usa (`requirements*.txt`, `conf/`, `docker/` e `docker-entrypoint.d/`).
- [ ] **Reduzir o tamanho da imagem** (cerca de 915 MB, com 598 MB vindos da base). A maior parte do ganho vem do item do `rasterio`. Depois dele, vale ver o que mais pesa no venv (`du` em `site-packages`).
