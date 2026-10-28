#!/bin/sh
# Generates the lock files the build installs from, with every package pinned to
# the version resolved now and the SHA-256 of its PyPI files, so the build runs
# pip in hash-checking mode:
#
#   - requirements/pygeoapi/<version>.txt: pygeoapi and its whole dependency
#     tree. The build picks the file by PYGEOAPI_VERSION; each version keeps its
#     own, so locking a new version never changes what an existing one installs.
#   - requirements/extra/requirements.txt (argument "extra"): the extras listed
#     by hand in requirements/extra/requirements.in and the dependencies only
#     they pull in. Resolved constrained to the lock of the default
#     PYGEOAPI_VERSION; what that lock already has is left out, so the extras
#     can only add packages. The file is shared by every pygeoapi version.
#
#   requirements/update-requirements.sh                         # PYGEOAPI_VERSION from the Dockerfile
#   requirements/update-requirements.sh 0.25.0                  # one or more versions
#   requirements/update-requirements.sh requirements/pygeoapi/*  # every existing lock (after a base image change)
#   requirements/update-requirements.sh extra                   # the extras (after editing requirements.in)
#
# Paths are accepted only when the file name is <version>.txt (it starts with a
# digit); any other file is skipped with a message.
#
# Commit the result. After a new default PYGEOAPI_VERSION or a base image
# change, regenerate the extras too (last, since they depend on that lock).
#
# Resolves inside the same -devel image as the wheels stage, with the base image
# versions and date read from the Dockerfile ARG defaults, and with the packages
# that image ships (GDAL, numpy, pyarrow, pip...) as constraints, as the build
# does.
# Those packages are left out: the base image already pins and hash-checks them,
# and the build fetches the locks with --no-deps, so it never downloads them
# again.
#
# Hashes cover the sdist and the wheels this image can install: pure Python, or
# built for its Python version (or the stable abi3) on glibc Linux (manylinux),
# for any architecture, so the same file works for amd64 and arm64 builds.
#
# CONTAINER_ENGINE selects podman or docker (default: podman if installed).
set -eu

cd "$(dirname "$0")/.."

arg() {
    sed -n "s/^ARG $1=//p" Dockerfile
}

# name==version lines of a lock, without the hashes
pins() {
    sed -n 's/^\([^ #][^ ]*==[^ ]*\).*/\1/p' "$1"
}

GDAL_VERSION=$(arg GDAL_VERSION)
PYTHON_VERSION=$(arg PYTHON_VERSION)
BASE_DATE=$(arg BASE_DATE)
IMAGE=docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel-${BASE_DATE}

if [ -z "${CONTAINER_ENGINE:-}" ]; then
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_ENGINE=podman
    else
        CONTAINER_ENGINE=docker
    fi
fi

