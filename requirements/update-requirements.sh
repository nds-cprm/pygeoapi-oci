#!/bin/sh
# Generates the lock files the build installs from, three per pygeoapi version,
# with every package pinned to the version resolved now and the SHA-256 of its
# PyPI files, so the build runs pip in hash-checking mode:
#
#   - requirements/pygeoapi/<version>.txt: pygeoapi and its whole dependency
#     tree.
#   - requirements/extra/<version>.txt: the extras listed by hand in
#     requirements/extra/requirements.in and the dependencies only they pull
#     in, resolved constrained to the pygeoapi lock of the same version; what
#     that lock already has is left out, so the extras can only add packages.
#   - requirements/build-no-binary/<version>.txt: the build dependencies
#     (Cython, meson, ninja...) of the sdists the wheels stage compiles: the NO_BINARY packages
#     and those with no wheel at all (uWSGI). Taken from what pip installs into
#     their isolated build environments while preparing their metadata,
#     including what the base image also ships (numpy, setuptools), which is
#     downloaded again into each build environment. The build passes it as a
#     --build-constraint: the build environments get these versions, and pip
#     checks the hashes of what it downloads into them.
#
# The build picks the files by PYGEOAPI_VERSION; each version keeps its own, so
# locking a new version never changes what an existing one installs.
#
#   requirements/update-requirements.sh                                  # PYGEOAPI_VERSION from the Dockerfile
#   requirements/update-requirements.sh 0.25.0                           # one or more versions
#   requirements/update-requirements.sh requirements/pygeoapi/*          # every existing version (after a base image change)
#   requirements/update-requirements.sh --extra 0.24.0                   # only the extras and build locks (after editing requirements.in)
#   requirements/update-requirements.sh --extra requirements/pygeoapi/*  # the same, for every version
#
# Paths are accepted only when the file name is <version>.txt (it starts with a
# digit); any other file is skipped with a message. --extra takes the versions
# the same way and leaves their pygeoapi locks untouched, which must exist; it
# regenerates the build lock too, since the extras may add sdists (uWSGI).
#
# Commit the result.
#
# Resolves inside the same -devel image as the wheels stage, with the base image
# versions and date and NO_BINARY read from the Dockerfile ARG defaults, and
# with the packages that image ships (GDAL, numpy, pyarrow, pip...) as
# constraints, as the build does.
# Those packages are left out of the pygeoapi and extras locks: the base image
# already pins and hash-checks them, and the build fetches the locks with
# --no-deps, so it never downloads them again.
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
NO_BINARY=$(arg NO_BINARY)
IMAGE=docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel-${BASE_DATE}

if [ -z "${CONTAINER_ENGINE:-}" ]; then
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_ENGINE=podman
    else
        CONTAINER_ENGINE=docker
    fi
fi

