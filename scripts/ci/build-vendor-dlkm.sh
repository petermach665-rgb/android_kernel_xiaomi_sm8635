#!/bin/bash
# build-vendor-dlkm.sh - pack the modules just built by build-flavor.sh into a
# flashable vendor_dlkm.img.
#
#   scripts/ci/build-vendor-dlkm.sh <flavor>
#
# Why: the stock prebuilt /vendor_dlkm modules carry CRCs from the ROM's own
# build and refuse to load against our Image ("disagrees about version of
# symbol _dev_err"). Building the modules from the same tree+config+toolchain
# as the Image makes the pair self-consistent.
#
# Requires: build-flavor.sh already ran in this workspace (out/ is populated
# and out/Module.symvers exists), e2fsprogs for mke2fs, optionally
# android-sdk-libsparse-utils for img2simg.
#
# Environment:
#   OUT        kbuild output dir            (default: out)
#   DIST       where the .img lands        (default: dist)
#   SPARSE     1 = run img2simg if present (default: 1)
#   STRIP_MODULES 1 = strip with llvm-strip (default: 0 - keep symbols,
#                 matches the stock partition and avoids the host-binutils
#                 "Unable to recognise the format" failure on aarch64 .ko)
#   STOCK_MODULE_COUNT  warn if fewer than this many .ko were installed
#   SKIP_BUILD 1 = only install + pack, do not re-run make
#
# Produces: $DIST/vendor_dlkm-<flavor>.img
#
# NOTE: the image is NOT AVB-signed. It boots only when dm-verity/verification
# is disabled for vendor_dlkm (fastboot --disable-verity --disable-verification
# flash vbmeta ...) or the bootloader does not enforce it.
set -euo pipefail

FLAVOR="${1:-}"
[ -n "$FLAVOR" ] || { sed -n '2,34p' "$0"; exit 2; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

OUT="${OUT:-out}"
DIST="${DIST:-dist}"
SPARSE="${SPARSE:-1}"
STRIP_MODULES="${STRIP_MODULES:-0}"
STOCK_MODULE_COUNT="${STOCK_MODULE_COUNT:-0}"
JOBS="${JOBS:-$(nproc --all)}"
CLANG_DIR="${CLANG_DIR:-$HOME/clang}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

[ -d "$OUT" ] || die "no $OUT/ - run build-flavor.sh first"
[ -f "$OUT/Module.symvers" ] || die "no $OUT/Module.symvers - run build-flavor.sh first"

KREL="$(cat "$OUT/include/config/kernel.release" 2>/dev/null || true)"
[ -n "$KREL" ] || die "cannot read $OUT/include/config/kernel.release"
log "flavor=$FLAVOR kernel.release=$KREL"

STAGE="$OUT/vendor_dlkm-staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  # The host binutils 'strip' cannot read aarch64 relocatable objects, which
  # makes INSTALL_MOD_STRIP=1 fail with "Unable to recognise the format of the
  # input file". Either point STRIP at the AOSP llvm-strip or skip stripping.
  STRIP_ENV=()
  if [ "$STRIP_MODULES" = 1 ]; then
    if [ -x "$CLANG_DIR/bin/llvm-strip" ]; then
      STRIP_ENV=(INSTALL_MOD_STRIP=1 STRIP="$CLANG_DIR/bin/llvm-strip")
      log "stripping modules with $CLANG_DIR/bin/llvm-strip"
    else
      log "[!] llvm-strip not found in $CLANG_DIR/bin - installing modules unstripped"
    fi
  else
    log "installing modules unstripped (STRIP_MODULES=0)"
  fi

  log "modules_install -> $STAGE/lib/modules/$KREL"
  make -j"$JOBS" O="$OUT" "${STRIP_ENV[@]}" \
       INSTALL_MOD_PATH="$PWD/$STAGE" modules_install 2>&1 | tail -20 \
    || die "modules_install failed"
fi

MODDIR="$STAGE/lib/modules/$KREL"
[ -d "$MODDIR" ] || die "modules_install did not create $MODDIR"

# depmod bookkeeping is not needed on-device for GKI dlkm; drop the symlinks.
rm -f "$MODDIR/build" "$MODDIR/source" 2>/dev/null || true

NKO=$(find "$MODDIR" -name '*.ko' | wc -l)
log "modules installed: $NKO"
[ "$NKO" -gt 0 ] || die "no .ko files installed"
if [ "$STOCK_MODULE_COUNT" -gt 0 ] && [ "$NKO" -lt "$STOCK_MODULE_COUNT" ]; then
  log "[!] only $NKO .ko vs $STOCK_MODULE_COUNT on the stock partition - missing modules will not be replaced"
fi

# The on-device layout is /vendor_dlkm/lib/modules/<krel>/*.ko, i.e. the
# partition root maps to the staging dir root.
SIZE_KB=$(du -sk "$STAGE" | cut -f1)
IMG_KB=$(( SIZE_KB + SIZE_KB / 8 + 4096 ))
log "staging ${SIZE_KB} KiB -> ext4 image ${IMG_KB} KiB"

mkdir -p "$DIST"
RAW="$DIST/vendor_dlkm-$FLAVOR.raw.img"
IMG="$DIST/vendor_dlkm-$FLAVOR.img"
rm -f "$RAW" "$IMG"

# -d root: staging dir contents go to the image root, matching the stock
# partition (which contains lib/, lost+found/, ...).
mke2fs -q -t ext4 -b 4096 -O ^has_journal,^resize_inode -d "$STAGE" "$RAW" "$IMG_KB"k || die "mke2fs failed"

if [ "$SPARSE" = 1 ] && command -v img2simg >/dev/null 2>&1; then
  img2simg "$RAW" "$IMG" && rm -f "$RAW"
  log "sparse image: $IMG ($(stat -c%s "$IMG") bytes)"
else
  mv -f "$RAW" "$IMG"
  log "raw image: $IMG ($(stat -c%s "$IMG") bytes)"
fi

sha256sum "$IMG" > "$IMG.sha256"
echo "summary: flavor=$FLAVOR modules=$NKO image=$IMG size=$(stat -c%s "$IMG")"