# resolve <requirements> <constraints>: prints, with their hashes, the packages
# pip would install for the requirements (file contents), minus those the image
# ships and those in the constraints (name==version lines), which also bind the
# resolution
resolve() {
    # the hashing helper goes in through stdin and the files through the
    # environment: no bind mount, so no SELinux relabeling or shared-folder
    # setup (podman machine, Docker Desktop) is needed
    "$CONTAINER_ENGINE" run --rm -i --entrypoint sh \
        -e REQUIREMENTS="$1" -e CONSTRAINTS="$2" -e PYTHON_VERSION="$PYTHON_VERSION" \
        "$IMAGE" -c '
            set -e
            cat > /tmp/hashes.py
            printf "%s\n" "$REQUIREMENTS" > /tmp/requirements.txt
            printf "%s\n" "$CONSTRAINTS" > /tmp/constraints.txt
            pip freeze --all > /tmp/base-constraints.txt
            pip install --quiet --no-cache-dir --dry-run --ignore-installed \
                --report /tmp/report.json -c /tmp/base-constraints.txt \
                -c /tmp/constraints.txt -r /tmp/requirements.txt >&2
            python3 /tmp/hashes.py /tmp/report.json /tmp/base-constraints.txt \
                /tmp/constraints.txt
        ' <<'EOF'
import json
import os
import re
import sys
import urllib.request


def normalize(name):
    return re.sub(r'[-_.]+', '-', name).lower()


excluded = {
    normalize(line.split('==')[0])
    for path in sys.argv[2:]
    for line in open(path)
    if '==' in line
}
report = json.load(open(sys.argv[1]))
packages = sorted(
    (item['metadata']['name'], item['metadata']['version'])
    for item in report['install']
    if normalize(item['metadata']['name']) not in excluded
)
cpython = 'cp' + os.environ['PYTHON_VERSION'].replace('.', '')


def wanted(filename):
    # wheel name: {name}-{version}(-{build})?-{python}-{abi}-{platform}.whl
    if not filename.endswith('.whl'):
        return True
    python, abi, platform = filename[:-4].split('-')[-3:]
    pythons = python.split('.')
    platforms = platform.split('.')
    if platform != 'any' and not any(
        p.startswith('manylinux') or p.startswith('linux_') for p in platforms
    ):
        return False
    return cpython in pythons or abi == 'abi3' or any(p.startswith('py') for p in pythons)


for name, version in sorted(packages, key=lambda p: p[0].lower()):
    url = f'https://pypi.org/pypi/{name}/{version}/json'
    with urllib.request.urlopen(url, timeout=30) as response:
        files = json.load(response)['urls']
    hashes = sorted({f['digests']['sha256'] for f in files if wanted(f['filename'])})
    if not hashes:
        sys.exit(f'no files with hashes for {name}=={version}')
    lines = [f'{name}=={version}'] + [f'    --hash=sha256:{h}' for h in hashes]
    print(' \\\n'.join(lines))
EOF
}

# write <output> <description>: stdin, under a header
write() {
    {
        echo "# generated by requirements/update-requirements.sh, do not edit"
        echo "# $2 on $IMAGE"
        cat
    } > "$1.new"
    mv "$1.new" "$1"
    echo "$1: $(grep -c '==' "$1") packages, $(grep -c -- '--hash=' "$1") hashes" >&2
}

lock() {
    version=$1
    echo "resolving pygeoapi $version with $IMAGE" >&2
    resolve "pygeoapi==$version" "" > requirements/pygeoapi/$version.txt.out
    write requirements/pygeoapi/$version.txt "pygeoapi $version and its dependencies" \
        < requirements/pygeoapi/$version.txt.out
    rm -f requirements/pygeoapi/$version.txt.out
}

lock_extra() {
    version=$(arg PYGEOAPI_VERSION)
    base_lock=requirements/pygeoapi/$version.txt
    if [ ! -f "$base_lock" ]; then
        echo "no lock file for pygeoapi $version: generate it first" >&2
        exit 1
    fi
    echo "resolving requirements/extra/requirements.in with $IMAGE" \
        "and the lock of pygeoapi $version" >&2
    output=requirements/extra/requirements.txt
    resolve "$(cat requirements/extra/requirements.in)" "$(pins "$base_lock")" > "$output.out"
    write "$output" "extras (requirements.in) and the dependencies only they pull in, besides pygeoapi $version," \
        < "$output.out"
    rm -f "$output.out"
}

mkdir -p requirements/pygeoapi

if [ $# -eq 0 ]; then
    set -- "$(arg PYGEOAPI_VERSION)"
fi

for version in "$@"; do
    # also accepts lock file paths (requirements/pygeoapi/0.24.0.txt -> 0.24.0);
    # any other file, such as requirements/extra/requirements.txt, is skipped, so
    # globs over requirements/ are safe too
    case $version in
        extra)
            lock_extra
            continue
            ;;
        */*|*.txt)
            case ${version##*/} in
                [0-9]*.txt)
                    version=${version##*/}
                    version=${version%.txt}
                    ;;
                *)
                    echo "skipping $version: not a <version>.txt lock" >&2
                    continue
                    ;;
            esac
            ;;
    esac
    lock "$version"
done
