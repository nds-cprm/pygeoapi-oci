# Exemplo com Docker Compose

A imagem fala o **protocolo uwsgi** (não HTTP) na porta 8000. O exemplo [`nginx/`](nginx/) põe o nginx na frente como proxy reverso: ele recebe HTTP na porta 8080 e repassa ao uWSGI com `uwsgi_pass`.

| Serviço | Imagem | Papel |
|---|---|---|
| `pygeoapi` | `ndscprm/pygeoapi` | uWSGI na porta 8000 (protocolo uwsgi), raiz somente leitura, com `tmpfs` em `/tmp` (nss_wrapper) e em `/var/lib/pygeoapi` (OpenAPI gerado a cada início) |
| `nginx` | `nginxinc/nginx-unprivileged` | HTTP na porta 8080 do host, sem root e com raiz somente leitura; configuração em [`nginx/conf/nginx/nginx.conf`](nginx/conf/nginx/nginx.conf) |

Para Kubernetes e OpenShift, veja [`kubernetes/`](kubernetes/README.md).

O nginx só sobe depois que o healthcheck do pygeoapi passa. O healthcheck é declarado no Compose de propósito: o Podman ignora o `HEALTHCHECK` de imagens no formato OCI.

## Uso

```sh
cd examples/nginx
docker compose up -d
curl 'http://localhost:8080/?f=json'
```

Para testar uma imagem construída localmente: `PYGEOAPI_IMAGE=pygeoapi-oci docker compose up -d`. Com o Podman, `podman compose` funciona igual.

Sem configuração própria, o pygeoapi usa a padrão da imagem, sem coleções. Para publicar as suas, descomente o `volumes:` do serviço `pygeoapi` e crie `nginx/conf/pygeoapi/config.yml` (o pygeoapi substitui `${VAR:-padrão}` pelas variáveis de ambiente). Os dados referenciados pela configuração também precisam ser montados, ou ficar num banco acessível pela rede.

## Podman sem Compose

O Podman ignora o `HEALTHCHECK` de imagens no formato OCI, que é o padrão do `podman build`. Declare o healthcheck no `podman run`, com o mesmo script e os mesmos tempos da imagem:

```sh
podman run -d --name pygeoapi --read-only --tmpfs /var/lib/pygeoapi \
    --health-cmd healthcheck --health-interval 30s --health-timeout 5s \
    --health-start-period 15s --health-retries 3 \
    docker.io/ndscprm/pygeoapi:0.24.0
podman healthcheck run pygeoapi   # 0 = saudável; também aparece em podman ps
```

- Com `--read-only`, o Podman monta sozinho um `tmpfs` em `/tmp`, onde o nss_wrapper cria o passwd virtual. O Docker não faz isso, então lá é preciso acrescentar `--tmpfs /tmp`.
- O Podman agenda as verificações periódicas com timers do systemd. Sem systemd, como em alguns containers de CI, só o `podman healthcheck run` funciona.
- Num build local com `podman build`, use `--format docker` para manter o `HEALTHCHECK` na imagem. As imagens publicadas pelo CI, geradas pelo BuildKit, já o têm.

## Sistema de arquivos somente leitura

A imagem funciona com a raiz somente leitura, desde que dois caminhos sejam graváveis:

- `/tmp`: o nss_wrapper da imagem base cria ali o passwd virtual do UID, que não está no `/etc/passwd`. Sem ele, o container sai logo no início com `mktemp: failed to create directory ... /tmp/nss_wrapper.XXXXXX`.
- `/var/lib/pygeoapi`: o OpenAPI, gerado a cada início (`PYGEOAPI_OPENAPI`). Sem ele, o container sai com `Could not open file '/var/lib/pygeoapi/openapi.yml'`.

| Runtime | Como |
|---|---|
| Docker | `docker run --read-only --tmpfs /tmp --tmpfs /var/lib/pygeoapi ...` |
| Podman | `podman run --read-only --tmpfs /var/lib/pygeoapi ...` (o Podman monta `/tmp` sozinho com `--read-only`) |
| Compose | `read_only: true` e `tmpfs:` com os dois caminhos, como em [`nginx/docker-compose.yaml`](nginx/docker-compose.yaml) |
| Kubernetes e OpenShift | `readOnlyRootFilesystem: true` e um `emptyDir` em cada caminho, como em [`kubernetes/pygeoapi.yaml`](kubernetes/pygeoapi.yaml) |

