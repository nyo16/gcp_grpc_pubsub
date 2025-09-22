#!/bin/sh
# Script to update Google API protobuf files for Elixir
# Original inspiration from https://github.com/cjab/weddell/blob/master/bin/update-proto

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo "${RED}[ERROR]${NC} $1"; }

if [ "$MIX_HOME" = "" ]; then
    export MIX_HOME=$HOME/.mix
fi

PLUGIN_PATH=$MIX_HOME/escripts/protoc-gen-elixir 

echo_info "Checking for protoc-gen-elixir plugin..."
if [ ! -f $PLUGIN_PATH ]; then
    echo_info "Installing protoc-gen-elixir plugin..."
    mix escript.install hex protobuf --force
else
    echo_info "protoc-gen-elixir plugin found at $PLUGIN_PATH"
fi

DIR="$( cd "$( dirname "$0" )" && pwd )"
TMP_DIR=$DIR/staging_folder
echo_info "Working directory: $DIR"
echo_info "Staging directory: $TMP_DIR"

OUT=$DIR/lib
PROTOBUF_PATH=$TMP_DIR/protobuf
GOOGLEAPIS_PATH=$TMP_DIR/googleapis
PROTOC_PATH=$TMP_DIR/protoc
PROTOC=$PROTOC_PATH/bin/protoc

# Detect platform and set appropriate protoc URL
PLATFORM=$(uname -s)
ARCH=$(uname -m)

case "$PLATFORM" in
    Darwin)
        if [ "$ARCH" = "arm64" ]; then
            PROTOC_URL=https://github.com/protocolbuffers/protobuf/releases/download/v32.0/protoc-32.0-osx-aarch_64.zip
        else
            PROTOC_URL=https://github.com/protocolbuffers/protobuf/releases/download/v32.0/protoc-32.0-osx-x86_64.zip
        fi
        ;;
    Linux)
        if [ "$ARCH" = "x86_64" ]; then
            PROTOC_URL=https://github.com/protocolbuffers/protobuf/releases/download/v32.0/protoc-32.0-linux-x86_64.zip
        else
            PROTOC_URL=https://github.com/protocolbuffers/protobuf/releases/download/v32.0/protoc-32.0-linux-aarch_64.zip
        fi
        ;;
    *)
        echo_error "Unsupported platform: $PLATFORM"
        exit 1
        ;;
esac

echo_info "Platform: $PLATFORM ($ARCH)"
echo_info "Protoc URL: $PROTOC_URL"

cd $DIR
mkdir -p $TMP_DIR

echo_info "Setting up protoc compiler..."
if [ ! -d "$PROTOC_PATH" ]; then
    echo_info "Downloading protoc..."
    if command -v curl >/dev/null 2>&1; then
        curl -L -o $TMP_DIR/protoc.zip $PROTOC_URL
    elif command -v wget >/dev/null 2>&1; then
        wget -O $TMP_DIR/protoc.zip $PROTOC_URL
    else
        echo_error "Neither curl nor wget found. Please install one of them."
        exit 1
    fi
    
    echo_info "Extracting protoc..."
    cd $TMP_DIR
    unzip -q protoc.zip -d $PROTOC_PATH
    rm $TMP_DIR/protoc.zip
    echo_info "Protoc installed successfully"
else
    echo_info "Protoc already installed at $PROTOC_PATH"
fi

echo_info "Setting up googleapis repository..."
if [ ! -d "$GOOGLEAPIS_PATH" ]; then
    echo_info "Cloning googleapis repository..."
    git clone https://github.com/googleapis/googleapis.git $GOOGLEAPIS_PATH
else
    echo_info "googleapis repository already exists, updating..."
fi

cd $GOOGLEAPIS_PATH && git pull && cd $DIR

echo_info "Cleaning up old generated files..."
# remove proto files in case that exists.
rm -rf $OUT
# create output directory.
mkdir -p $OUT
echo_info "Output directory prepared: $OUT"

echo_info "Generating Elixir code from protobuf files..."

echo_info "Generating Google Pub/Sub v1..."
$PROTOC -I $GOOGLEAPIS_PATH \
--plugin=protoc-gen-elixir=$PLUGIN_PATH \
--elixir_out=plugins=grpc:$OUT \
$GOOGLEAPIS_PATH/google/pubsub/v1/*.proto

echo_info "Generating Google Pub/Sub v1 Schema..."
$PROTOC -I $GOOGLEAPIS_PATH \
--plugin=protoc-gen-elixir=$PLUGIN_PATH \
--elixir_out=plugins=grpc:$OUT \
$GOOGLEAPIS_PATH/google/pubsub/v1/schema.proto

echo_info "Protobuf generation completed successfully!"
echo_info "Generated files are in: $OUT"