# resolve <requirements> <constraints> [keep-base]: prints, with their hashes,
# the packages pip would install for the requirements (file contents), minus
# those the image ships (unless keep-base is given) and those in the
# constraints (name==version lines), which also bind the resolution
resolve() {
    # the helpers go in through stdin and the files through the environment:
    # no bind mount, so no SELinux relabeling or shared-folder setup (podman
    # machine, Docker Desktop) is needed
    "$CONTAINER_ENGINE" run --rm -i --entrypoint sh \
        -e REQUIREMENTS="$1" -e CONSTRAINTS="$2" -e KEEP_BASE="${3:-}" \
        -e PYTHON_VERSION="$PYTHON_VERSION" \
        "$IMAGE" -c '
            set -e
            cat > /tmp/hashes.py
            printf "%s\n" "$REQUIREMENTS" > /tmp/requirements.txt
            printf "%s\n" "$CONSTRAINTS" > /tmp/constraints.txt
            pip freeze --all > /tmp/base-constraints.txt
            if [ -n "$KEEP_BASE" ]; then
                : > /tmp/excluded.txt
            else
                cp /tmp/base-constraints.txt /tmp/excluded.txt
            fi
            pip install --quiet --no-cache-dir --dry-run --ignore-installed \
                --report /tmp/report.json -c /tmp/base-constraints.txt \
                -c /tmp/constraints.txt -r /tmp/requirements.txt >&2
            python3 /tmp/hashes.py /tmp/report.json /tmp/excluded.txt \
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

# build_requirements <requirements>: prints name==version of everything pip
# installs into the build environments of the sdists among the requirements
# (pinned lines, fetched with --no-deps), NO_BINARY ones included, while it
# prepares their metadata (pip -v logs each "Successfully installed"), with the
# same environment and constraints as the wheels stage
build_requirements() {
    "$CONTAINER_ENGINE" run --rm -i --entrypoint sh \
        -e REQUIREMENTS="$1" -e NO_BINARY="$NO_BINARY" \
        "$IMAGE" -c '
            set -e
            cat > /tmp/installed.py
            printf "%s\n" "$REQUIREMENTS" > /tmp/requirements.txt
            pip freeze --all > /tmp/base-constraints.txt
            if ! PROJ_DIR=/usr PROJ_VERSION=$(pkg-config --modversion proj) \
                pip install -v --no-cache-dir --dry-run --ignore-installed \
                    --no-deps --no-binary "$NO_BINARY" \
                    -c /tmp/base-constraints.txt \
                    --build-constraint /tmp/base-constraints.txt \
                    -r /tmp/requirements.txt > /tmp/pip.log 2>&1; then
                tail -40 /tmp/pip.log >&2
                exit 1
            fi
            python3 /tmp/installed.py /tmp/pip.log
        ' <<'EOF'
import re
import sys

versions = {}
for line in open(sys.argv[1]):
    match = re.match(r'\s+Successfully installed (.*)', line)
    for package in match.group(1).split() if match else ():
        name, version = package.rsplit('-', 1)
        key = re.sub(r'[-_.]+', '-', name).lower()
        if versions.setdefault(key, (name, version))[1] != version:
            sys.exit(f'{name}: build environments need both {versions[key][1]} and {version}')
if not versions:
    sys.exit('no build environment found: nothing is built from source?')
for name, version in sorted(versions.values(), key=lambda p: p[0].lower()):
    print(f'{name}=={version}')
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

# lock <version>: the pygeoapi lock of that version, then its extras and build
# locks
lock() {
    version=$1
    output=requirements/pygeoapi/$version.txt
    echo "resolving pygeoapi $version with $IMAGE" >&2
    resolve "pygeoapi==$version" "" > "$output.out"
    write "$output" "pygeoapi $version and its dependencies" < "$output.out"
    rm -f "$output.out"
    lock_extra "$version"
}

# lock_extra <version>: the extras lock of a version whose pygeoapi lock
# exists, then its build lock
lock_extra() {
    version=$1
    output=requirements/extra/$version.txt
    echo "resolving requirements/extra/requirements.in with $IMAGE" \
        "and the lock of pygeoapi $version" >&2
    resolve "$(cat requirements/extra/requirements.in)" \
        "$(pins "requirements/pygeoapi/$version.txt")" > "$output.out"
    write "$output" "extras (requirements.in) and the dependencies only they pull in, besides pygeoapi $version," \
        < "$output.out"
    rm -f "$output.out"
    lock_build "$version"
}

# lock_build <version>: the build lock of a version whose pygeoapi and extras
# locks exist
lock_build() {
    version=$1
    output=requirements/build-no-binary/$version.txt
    echo "finding the build dependencies of the sdists of pygeoapi $version" \
        "(NO_BINARY=$NO_BINARY and sdist-only packages) with $IMAGE" >&2
    requirements=$(build_requirements "$(pins "requirements/pygeoapi/$version.txt")
$(pins "requirements/extra/$version.txt")")
    echo "build dependencies:" $requirements >&2
    resolve "$requirements" "" keep-base > "$output.out"
    write "$output" "build dependencies of the sdists compiled for pygeoapi $version (NO_BINARY=$NO_BINARY and sdist-only packages)," \
        < "$output.out"
    rm -f "$output.out"
}

mkdir -p requirements/pygeoapi requirements/extra requirements/build-no-binary

# --extra, anywhere in the arguments: only the extras and build locks
extra_only=
for argument in "$@"; do
    shift
    case $argument in
        --extra) extra_only=yes ;;
        -*)
            echo "unknown option $argument" >&2
            exit 1
            ;;
        *) set -- "$@" "$argument" ;;
    esac
done

if [ $# -eq 0 ]; then
    set -- "$(arg PYGEOAPI_VERSION)"
fi

for version in "$@"; do
    # also accepts lock file paths (requirements/pygeoapi/0.24.0.txt -> 0.24.0);
    # any other file, such as requirements/extra/requirements.in, is skipped, so
    # globs over requirements/ are safe too
    case $version in
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
    if [ -z "$extra_only" ]; then
        lock "$version"
    elif [ -f "requirements/pygeoapi/$version.txt" ]; then
        lock_extra "$version"
    else
        echo "no lock file for pygeoapi $version: run" \
            "requirements/update-requirements.sh $version first" >&2
        exit 1
    fi
done
