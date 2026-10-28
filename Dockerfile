# base images: ndscprm/gdal (Debian trixie + official Python + GDAL in /opt/geosgb)
ARG GDAL_VERSION=3.12.4
ARG PYTHON_VERSION=3.12
# dated tag of the base image (<YYYYMMDD>, or <YYYYMMDD>.N for a later build on
# the same day): the plain tags are rebuilt in place, the dated ones never are,
# and the devel and runtime images of a build share the same date. Changing it
# is a base image change: the update-locks workflow regenerates every lock
ARG BASE_DATE=20261026

# default pygeoapi version, also read by the CI workflow (keep this format)
ARG PYGEOAPI_VERSION=0.24.0

# SHA-256 of SCHEMAS_OPENGIS_NET.zip, updated by hand: the file has no version
# and changes in place on the server, so a new one fails the build until it is
# checked and this hash replaced (sha256sum of the downloaded zip).
# Current: Last-Modified Fri, 01 May 2026 13:52:22 GMT, 42634590 bytes
ARG OGC_SCHEMAS_SHA256=c9aa5c7af6a8eeba4c68bc58295f37444dedab6838d184cbb95d0f09f1d8a927


# OGC API schemas, served locally instead of fetched at runtime. The devel image
# already has wget/unzip (the runtime one does not) and is pulled for the wheels
# stage anyway; a separate stage keeps its cache apart and builds in parallel
FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel-${BASE_DATE} AS schemas

ARG OGC_SCHEMAS_SHA256

RUN wget -q https://schemas.opengis.net/SCHEMAS_OPENGIS_NET.zip && \
    if ! echo "${OGC_SCHEMAS_SHA256}  SCHEMAS_OPENGIS_NET.zip" | sha256sum -c --quiet -; then \
        echo "SCHEMAS_OPENGIS_NET.zip is $(sha256sum SCHEMAS_OPENGIS_NET.zip | cut -d' ' -f1)," \
            "expected ${OGC_SCHEMAS_SHA256}: check the new file and update" \
            "OGC_SCHEMAS_SHA256" >&2; \
        exit 1; \
    fi && \
    unzip -q SCHEMAS_OPENGIS_NET.zip "ogcapi/*" -d /schemas.opengis.net


# wheels for every Python dependency: the devel image has the compilers and
# -dev headers, so packages without a binary wheel (uWSGI) are built here, against
# the same Python and GDAL as the final stage; binary wheels are only downloaded
FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel-${BASE_DATE} AS wheels

ARG PYGEOAPI_VERSION

# LDFLAGS=-s strips what is compiled here, like the base image does for its
# runtime variant (the runtime image has no strip to do it afterwards)

# pygeoapi: requirements/pygeoapi/${PYGEOAPI_VERSION}.txt is the lock of that
# version (requirements/update-requirements.sh): it pins pygeoapi and its whole
# dependency tree, with the hashes of their PyPI files. It leaves out what the
# image already ships (GDAL, numpy...): the base image pins and hash-checks
# those, so --no-deps fetches only the lock and never downloads them again;
# they are constraints, so nothing can replace them, and the final pip install
# checks that the tree is complete.
# NO_BINARY packages are built from their sdist (hash-checked like the rest)
# against the image's own GDAL, PROJ and GEOS, instead of the PyPI wheels that
# bundle other copies of them (rasterio alone ships a whole GDAL). Their
# versions come from the lock, and every name has to be in it: a typo, or a
# package the pygeoapi version no longer depends on, stops the build. Tested
# with rasterio 1.5.2, pyproj 3.8.0 and shapely 2.2.0 on GDAL 3.12.4, PROJ
# 9.6.0 and GEOS 3.13.1 (rasterio needs GDAL >= 3.8, pyproj PROJ >= 9.4).
# pyproj looks for the proj executable, which the devel image does not have
# (only the libproj-dev headers): PROJ_DIR and PROJ_VERSION, from pkg-config,
# replace it.
# Build dependencies are pinned with --build-constraint, since -c only reaches
# the packages being installed, not the isolated environments their sdists are
# built in: to the base image's versions (numpy, setuptools...), and to
# requirements/build-no-binary/${PYGEOAPI_VERSION}.txt, the lock of everything
# those environments install (Cython, meson, ninja...), with hashes, which pip
# checks when it downloads them. That lock is generated for the NO_BINARY default
# below: with another NO_BINARY, regenerate it, or a build dependency may go
# unpinned
ARG NO_BINARY=rasterio,pyproj,shapely

RUN --mount=type=bind,source=requirements,target=/tmp/requirements \
    lock=/tmp/requirements/pygeoapi/${PYGEOAPI_VERSION}.txt && \
    if [ ! -f "$lock" ]; then \
        echo "no lock file for pygeoapi ${PYGEOAPI_VERSION}:" \
            "run requirements/update-requirements.sh ${PYGEOAPI_VERSION}" >&2; \
        exit 1; \
    fi && \
    if [ ! -f /tmp/requirements/build-no-binary/${PYGEOAPI_VERSION}.txt ]; then \
        echo "no build lock for pygeoapi ${PYGEOAPI_VERSION}:" \
            "run requirements/update-requirements.sh ${PYGEOAPI_VERSION}" >&2; \
        exit 1; \
    fi && \
    for name in $(echo "${NO_BINARY}" | tr ',' ' '); do \
        if ! spec=$(grep -io "^${name}==[^ ]*" "$lock"); then \
            echo "${name} (NO_BINARY) is not in the lock of pygeoapi" \
                "${PYGEOAPI_VERSION}: fix the name or remove it from NO_BINARY" >&2; \
            exit 1; \
        fi; \
        echo "building ${spec} from its sdist"; \
    done && \
    pip freeze --all > /tmp/base-constraints.txt && \
    PROJ_DIR=/usr PROJ_VERSION=$(pkg-config --modversion proj) \
    LDFLAGS=-s pip wheel --no-cache-dir --use-pep517 --wheel-dir /wheels \
        --require-hashes --no-deps --no-binary "${NO_BINARY}" \
        -c /tmp/base-constraints.txt --build-constraint /tmp/base-constraints.txt \
        --build-constraint /tmp/requirements/build-no-binary/${PYGEOAPI_VERSION}.txt \
        -r "$lock"

