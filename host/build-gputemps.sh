#!/bin/bash
# Build and install `gputemps` - the junction/hotspot temperature reader.
#
# Junction temperature is the vendor's stated best early indicator of a
# thermally-failing RTX 5090, and no NVIDIA tooling exposes it: NVML enumerates
# exactly one thermal sensor and DCGM has no junction field. This tool reads it
# from BAR0 MMIO directly (Blackwell: 0x00AD0A90, 4 channels).
#
# Deliberate choices:
#  * Sources are pinned by commit in gputemps.sha, never floated to HEAD - the
#    JSON schema has changed twice and our parser is written against that SHA.
#  * nvml.h is fetched into a PRIVATE /opt/gputemps/include. No CUDA toolkit
#    gets installed for the sake of one header.
#  * libnvidia-ml.so is symlinked into a PRIVATE /opt/gputemps/lib and linked
#    with -L against that. We do NOT create a symlink in
#    /lib/x86_64-linux-gnu - a driver upgrade would leave it dangling. The
#    library SONAME is versioned, so no RPATH or LD_LIBRARY_PATH is needed at
#    runtime; the script verifies that with ldd.
#  * Installed 0750, not 0755: it mmaps /dev/mem, so there is no reason for it
#    to be world-executable.
#  * NO kernel arguments are needed. CONFIG_IO_STRICT_DEVMEM is unset on these
#    hosts and Secure Boot is off, so BAR0 mmap already works and `iomem=relaxed`
#    is NOT required. Do not "helpfully" add it later - it needs a reboot and
#    buys nothing here.
#
# Usage:
#   sudo ./build-gputemps.sh              # fetch, build, install, stamp, tar
#   sudo ./build-gputemps.sh --from-tar F # install a tarball built elsewhere
#   ./build-gputemps.sh --check           # report what is installed, no changes
set -euo pipefail

cd "$(dirname "$0")"
SRC_PIN="$PWD/gputemps.sha"
PREFIX=/opt/gputemps
BIN=/usr/local/bin/gputemps
WORK=${WORK:-/tmp/gputemps-build.$$}
TARDIR=${TARDIR:-$PWD}

# shellcheck disable=SC1090
[ -f "$SRC_PIN" ] || { echo "missing $SRC_PIN"; exit 1; }
. "$SRC_PIN"

need_root() { [ "$(id -u)" = 0 ] || { echo "run as root: sudo $0 $*"; exit 1; }; }

stamp_show() {
  if [ -f "$PREFIX/BUILD" ]; then cat "$PREFIX/BUILD"; else echo "no BUILD stamp at $PREFIX/BUILD"; fi
  if [ -x "$BIN" ]; then
    echo "binary:    $BIN ($(stat -c%A "$BIN"))"
    echo "sha256:    $(sha256sum "$BIN" | cut -d' ' -f1)"
    echo "ldd:"; ldd "$BIN" | sed 's/^/  /'
  else
    echo "binary:    NOT INSTALLED"
  fi
}

case "${1:-}" in
  --check) stamp_show; exit 0 ;;
esac

install_tarball() { # $1 = tarball
  need_root "$@"
  local t=$1
  [ -f "$t" ] || { echo "no such tarball: $t"; exit 1; }
  tar xzf "$t" -C / --no-same-owner
  chmod 750 "$BIN"
  echo "installed from $t"
  stamp_show
  exit 0
}

if [ "${1:-}" = "--from-tar" ]; then install_tarball "${2:?--from-tar needs a file}"; fi

need_root
command -v git >/dev/null || { echo "git required"; exit 1; }

# --- dependencies: compiler + libpci only ------------------------------------
missing=""
for p in build-essential libpci-dev; do
  dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
done
if [ -n "$missing" ]; then
  echo "installing:$missing"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing
fi

trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# --- fetch pinned sources ----------------------------------------------------
echo "==> fetching $GPUTEMPS_REPO @ $GPUTEMPS_COMMIT"
git init -q "$WORK/src"
git -C "$WORK/src" remote add origin "$GPUTEMPS_REPO"
git -C "$WORK/src" fetch -q --depth 1 origin "$GPUTEMPS_COMMIT"
git -C "$WORK/src" checkout -q FETCH_HEAD
got=$(git -C "$WORK/src" rev-parse HEAD)
[ "$got" = "$GPUTEMPS_COMMIT" ] || { echo "commit mismatch: got $got want $GPUTEMPS_COMMIT"; exit 1; }

# 2b85 must be in the device table or we would be reading Ada/Ampere offsets
grep -q '0x2B85' "$WORK/src/src/sensor.c" || {
  echo "FATAL: RTX 5090 (0x2B85) not in this commit's device table"; exit 1; }

echo "==> fetching nvml.h from $NVML_REPO @ $NVML_TAG"
git init -q "$WORK/nv"
git -C "$WORK/nv" remote add origin "$NVML_REPO"
git -C "$WORK/nv" fetch -q --depth 1 origin "refs/tags/$NVML_TAG"
git -C "$WORK/nv" checkout -q FETCH_HEAD
NVML_H=$(find "$WORK/nv" -name nvml.h -print -quit)
[ -n "$NVML_H" ] || { echo "nvml.h not found in nvidia-settings@$NVML_TAG"; exit 1; }

# --- private include/lib -----------------------------------------------------
install -d -m 755 "$PREFIX/include" "$PREFIX/lib"
install -m 644 "$NVML_H" "$PREFIX/include/nvml.h"

RUNTIME_LIB=$(ldconfig -p | awk '/libnvidia-ml\.so\.1/{print $NF; exit}')
[ -n "$RUNTIME_LIB" ] || { echo "libnvidia-ml.so.1 not found - is the driver installed?"; exit 1; }
ln -sfn "$RUNTIME_LIB" "$PREFIX/lib/libnvidia-ml.so"
echo "==> link target: $PREFIX/lib/libnvidia-ml.so -> $RUNTIME_LIB"

# --- build -------------------------------------------------------------------
echo "==> building"
make -C "$WORK/src" -s clean >/dev/null 2>&1 || true
make -C "$WORK/src" -s \
  CPPFLAGS="-I$PREFIX/include" \
  LDFLAGS="-L$PREFIX/lib"
[ -x "$WORK/src/gputemps" ] || { echo "build produced no binary"; exit 1; }

install -m 750 "$WORK/src/gputemps" "$BIN"

# The SONAME is versioned, so the runtime resolves libnvidia-ml.so.1 through
# the normal loader path. If this ever reports "not found" the private -L has
# leaked into the runtime path and needs a real fix, not an LD_LIBRARY_PATH.
if ldd "$BIN" | grep -q "not found"; then
  echo "FATAL: unresolved runtime dependency:"; ldd "$BIN" | grep "not found"; exit 1
fi

# --- stamp -------------------------------------------------------------------
DRIVER=$(timeout 25 nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo unknown)
cat > "$PREFIX/BUILD" << EOF
commit:    $GPUTEMPS_COMMIT
repo:      $GPUTEMPS_REPO
nvml_tag:  $NVML_TAG
built_at:  $(date -Is)
built_on:  $(hostname)
gcc:       $(gcc --version | head -1)
driver:    $DRIVER
binsha256: $(sha256sum "$BIN" | cut -d' ' -f1)
EOF
chmod 644 "$PREFIX/BUILD"

# --- tarball for hosts that cannot reach GitHub ------------------------------
TAR="$TARDIR/gputemps-${GPUTEMPS_COMMIT:0:12}-$(uname -m).tar.gz"
tar czf "$TAR" -C / "${BIN#/}" "${PREFIX#/}/BUILD" "${PREFIX#/}/include/nvml.h" 2>/dev/null
echo "==> tarball: $TAR"
echo ""
stamp_show
