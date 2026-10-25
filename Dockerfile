# base images: ndscprm/gdal (Debian trixie + official Python + GDAL in /opt/geosgb)
ARG GDAL_VERSION=3.12.4
ARG PYTHON_VERSION=3.12

# default MapProxy version, also read by the CI workflow (keep this format)
ARG PYGEOAPI_VERSION=0.24.0
# ARG MAPPROXY_BASE_DIR=/var/lib/mapproxy


# OGC API schemas, served locally instead of fetched at runtime. The base image
# has no wget/unzip; they are installed here only, since this stage is discarded
FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION} AS schemas

RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
        ca-certificates unzip wget && \
    wget -q https://schemas.opengis.net/SCHEMAS_OPENGIS_NET.zip && \
    unzip -q SCHEMAS_OPENGIS_NET.zip "ogcapi/*" -d /schemas.opengis.net


FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}

ARG PYGEOAPI_VERSION

# WORKDIR ${MAPPROXY_BASE_DIR}

# # envsubst (the devel image already has the compilers and -dev headers)
# RUN apt-get update && \
#     apt-get install --yes --no-install-recommends --no-install-suggests \
#         gettext-base && \
#     rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,source=requirements.txt,target=/tmp/requirements.txt \
    pip install --no-cache-dir --use-pep517  -c /tmp/requirements.txt  -r /tmp/requirements.txt && \
    pip install --no-cache-dir "pygeoapi==${PYGEOAPI_VERSION}"

COPY --from=schemas /schemas.opengis.net /schemas.opengis.net

# EXPOSE 8000

# # uWSGI ping (uwsgi protocol), answered by a worker: fails if no worker is
# # serving. Only applied by Docker: Podman ignores it in OCI images and
# # Kubernetes never uses it, so Compose, Quadlet and probes call the same script
# HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
#     CMD [ "healthcheck" ]

# # ENTRYPOINT inherited from the base image (/docker-entrypoint.sh): runs the
# # /docker-entrypoint.d scripts, then the CMD
# CMD [ "uwsgi", "--ini", "/var/lib/uwsgi/uwsgi.conf" ]
