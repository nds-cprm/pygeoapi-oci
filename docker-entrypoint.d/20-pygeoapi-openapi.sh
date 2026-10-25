#!/bin/sh
# Generates the OpenAPI document from the current configuration on every start,
# so that a mounted or changed PYGEOAPI_CONFIG is always reflected in it
set -e

pygeoapi openapi generate "$PYGEOAPI_CONFIG" --output-file "$PYGEOAPI_OPENAPI"
