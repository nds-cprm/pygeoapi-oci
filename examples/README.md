# Exemplo com Docker Compose

A imagem fala o **protocolo uwsgi** (não HTTP) na porta 8000. O exemplo [`nginx/`](nginx/) põe o nginx na frente como proxy reverso: ele recebe HTTP na porta 8080 e repassa ao uWSGI com `uwsgi_pass`.

| Serviço | Imagem | Papel |
|---|---|---|
| `pygeoapi` | `ndscprm/pygeoapi` | uWSGI na porta 8000 (protocolo uwsgi), raiz somente leitura, com `tmpfs` em `/tmp` (nss_wrapper) e em `/var/lib/pygeoapi` (OpenAPI gerado a cada início) |
| `nginx` | `nginxinc/nginx-unprivileged` | HTTP na porta 8080 do host, sem root e com raiz somente leitura; configuração em [`nginx/conf/nginx/nginx.conf`](nginx/conf/nginx/nginx.conf) |

O nginx só sobe depois que o healthcheck do pygeoapi passa. O healthcheck é declarado no Compose de propósito: o Podman ignora o `HEALTHCHECK` de imagens no formato OCI.

## Uso

```sh
cd examples/nginx
docker compose up -d
curl 'http://localhost:8080/?f=json'
```

Para testar uma imagem construída localmente: `PYGEOAPI_IMAGE=pygeoapi-oci docker compose up -d`. Com o Podman, `podman compose` funciona igual.

Sem configuração própria, o pygeoapi usa a padrão da imagem, sem coleções. Para publicar as suas, descomente o `volumes:` do serviço `pygeoapi` e crie `nginx/conf/pygeoapi/config.yml` (o pygeoapi substitui `${VAR:-padrão}` pelas variáveis de ambiente). Os dados referenciados pela configuração também precisam ser montados, ou ficar num banco acessível pela rede.

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
