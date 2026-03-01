#!/bin/bash
set -eu

if [ -n "${KX_BUILD_DEBUG-}" ]; then
  echo "Enabling script debugging..."
  set -x
fi

export TIMEFORMAT='🕑 %1lR'

echo "--- Building PostgreSQL TopN extension"

# Get version from control file
TOPN_VERSION=$(grep default_version topn.control | cut -d"'" -f2)
PG_VERSION=16

# Add build number if in CI
if [ -n "${BUILDKITE_BUILD_NUMBER-}" ]; then
  DEB_VERSION="${TOPN_VERSION}+kx-ci${BUILDKITE_BUILD_NUMBER}"
else
  DEB_VERSION="${TOPN_VERSION}"
fi

echo "Building postgresql-${PG_VERSION}-topn version ${DEB_VERSION}"

# Annotate build with version info
if [ -n "${BUILDKITE_AGENT_ACCESS_TOKEN-}" ]; then
  buildkite-agent meta-data set topn-version "$TOPN_VERSION"
  buildkite-agent meta-data set deb-version "$DEB_VERSION"
  
  echo -e ":debian: TopN Package Version: \`${DEB_VERSION}\` for PostgreSQL ${PG_VERSION}" \
      | buildkite-agent annotate --style info --context deb-version
fi

BUILD_CONTAINER="build-topn-${BUILDKITE_JOB_ID:-local}"
STAGING_DIR="staging-topn"

echo "--- Building extension..."

# Build the extension in jammybuild container
time docker run \
  --name "${BUILD_CONTAINER}" \
  --rm \
  -v "$(pwd):/workspace" \
  -w "/workspace" \
  "${ECR}/jammybuild:master.latest" \
  bash -c "
    set -e
    echo 'Installing build dependencies...'
    apt-get update -qq
    apt-get install -y -qq postgresql-server-dev-${PG_VERSION} > /dev/null 2>&1
    
    echo 'Building extension...'
    make clean PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config || true
    make PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config
    
    echo 'Installing to staging directory...'
    rm -rf ${STAGING_DIR}
    mkdir -p ${STAGING_DIR}
    make install DESTDIR=${STAGING_DIR} PG_CONFIG=/usr/lib/postgresql/${PG_VERSION}/bin/pg_config
    
    echo 'Build complete'
  "

echo "--- Creating debian package..."

# Detect architecture
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
# Normalize architecture name
case "$ARCH" in
  x86_64|amd64)
    DEB_ARCH="amd64"
    ;;
  aarch64|arm64)
    DEB_ARCH="arm64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

echo "Building package for architecture: $DEB_ARCH"

# Create build directory
mkdir -p build-jammy

# Create the package using ci-tools which has fpm pre-installed
time docker run \
  --rm \
  -v "$(pwd):/workspace" \
  -w "/workspace" \
  "${ECR}/ci-tools:cds-ci-tools-upgrade.latest" \
  fpm -s dir -t deb \
    -n "postgresql-${PG_VERSION}-topn" \
    -v "${DEB_VERSION}" \
    -C "${STAGING_DIR}" \
    -p "build-jammy/postgresql-${PG_VERSION}-topn_${DEB_VERSION}_${DEB_ARCH}.deb" \
    --architecture "${DEB_ARCH}" \
    --description "PostgreSQL TopN extension for approximate top-N queries" \
    --url "https://github.com/citusdata/postgresql-topn" \
    --maintainer "Koordinates CI Builder <support@koordinates.com>" \
    --depends "postgresql-${PG_VERSION}" \
    .

# Clean up staging directory
rm -rf "${STAGING_DIR}"

echo "Package created successfully"
ls -la build-jammy/*.deb

echo "--- Signing debian package..."
if [ -n "${APT_GPG_KEY-}" ]; then
  # Sign packages using debsigs (available in ci-tools image)
  time docker run \
    -v "$(pwd):/src" \
    -e "GPG_KEY=${APT_GPG_KEY}" \
    -w "/src" \
    --entrypoint /bin/bash \
    "${ECR}/ci-tools:cds-ci-tools-upgrade.latest" \
    -c "echo \"\${GPG_KEY}\" | base64 -d | gpg -q --import - && \
        for deb in /src/build-jammy/*.deb; do \
          echo \"Signing \$deb...\"; \
          debsigs --sign=origin -k \$(gpg --list-secret-keys --with-colons | grep '^sec' | cut -d: -f5 | head -1) \$deb; \
        done"
else
  echo "No GPG key available, skipping signing"
fi

echo "--- Build complete"
ls -la build-jammy/*.deb