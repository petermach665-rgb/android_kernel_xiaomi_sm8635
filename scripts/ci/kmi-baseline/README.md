# KMI baselines

Each `<flavor>.symvers` file is the complete `Module.symvers` emitted by the
same tree, flavor, defconfig, fragment, and toolchain that will be released.
A baseline is a reproducibility gate; it is not proof that stock vendor
modules will load or that the image has booted on a device.

Generate or refresh a baseline from a successful `mode=baseline` workflow (or
the equivalent local build) after the source and toolchain pins are fixed:

```sh
cp dist/Module.symvers-ksun-susfs-droidspaces \
  scripts/ci/kmi-baseline/ksun-susfs-droidspaces.symvers
```

`build-flavor.sh` diffs every later build against the selected baseline and
fails on any changed or removed CRC. Added symbols do not break a prebuilt
module and are reported without failing the gate. The comparison is performed
by `scripts/ci/symvers-diff.sh`.

## accepted-drift.txt (optional, per branch)

A CRC shift may be listed only after the shifted image has booted on physical
peridot hardware with the intended stock `vendor_dlkm` modules. The format is:

```text
# <symbol> <new-crc>   # device and boot evidence
```

This workspace has no physical-device evidence, so
`accepted-drift.txt` is intentionally empty. Never add a symbol on reasoning
alone; an allowlist weakens the only automated KMI failure signal.
