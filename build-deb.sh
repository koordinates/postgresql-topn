#!/bin/bash
set -e

# PostgreSQL version to build for (can be overridden)
PG_VERSION=${1:-16}

# Package info from control file
VERSION=$(grep default_version topn.control | cut -d"'" -f2)
PACKAGE_NAME="postgresql-${PG_VERSION}-topn"

echo "Building ${PACKAGE_NAME} version ${VERSION} for PostgreSQL ${PG_VERSION}"

# Find pg_config
PG_CONFIG="/usr/lib/postgresql/${PG_VERSION}/bin/pg_config"
if [ ! -f "$PG_CONFIG" ]; then
    echo "Error: PostgreSQL ${PG_VERSION} not found at $PG_CONFIG"
    exit 1
fi

# Clean and build
make clean PG_CONFIG="$PG_CONFIG" || true
make PG_CONFIG="$PG_CONFIG"

# Install to temporary directory
TEMPDIR=$(mktemp -d)
make install DESTDIR="$TEMPDIR" PG_CONFIG="$PG_CONFIG"

# Create debian package with fpm
fpm -s dir -t deb \
    -n "$PACKAGE_NAME" \
    -v "$VERSION" \
    -C "$TEMPDIR" \
    -p "${PACKAGE_NAME}_${VERSION}_amd64.deb" \
    --description "PostgreSQL TopN extension for approximate top-N queries" \
    --url "https://github.com/citusdata/postgresql-topn" \
    --depends "postgresql-${PG_VERSION}" \
    .

# Cleanup
rm -rf "$TEMPDIR"

echo "Package created: ${PACKAGE_NAME}_${VERSION}_amd64.deb"