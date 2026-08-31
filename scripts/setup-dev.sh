#!/bin/sh
# Builds the Steel-enabled Helix fork and installs this plugin's dependencies.
#
# Everything cargo produces goes into .build/ inside the workspace so it survives
# a dev container rebuild; the installed binaries themselves do not, so this
# script is also the recovery path after a rebuild.
set -e

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/.build"
export CARGO_TARGET_DIR="$BUILD/target"

mkdir -p "$BUILD"

echo "==> Fetching sources"
[ -d "$BUILD/helix" ] || git clone --depth 1 --branch steel-event-system \
	https://github.com/mattwparas/helix.git "$BUILD/helix"
[ -d "$BUILD/steel-src" ] || git clone --depth 1 \
	https://github.com/mattwparas/steel.git "$BUILD/steel-src"

echo "==> Installing the Steel toolchain (steel, forge, language server)"
cargo install --git https://github.com/mattwparas/steel.git \
	steel-interpreter steel-language-server cargo-steel-lib steel-forge --locked --force

echo "==> Installing the Steel standard cogs"
# Each cog is installed at the path named by its own `package-name`.
COGS="${STEEL_HOME:-$HOME/.local/share/steel}/cogs"
mkdir -p "$COGS"
cd "$BUILD/steel-src/cogs"
find . -name cog.scm | while read -r manifest; do
	name=$(sed -n "s/.*define package-name '\([^ )]*\).*/\1/p" "$manifest")
	[ -n "$name" ] || continue
	mkdir -p "$COGS/$name"
	cp -r "$(dirname "$manifest")"/* "$COGS/$name/"
done
cd "$ROOT"

echo "==> Building Helix with Steel enabled"
cargo install --path "$BUILD/helix/helix-term" --features steel,git --locked --force

echo
echo "Done. hx $(hx --version | head -1)"
echo "Point your ~/.config/helix/helix.scm at $ROOT/devcontainer.scm - see the README."
