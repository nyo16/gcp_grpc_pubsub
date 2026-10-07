#!/bin/sh
# Script to update Google API protobuf files for Elixir
# Original inspiration from https://github.com/cjab/weddell/blob/master/bin/update-proto
#
# Every input is pinned so regeneration is reproducible:
#   - protoc release + per-platform SHA-256 (from the GitHub release assets)
#   - googleapis commit
#   - protoc-gen-elixir (hex package `protobuf`); keep it compatible with the
#     `protobuf` runtime in mix.lock (grpc_core requires `~> 0.17`)

set -e  # Exit on any error

PROTOC_VERSION="32.0"
GOOGLEAPIS_REF="3acfdb6166a7101691cdf812bf8f8a67a2084fde"
PROTOBUF_VERSION="0.17.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo "${RED}[ERROR]${NC} $1"; }

DIR="$( cd "$( dirname "$0" )" && pwd )"
TMP_DIR="$DIR/staging_folder"
echo_info "Working directory: $DIR"
echo_info "Staging directory: $TMP_DIR"

# protoc-gen-elixir names files <package dir>/<proto path>.pb.ex
# (google/pubsub/v1/google/pubsub/v1/pubsub.pb.ex), so generate into staging and copy
# the files flat into lib/google/pubsub/v1/. Only lib/google/ is ever replaced.
GEN_DIR="$TMP_DIR/generated"
OUT="$DIR/lib/google"
GOOGLEAPIS_PATH="$TMP_DIR/googleapis"
PROTOC_PATH="$TMP_DIR/protoc-$PROTOC_VERSION"
PROTOC="$PROTOC_PATH/bin/protoc"
# Isolated MIX_HOME so the pinned plugin never clashes with (or overwrites) a global install.
PLUGIN_MIX_HOME="$TMP_DIR/mix"
PLUGIN_PATH="$PLUGIN_MIX_HOME/escripts/protoc-gen-elixir"

# Detect platform and set the matching protoc asset + checksum
PLATFORM=$(uname -s)
ARCH=$(uname -m)

case "$PLATFORM-$ARCH" in
    Darwin-arm64)
        PROTOC_ASSET="protoc-$PROTOC_VERSION-osx-aarch_64.zip"
        PROTOC_SHA256="09a2c729cc821215cc0d4c564b761760961fe338c52f24b302fd7e18e7b675d1"
        ;;
    Darwin-x86_64)
        PROTOC_ASSET="protoc-$PROTOC_VERSION-osx-x86_64.zip"
        PROTOC_SHA256="63eeba15ddc12ab11b0a8bce81fb2d46cc69022c3e6ad21fecde90d52139bff6"
        ;;
    Linux-x86_64)
        PROTOC_ASSET="protoc-$PROTOC_VERSION-linux-x86_64.zip"
        PROTOC_SHA256="7ca037bfe5e5cabd4255ccd21dd265f79eb82d3c010117994f5dc81d2140ee88"
        ;;
    Linux-aarch64|Linux-arm64)
        PROTOC_ASSET="protoc-$PROTOC_VERSION-linux-aarch_64.zip"
        PROTOC_SHA256="56af3fc2e43a0230802e6fadb621d890ba506c5c17a1ae1070f685fe79ba12d0"
        ;;
    *)
        echo_error "Unsupported platform: $PLATFORM ($ARCH)"
        exit 1
        ;;
esac

PROTOC_URL="https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/$PROTOC_ASSET"

echo_info "Platform: $PLATFORM ($ARCH)"
echo_info "Protoc URL: $PROTOC_URL"

cd "$DIR"
mkdir -p "$TMP_DIR"

echo_info "Checking for protoc-gen-elixir $PROTOBUF_VERSION..."
if [ ! -x "$PLUGIN_PATH" ] || [ "$("$PLUGIN_PATH" --version 2>/dev/null)" != "$PROTOBUF_VERSION" ]; then
    echo_info "Installing protoc-gen-elixir $PROTOBUF_VERSION into $PLUGIN_MIX_HOME..."
    MIX_HOME="$PLUGIN_MIX_HOME" mix local.hex --force --if-missing
    MIX_HOME="$PLUGIN_MIX_HOME" mix escript.install hex protobuf "$PROTOBUF_VERSION" --force
else
    echo_info "protoc-gen-elixir $PROTOBUF_VERSION found at $PLUGIN_PATH"
fi

echo_info "Setting up protoc compiler..."
if [ ! -x "$PROTOC" ]; then
    echo_info "Downloading protoc $PROTOC_VERSION..."
    PROTOC_ZIP="$TMP_DIR/$PROTOC_ASSET"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$PROTOC_ZIP" "$PROTOC_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$PROTOC_ZIP" "$PROTOC_URL"
    else
        echo_error "Neither curl nor wget found. Please install one of them."
        exit 1
    fi

    echo_info "Verifying protoc checksum..."
    if ! echo "$PROTOC_SHA256  $PROTOC_ZIP" | shasum -a 256 -c -; then
        echo_error "Checksum mismatch for $PROTOC_ASSET"
        rm -f "$PROTOC_ZIP"
        exit 1
    fi

    echo_info "Extracting protoc..."
    rm -rf "$PROTOC_PATH"
    unzip -q "$PROTOC_ZIP" -d "$PROTOC_PATH"
    rm "$PROTOC_ZIP"
    echo_info "Protoc installed successfully"
else
    echo_info "Protoc already installed at $PROTOC_PATH"
fi

echo_info "Setting up googleapis at $GOOGLEAPIS_REF..."
if [ ! -d "$GOOGLEAPIS_PATH/.git" ]; then
    git init -q "$GOOGLEAPIS_PATH"
    git -C "$GOOGLEAPIS_PATH" remote add origin https://github.com/googleapis/googleapis.git
fi
git -C "$GOOGLEAPIS_PATH" fetch -q --depth 1 origin "$GOOGLEAPIS_REF"
git -C "$GOOGLEAPIS_PATH" -c advice.detachedHead=false checkout -q "$GOOGLEAPIS_REF"

echo_info "Generating Elixir code from protobuf files..."

# google/pubsub/v1/*.proto includes schema.proto
echo_info "Generating Google Pub/Sub v1..."
rm -rf "$GEN_DIR"
mkdir -p "$GEN_DIR"
"$PROTOC" -I "$GOOGLEAPIS_PATH" \
    --plugin=protoc-gen-elixir="$PLUGIN_PATH" \
    --elixir_out=plugins=grpc:"$GEN_DIR" \
    "$GOOGLEAPIS_PATH"/google/pubsub/v1/*.proto

echo_info "Replacing generated files in $OUT..."
rm -rf "$OUT"
mkdir -p "$OUT/pubsub/v1"
cp "$GEN_DIR"/google/pubsub/v1/google/pubsub/v1/*.pb.ex "$OUT/pubsub/v1/"

echo_info "Protobuf generation completed successfully!"
echo_info "Generated files are in: $OUT"