Os dois caminhos podem ser `tmpfs` ou volumes vazios: nada neles precisa sobreviver a um reinício. Um volume nomeado em `/var/lib/pygeoapi` também funciona, e o Podman o cria com dono `1000:0`. O teste de fumaça do CI roda a imagem assim, com `--read-only` e um UID arbitrário (`--user 12345:0`).

## Porta

O uWSGI escuta na porta de `PYGEOAPI_LISTEN_PORT` (padrão 8000), lida também pelo `healthcheck`. Ela pode ser trocada no build (`--build-arg PYGEOAPI_LISTEN_PORT=...`, que também muda o `EXPOSE`) ou ao rodar (`-e PYGEOAPI_LISTEN_PORT=...`). O `upstream` do [`nginx.conf`](nginx/conf/nginx/nginx.conf) precisa apontar para a mesma porta.

## URL pública

O pygeoapi monta todos os links (JSON, HTML, OpenAPI) a partir do `server.url` da configuração, que na imagem vem de `PYGEOAPI_SERVER_URL`. Ele **não** lê o `Host` nem os cabeçalhos `X-Forwarded-*` do pedido, então a variável precisa ser o endereço que o cliente usa:

| Cenário | `PYGEOAPI_SERVER_URL` |
|---|---|
| Este exemplo, acessado no próprio host | `http://localhost:8080` (o padrão) |
| Outro nome ou porta | `http://<host>:<porta>` |
| TLS no nginx ou num terminador/balanceador na frente dele | `https://<host>` |
| Subcaminho (veja abaixo) | `https://<host>/pygeoapi` |

No Compose, a variável pode vir do ambiente ou de um `.env`: `PYGEOAPI_SERVER_URL=https://geo.exemplo.gov.br docker compose up -d`. Ao mudá-la, recrie o container do pygeoapi (`docker compose up -d`), que gera o OpenAPI de novo na inicialização.

## Subcaminho

Para publicar em `/pygeoapi/`, troque o `location /` do `nginx.conf` por:

```nginx
# relative Location headers, so the redirect keeps the public host and port
absolute_redirect off;

location /pygeoapi/ {
    # pygeoapi routes from /: drop the prefix (the links come from PYGEOAPI_SERVER_URL)
    rewrite ^/pygeoapi(/.*)$ $1 break;
    uwsgi_pass pygeoapi;
}

location = /pygeoapi {
    return 301 /pygeoapi/;
}
```

e defina `PYGEOAPI_SERVER_URL` com o prefixo (ex.: `http://localhost:8080/pygeoapi`).

- O `rewrite ... break` muda o caminho que o nginx envia no `PATH_INFO` (o `uwsgi_params` usa `$document_uri`), então o pygeoapi recebe `/conformance` para `/pygeoapi/conformance`. Não é preciso mexer em `SCRIPT_NAME`.
- O `absolute_redirect off` (no `server`) faz o `301` sair com `Location: /pygeoapi/`. Sem ele, o nginx monta uma URL absoluta com a porta em que ele escuta dentro do container (8080), que é errada quando o Compose publica outra porta.
- Um `uwsgi_param` dentro do `location` cancela todos os herdados do `server` (`include uwsgi_params`). Se acrescentar algum ali, repita o `include uwsgi_params` no mesmo bloco.

## Timeouts e buffers

- `uwsgi_read_timeout 65s` acompanha o `harakiri = 60` do uWSGI ([`conf/uwsgi.conf`](../conf/uwsgi.conf)): o uWSGI mata o worker travado (e registra isso no log dele) antes de o nginx desistir da espera, e o worker volta a atender. Ao mudar um, mude o outro.
- `uwsgi_buffer_size` e `uwsgi_buffers` guardam respostas grandes (páginas de GeoJSON, o OpenAPI) na memória do nginx, para liberar o worker do uWSGI logo.
- O `gzip_types` lista o tipo do OpenAPI duas vezes, com e sem `;version=3.0`: o nginx compara o `Content-Type` inteiro, exceto o `charset`.

Verificado em 25/10/2026 com o Podman (`podman compose`): links com a URL pública, páginas HTML e arquivos estáticos, schemas locais, gzip e o subcaminho `/pygeoapi/` com outra porta publicada. O teste de fumaça do CI ([`.github/scripts/smoke-test.sh`](../.github/scripts/smoke-test.sh)) usa este `nginx.conf`, então uma mudança nele é testada a cada build.
