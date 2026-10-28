# Exemplo com Kubernetes e OpenShift

Os mesmos dois serviços do [exemplo com Compose](../README.md), com sistema de arquivos raiz somente leitura:

| Arquivo | Conteúdo |
|---|---|
| [`pygeoapi.yaml`](pygeoapi.yaml) | Deployment e Service `pygeoapi` (protocolo uwsgi na porta 8000) |
| [`nginx.yaml`](nginx.yaml) | Deployment e Service `nginx` (HTTP na porta 8080), com a configuração do ConfigMap `nginx-conf` |
| [`openshift-route.yaml`](openshift-route.yaml) | Só no OpenShift: Route com TLS terminado no router |

## Uso

Na raiz do repositório:

```sh
kubectl create configmap nginx-conf \
    --from-file=default.conf=examples/nginx/conf/nginx/nginx.conf
kubectl apply -f examples/kubernetes/pygeoapi.yaml -f examples/kubernetes/nginx.yaml
kubectl port-forward svc/nginx 8080:8080
curl 'http://localhost:8080/?f=json'
```

No OpenShift, use `oc` no lugar de `kubectl` e aplique também o `openshift-route.yaml`. Depois, troque o `PYGEOAPI_SERVER_URL` do `pygeoapi.yaml` pelo endereço da Route (`oc get route pygeoapi`), com `https://`.

O ConfigMap do nginx é criado a partir do mesmo `nginx.conf` do exemplo com Compose, então os dois exemplos não divergem. Ao mudar o arquivo, recrie o ConfigMap (`kubectl create configmap ... --dry-run=client -o yaml | kubectl apply -f -`) e reinicie o nginx (`kubectl rollout restart deployment/nginx`).

## Sistema de arquivos somente leitura

Os dois containers usam `readOnlyRootFilesystem: true`. Cada um grava só em volumes `emptyDir`:

| Container | Caminho | Para quê |
|---|---|---|
| `pygeoapi` | `/tmp` | O nss_wrapper da imagem base cria ali o passwd virtual do UID, que não está no `/etc/passwd`. Sem ele, o container sai logo no início com `mktemp: failed to create directory`. |
| `pygeoapi` | `/var/lib/pygeoapi` | O OpenAPI, gerado a cada início a partir da configuração. Sem ele, o container sai com `Could not open file '/var/lib/pygeoapi/openapi.yml'`. |
| `nginx` | `/tmp` | O arquivo de PID e os arquivos temporários do nginx. |

Um `emptyDir` começa vazio a cada início do pod, o que é o esperado nos três casos. Por padrão, ele fica no disco do nó. Com `medium: Memory`, ele vai para a RAM e conta no limite de memória do container.

## Usuário e OpenShift

Os manifestos não definem `runAsUser`. No Kubernetes, o pygeoapi roda com o usuário da imagem, `1000:0`, e o nginx, com o UID 101. A SCC `restricted-v2` do OpenShift troca o UID por um arbitrário do namespace (por exemplo, `1000740000`) e mantém o grupo 0. As duas imagens funcionam assim: o nss_wrapper cria o usuário, e os diretórios graváveis pertencem ao grupo 0.

O `securityContext` também atende às exigências da `restricted-v2` e do Pod Security Standard `restricted`: `runAsNonRoot`, `allowPrivilegeEscalation: false`, todas as capabilities removidas e o seccomp `RuntimeDefault`.

## Probes

O Kubernetes e o OpenShift ignoram o `HEALTHCHECK` da imagem. As probes chamam o mesmo script, `healthcheck`, um ping no protocolo uwsgi respondido por um worker:

- `startupProbe`: até 60 s (30 tentativas de 2 s) para gerar o OpenAPI e subir o primeiro worker. Aumente o `failureThreshold` se a configuração tiver muitas coleções.
- `readinessProbe`: tira o pod do Service enquanto nenhum worker responde.
- `livenessProbe`: reinicia o container depois de três falhas seguidas, de 30 em 30 s.

## Service links

Os pods usam `enableServiceLinks: false`. Sem isso, o Kubernetes injeta em cada pod variáveis como `<SERVICE>_PORT` para todos os Services do namespace. Com o Service `pygeoapi`, aparece `PYGEOAPI_PORT=tcp://<ip>:8000`. Por isso, a porta da imagem se chama `PYGEOAPI_LISTEN_PORT`, e não `PYGEOAPI_PORT`. A imagem funciona com os service links ligados, mas eles poluem o ambiente sem trazer nada: o nginx encontra o pygeoapi pelo DNS do Service.

## Configuração própria

Para publicar coleções, crie um ConfigMap com o arquivo de configuração e descomente o volume `config` do `pygeoapi.yaml`:

```sh
kubectl create configmap pygeoapi-config --from-file=config.yml=<seu config.yml>
```

O `subPath` monta só o arquivo `/etc/pygeoapi/config.yml`. Um ConfigMap montado com `subPath` não é atualizado no pod quando muda, então reinicie o deployment (`kubectl rollout restart deployment/pygeoapi`). Isso também gera o OpenAPI de novo.

Verificado em 27/10/2026 no minikube (Kubernetes 1.32), com a imagem construída localmente:
- respostas 200 pelo nginx, inclusive a página HTML e um schema local;
- raiz somente leitura, com escrita só nos `emptyDir`;
- os dois deployments com o UID 1000740000 e o GID 0, como na `restricted-v2`;
- o pygeoapi com os service links ligados.

A Route do OpenShift não foi testada.
