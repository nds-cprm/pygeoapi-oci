#!/bin/sh
# Smoke test of the image, run by the CI on the native runner of each architecture (and locally:
# DOCKER=podman .github/scripts/smoke-test.sh <image>). Starts the container as it runs in production
# (arbitrary UID, read-only root filesystem with tmpfs on /tmp and /var/lib/pygeoapi) behind nginx with
# the configuration of examples/nginx (port 8000 speaks the uwsgi protocol, not HTTP), waits for the
# healthcheck, requests the main endpoints and a local OGC schema through nginx, checks that the links
# use PYGEOAPI_SERVER_URL and that the geospatial modules use the GDAL and PROJ of the base image.
set -eu

IMAGE=${1:?usage: $0 <image>}
DOCKER=${DOCKER:-docker}
NAME=pygeoapi-smoke-$$
NGINX_IMAGE=docker.io/nginxinc/nginx-unprivileged:1.30-alpine
NGINX_CONF=$(cd "$(dirname "$0")/../../examples/nginx/conf/nginx" && pwd)/nginx.conf
SERVER_URL=http://smoke.test/pygeoapi

cleanup() {
    "$DOCKER" rm -f "$NAME" "$NAME-nginx" > /dev/null 2>&1 || :
    "$DOCKER" network rm "$NAME" > /dev/null 2>&1 || :
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    "$DOCKER" logs "$NAME" 2>&1 | tail -20 >&2 || :
    exit 1
}

# GET through nginx; prints the body
get() {
    "$DOCKER" exec "$NAME-nginx" wget -q -O - "http://127.0.0.1:8080$1"
}

[ "$("$DOCKER" image inspect "$IMAGE" --format '{{.Config.User}}')" = 1000:0 ] || fail "image user is not 1000:0"

echo "## container (--user 12345:0, --read-only) behind nginx"
"$DOCKER" network create "$NAME" > /dev/null
# network alias pygeoapi: the upstream of examples/nginx/conf/nginx/nginx.conf
"$DOCKER" run -d --name "$NAME" --network "$NAME" --network-alias pygeoapi \
    --user 12345:0 --read-only --tmpfs /tmp --tmpfs /var/lib/pygeoapi \
    -e PYGEOAPI_SERVER_URL="$SERVER_URL" "$IMAGE" > /dev/null
healthy=
for _ in $(seq 30); do
    if "$DOCKER" exec "$NAME" healthcheck > /dev/null 2>&1; then
        healthy=yes
        break
    fi
    sleep 2
done
[ -n "$healthy" ] || fail "healthcheck did not pass within 60 s"
"$DOCKER" exec "$NAME" healthcheck
"$DOCKER" run -d --name "$NAME-nginx" --network "$NAME" --read-only --tmpfs /tmp \
    -v "$NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" "$NGINX_IMAGE" > /dev/null
sleep 2

echo "## HTTP requests through nginx"
for path in '/?f=json' '/conformance?f=json' '/openapi?f=json' '/collections?f=json' '/?f=html' \
        '/schemas/ogcapi/features/part1/1.0/openapi/schemas/landingPage.yaml'; do
    body=$(get "$path") || fail "GET $path"
    echo "$path: $(printf '%s' "$body" | wc -c) bytes"
done
get '/?f=json' | grep -q "\"href\": *\"$SERVER_URL/conformance" || fail "links do not use PYGEOAPI_SERVER_URL ($SERVER_URL)"

echo "## native libraries"
"$DOCKER" exec -i "$NAME" python3 - << 'EOF' || fail "native libraries"
import sys

import pyproj
import rasterio
import shapely
from osgeo import gdal

# compiled from source against the base image (NO_BINARY): no bundled copies of the libraries
versions = {
    'GDAL (osgeo / rasterio)': (gdal.__version__, rasterio.__gdal_version__),
    'PROJ (rasterio / pyproj)': (rasterio.__proj_version__, pyproj.proj_version_str),
}
print('GEOS (shapely):', shapely.geos_version_string)
for name, (a, b) in versions.items():
    print(f'{name}: {a} / {b}')
    if a != b:
        sys.exit(f'{name} differ')
EOF

echo "OK"
