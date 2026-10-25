# base images: ndscprm/gdal (Debian trixie + official Python + GDAL in /opt/geosgb)
ARG GDAL_VERSION=3.12.4
ARG PYTHON_VERSION=3.12

# default pygeoapi version, also read by the CI workflow (keep this format)
ARG PYGEOAPI_VERSION=0.24.0


# OGC API schemas, served locally instead of fetched at runtime. The devel image
# already has wget/unzip (the runtime one does not) and is pulled for the wheels
# stage anyway; a separate stage keeps its cache apart and builds in parallel
FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel AS schemas

RUN wget -q https://schemas.opengis.net/SCHEMAS_OPENGIS_NET.zip && \
    unzip -q SCHEMAS_OPENGIS_NET.zip "ogcapi/*" -d /schemas.opengis.net


# wheels for every Python dependency: the devel image has the compilers and
# -dev headers, so packages without a binary wheel (uWSGI) are built here, against
# the same Python and GDAL as the final stage; binary wheels are only downloaded
FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel AS wheels

ARG PYGEOAPI_VERSION

# LDFLAGS=-s strips what is compiled here, like the base image does for its
# runtime variant (the runtime image has no strip to do it afterwards)

# pygeoapi: requirements/pygeoapi-${PYGEOAPI_VERSION}.txt is the lock of that
# version (scripts/update-requirements.sh): it pins pygeoapi and its whole
# dependency tree, with the hashes of their PyPI files. It leaves out what the
# image already ships (GDAL, numpy...): the base image pins and hash-checks
# those, so --no-deps fetches only the lock and never downloads them again;
# they are constraints, so nothing can replace them, and the final pip install
# checks that the tree is complete
RUN --mount=type=bind,source=requirements,target=/tmp/requirements \
    lock=/tmp/requirements/pygeoapi-${PYGEOAPI_VERSION}.txt && \
    if [ ! -f "$lock" ]; then \
        echo "no lock file for pygeoapi ${PYGEOAPI_VERSION}:" \
            "run scripts/update-requirements.sh ${PYGEOAPI_VERSION}" >&2; \
        exit 1; \
    fi && \
    pip freeze --all > /tmp/base-constraints.txt && \
    LDFLAGS=-s pip wheel --no-cache-dir --use-pep517 --wheel-dir /wheels \
        --require-hashes --no-deps -c /tmp/base-constraints.txt -r "$lock"

# extras, in a layer of their own: also constrained to the versions in the
# lock, so they cannot move any pygeoapi dependency. Its hashes are stripped
# first: in a constraints file they would turn hash-checking on for the extras
# too, which have none yet
RUN --mount=type=bind,source=requirements,target=/tmp/requirements \
    --mount=type=bind,source=requirements-extra.txt,target=/tmp/requirements-extra.txt \
    pip freeze --all > /tmp/base-constraints.txt && \
    sed -n 's/^\([^ #][^ ]*==[^ ]*\).*/\1/p' \
        /tmp/requirements/pygeoapi-${PYGEOAPI_VERSION}.txt \
        > /tmp/pygeoapi-constraints.txt && \
    LDFLAGS=-s pip wheel --no-cache-dir --use-pep517 --wheel-dir /wheels \
        -c /tmp/base-constraints.txt -c /tmp/pygeoapi-constraints.txt \
        -r /tmp/requirements-extra.txt


FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}

ARG PYGEOAPI_VERSION

# installs from the wheels stage only (no index): pygeoapi first, constrained to
# this image's own packages and checked again against the hashes (the wheels
# stage keeps the PyPI files as they are); then the extras, constrained to
# everything already installed, so they can only add packages, never change one
RUN --mount=type=bind,source=requirements,target=/tmp/requirements \
    --mount=type=bind,from=wheels,source=/wheels,target=/wheels \
    pip freeze --all > /tmp/base-constraints.txt && \
    pip install --no-cache-dir --no-index --find-links /wheels \
        --require-hashes -c /tmp/base-constraints.txt \
        -r /tmp/requirements/pygeoapi-${PYGEOAPI_VERSION}.txt

RUN --mount=type=bind,source=requirements-extra.txt,target=/tmp/requirements-extra.txt \
    --mount=type=bind,from=wheels,source=/wheels,target=/wheels \
    pip freeze --all > /tmp/installed-constraints.txt && \
    pip install --no-cache-dir --no-index --find-links /wheels \
        -c /tmp/installed-constraints.txt -r /tmp/requirements-extra.txt

COPY --from=schemas /schemas.opengis.net /schemas.opengis.net

# the OpenAPI document is generated on every start (docker-entrypoint.d), so its
# directory is writable by group 0, which arbitrary UIDs (OpenShift) belong to
ENV PYGEOAPI_CONFIG=/etc/pygeoapi/config.yml \
    PYGEOAPI_OPENAPI=/var/lib/pygeoapi/openapi.yml

COPY conf/pygeoapi-config.yml ${PYGEOAPI_CONFIG}
COPY conf/uwsgi.conf /var/lib/uwsgi/uwsgi.conf
COPY --chmod=755 docker-entrypoint.d/ /docker-entrypoint.d/
COPY --chmod=755 docker/healthcheck /usr/local/bin/healthcheck

RUN mkdir -p /var/lib/pygeoapi && \
    chgrp 0 /var/lib/pygeoapi && \
    chmod g=u /var/lib/pygeoapi

EXPOSE 8000

# HTTP GET on the landing page, answered by a uWSGI worker: fails if no worker
# is serving. Only applied by Docker: Podman ignores it in OCI images and
# Kubernetes never uses it, so Compose, Quadlet and probes call the same script
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD [ "healthcheck" ]

# ENTRYPOINT inherited from the base image (/docker-entrypoint.sh): runs the
# /docker-entrypoint.d scripts, then the CMD
CMD [ "uwsgi", "--ini", "/var/lib/uwsgi/uwsgi.conf" ]
