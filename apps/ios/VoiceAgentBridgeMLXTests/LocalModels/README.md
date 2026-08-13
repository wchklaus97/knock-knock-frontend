# Local MLX qualification models

This folder is copied into the MLX qualification test bundle so physical-device
tests can run without network access. Model files are intentionally ignored and
must never be committed.

Expected local layout:

```text
LocalModels/
  e5-small/
  gemma-3-1b-it-qat-4bit/
```

Pass test paths as bundle-relative values, for example:

```text
KNOCK_MLX_EMBEDDER_DIR=bundle:LocalModels/e5-small
```

Physical iPhone execution is required for qualification. The explicit
`KNOCK_ALLOW_MLX_SIMULATOR_DIAGNOSTIC=1` switch may be used to inspect prompt
behavior while a device is unavailable, but its accuracy, latency, and memory
results must never be counted as device qualification evidence.
