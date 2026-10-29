# pygeoapi

OCI image of [pygeoapi](https://pygeoapi.io), the Python server for the **OGC API** standards (Features, Coverages, Maps, Processes, Records, EDR, Tiles and more), maintained by the Geological Survey of Brazil (SGB/CPRM).

- **Production ready:** uWSGI speaking the uwsgi protocol, meant to run behind nginx.
- **Non-root:** runs as `1000:0` and accepts arbitrary UIDs, such as OpenShift's.
- **Read-only root filesystem:** only `/tmp` and `/var/lib/pygeoapi` need to be writable.
- **One geospatial stack:** `osgeo`, `rasterio`, `pyproj` and `shapely` all use the GDAL, PROJ and GEOS of the base image, with no bundled copies.
- **Local OGC schemas:** the `ogcapi/` schemas ship with the image instead of being downloaded at runtime.
- **Pinned dependencies:** each pygeoapi version has a lock file with the exact version and hash of every Python package.
- **amd64 and arm64**, with SBOM and provenance attestations.

Source code, examples and documentation: <https://github.com/nds-cprm/pygeoapi-oci>

## Tags

Each tag starts with the **pygeoapi version** (`<version>` in the examples below), followed by an optional suffix:

| Suffix | Contents |
|---|---|
| none | The latest build of that pygeoapi version. Moving: republished whenever the base image is updated, with the Debian and Python security fixes. |
| `-YYYYMMDD` | One specific build, identified by its date (UTC). Never overwritten: a second build on the same day gets `.2`, `.3`... Use it, preferably with its digest, to pin an exact image or to roll back. |

The available versions are listed in the Tags tab. There is no `latest` tag.

The base image is [`ndscprm/gdal`](https://hub.docker.com/r/ndscprm/gdal) (Debian trixie, Python 3.12 and GDAL 3.12). The exact base of each build is recorded in the `org.opencontainers.image.base.name` label.

## Quick start

Port 8000 speaks the **uwsgi protocol, not HTTP**. A plain `curl` against it will not work: put nginx in front of it, with `uwsgi_pass`.

`docker-compose.yaml`:

```yaml
services:
  pygeoapi:
    image: docker.io/ndscprm/pygeoapi:<version>
    read_only: true
    tmpfs:
      - /tmp
      - /var/lib/pygeoapi
    environment:
      PYGEOAPI_SERVER_URL: http://localhost:8080
    # volumes:
    #   - ./config.yml:/etc/pygeoapi/config.yml:ro
    healthcheck:
      test: ["CMD", "healthcheck"]
      interval: 30s
      timeout: 5s
      start_period: 15s
      retries: 3

  nginx:
    image: docker.io/nginxinc/nginx-unprivileged:1.30-alpine
    depends_on:
      pygeoapi:
        condition: service_healthy
    ports:
      - "8080:8080"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
```

`nginx.conf`:

```nginx
upstream pygeoapi {
    server pygeoapi:8000;
}

server {
    listen 8080;
    include uwsgi_params;
    uwsgi_read_timeout 65s;

    location / {
        uwsgi_pass pygeoapi;
    }
}
```

```sh
docker compose up -d
curl 'http://localhost:8080/?f=json'
```

The full nginx configuration (gzip, buffers) and the Kubernetes and OpenShift manifests are in [examples/](https://github.com/nds-cprm/pygeoapi-oci/tree/main/examples).

## Configuration

The default configuration, at `/etc/pygeoapi/config.yml`, has no collections (`resources: {}`). To publish your own, mount another file at that path or point `PYGEOAPI_CONFIG` somewhere else. pygeoapi replaces `${VAR:-default}` in the file with environment variables. The OpenAPI document is regenerated from the mounted configuration on every start.

The data referenced by the configuration must also be mounted into the container or live in a database reachable over the network.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `PYGEOAPI_SERVER_URL` | `http://localhost:8080` | Public URL, the base of every generated link. See below. |
| `PYGEOAPI_LOGLEVEL` | `ERROR` | pygeoapi log level. |
| `PYGEOAPI_LISTEN_PORT` | `8000` | uWSGI port (uwsgi protocol). Also read by the healthcheck. |
| `PYGEOAPI_CONFIG` | `/etc/pygeoapi/config.yml` | Configuration file. |
| `UWSGI_PROCESSES` | `4` | uWSGI processes. |
| `UWSGI_THREADS` | `2` | Threads per process. |

To change other uWSGI options, append them to the command: `uwsgi --ini /var/lib/uwsgi/uwsgi.conf --harakiri 120`.

### Public URL

pygeoapi does **not** read the `Host` or `X-Forwarded-*` headers. `PYGEOAPI_SERVER_URL` must be exactly the address clients use, with the scheme, the port (if not the default one) and the subpath, if any. For example: `https://geo.example.org/pygeoapi`.

## Security and runtime

- **User:** `1000:0`, with no entry in `/etc/passwd`. An nss_wrapper creates the user at runtime for any UID, so `--user <uid>:0` and OpenShift's `restricted-v2` both work.
- **Read-only root:** `/tmp` and `/var/lib/pygeoapi` must be writable, as `tmpfs` or `emptyDir`:

  | Runtime | How |
  |---|---|
  | Docker | `--read-only --tmpfs /tmp --tmpfs /var/lib/pygeoapi` |
  | Podman | `--read-only --tmpfs /var/lib/pygeoapi` (Podman mounts `/tmp` by itself) |
  | Kubernetes and OpenShift | `readOnlyRootFilesystem: true` and an `emptyDir` on each path |

- **Healthcheck:** the `healthcheck` script sends a uwsgi-protocol ping that a worker must answer. The same command serves Docker's `HEALTHCHECK`, Compose, Podman's `--health-cmd` and Kubernetes probes. On Kubernetes, also set `enableServiceLinks: false`.
- **Vulnerability scanning:** every build is scanned with Trivy and Grype before it is tagged.

## Included libraries

- **Native stack from the base image:** GDAL 3.12, PROJ 9.6 and GEOS 3.13.
- **Built from source against that stack:** `rasterio`, `pyproj` and `shapely`.
- **Extra provider:** OpenSearch (`opensearch-dsl`).
- **Application server:** uWSGI, built from source.

## License

Apache-2.0. pygeoapi itself is released under the MIT license. As with any container image, this image also contains software under other licenses (Debian, Python, GDAL and their dependencies), and it is the user's responsibility to make sure their use complies with them.