# extras, in a layer of their own: requirements/extra/${PYGEOAPI_VERSION}.txt is
# their lock for this pygeoapi version (generated from requirements.in with the
# pygeoapi lock), hash-checked like the pygeoapi one. It leaves out what the
# pygeoapi lock already has, so --no-deps fetches only the packages the extras
# add and never the shared ones again. The pygeoapi lock goes in as
# constraints, without its hashes (they would turn on hash-checking for
# packages this step does not fetch), so an extra cannot move any of its
# versions
RUN --mount=type=bind,source=requirements,target=/tmp/requirements \
    lock=/tmp/requirements/extra/${PYGEOAPI_VERSION}.txt && \
    if [ ! -f "$lock" ]; then \
        echo "no extras lock for pygeoapi ${PYGEOAPI_VERSION}:" \
            "run requirements/update-requirements.sh ${PYGEOAPI_VERSION}" >&2; \
        exit 1; \
    fi && \
    pip freeze --all > /tmp/base-constraints.txt && \
    sed -n 's/^\([^ #][^ ]*==[^ ]*\).*/\1/p' \
        /tmp/requirements/pygeoapi/${PYGEOAPI_VERSION}.txt \
        > /tmp/pygeoapi-constraints.txt && \
    LDFLAGS=-s pip wheel --no-cache-dir --use-pep517 --wheel-dir /wheels \
        --require-hashes --no-deps \
        -c /tmp/base-constraints.txt -c /tmp/pygeoapi-constraints.txt \
        --build-constraint /tmp/base-constraints.txt \
        --build-constraint /tmp/requirements/build-no-binary/${PYGEOAPI_VERSION}.txt \
        -r "$lock"


FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-${BASE_DATE}

ARG PYGEOAPI_VERSION

# installs from the wheels stage only (no index): pygeoapi first, constrained to
# this image's own packages; then the extras, constrained to everything already
# installed, so they can only add packages, never change one. Both resolve
# their dependencies, so an incomplete lock fails here. Hashes were checked
# when the wheels stage downloaded each file; they are stripped here, since the
# wheels built from source there (NO_BINARY, uWSGI) have no PyPI hash to match
RUN --mount=type=bind,source=requirements,target=/tmp/requirements \
    --mount=type=bind,from=wheels,source=/wheels,target=/wheels \
    pip freeze --all > /tmp/base-constraints.txt && \
    sed -n 's/^\([^ #][^ ]*==[^ ]*\).*/\1/p' \
        /tmp/requirements/pygeoapi/${PYGEOAPI_VERSION}.txt \
        > /tmp/pygeoapi-requirements.txt && \
    pip install --no-cache-dir --no-index --find-links /wheels \
        -c /tmp/base-constraints.txt -r /tmp/pygeoapi-requirements.txt

RUN --mount=type=bind,source=requirements,target=/tmp/requirements \
    --mount=type=bind,from=wheels,source=/wheels,target=/wheels \
    pip freeze --all > /tmp/installed-constraints.txt && \
    sed -n 's/^\([^ #][^ ]*==[^ ]*\).*/\1/p' \
        /tmp/requirements/extra/${PYGEOAPI_VERSION}.txt > /tmp/extra-requirements.txt && \
    pip install --no-cache-dir --no-index --find-links /wheels \
        -c /tmp/installed-constraints.txt -r /tmp/extra-requirements.txt

# pyproj built from source has no PROJ data of its own and, unlike libproj
# (which osgeo and rasterio use), does not look in /usr/share/proj by default;
# point it at the proj-data package the base image ships
ENV PROJ_DATA=/usr/share/proj

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

# unprivileged by default. UID 1000 is not in /etc/passwd on purpose: the base
# image's 10-enable-nss-wrapper.sh creates a virtual user for it at start
# (USER_NAME, default sgb; HOME=/tmp), as it does for the arbitrary UIDs
# OpenShift assigns. Group 0 is the one that can write /var/lib/pygeoapi
USER 1000:0

# uwsgi protocol, not HTTP: put nginx (uwsgi_pass) in front, see examples/.
# The port is set only here: uwsgi.conf and the healthcheck read
# PYGEOAPI_LISTEN_PORT, which can also be changed at run time; nginx (the
# upstream in examples/) has to point at the same one. Not PYGEOAPI_PORT:
# Kubernetes sets that one to tcp://<ip>:<port> in every pod of a namespace
# with a Service named pygeoapi
ARG PYGEOAPI_LISTEN_PORT=8000
ENV PYGEOAPI_LISTEN_PORT=${PYGEOAPI_LISTEN_PORT}
EXPOSE ${PYGEOAPI_LISTEN_PORT}

# uWSGI ping (uwsgi protocol), answered by a worker: fails if no worker is
# serving. Only applied by Docker: Podman ignores it in OCI images and
# Kubernetes/OpenShift never use it, so Compose, podman --health-cmd and
# probes call the same script
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD [ "healthcheck" ]

# ENTRYPOINT inherited from the base image (/docker-entrypoint.sh): runs the
# /docker-entrypoint.d scripts, then the CMD
CMD [ "uwsgi", "--ini", "/var/lib/uwsgi/uwsgi.conf" ]
