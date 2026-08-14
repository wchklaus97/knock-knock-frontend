# Local MLX qualification models

This folder is copied into the MLX qualification test bundle so physical-device
tests can run without network access. Model files are intentionally ignored and
must never be committed.

Expected local layout:

```text
LocalModels/
  e5-small/
  gemma-3-1b-it-qat-4bit/
  gemma-4-e2b-it-4bit/
```

Pass test paths as bundle-relative values, for example:

```text
KNOCK_MLX_EMBEDDER_DIR=bundle:LocalModels/e5-small
KNOCK_MLX_GEMMA_DIR=bundle:LocalModels/gemma-4-e2b-it-4bit
KNOCK_MLX_GEMMA_MODEL_ID=mlx-community/gemma-4-e2b-it-4bit
```

`VoiceAgentBridgeGemma4Qualification` supplies the Gemma 4 model ID itself. The
directory still has to be staged explicitly; the test target never downloads
weights. The allowlisted Gemma 4 weight file is 3,581,101,896 bytes with SHA-256
`e9bea0584546fafb5ff83a1132a6c4662a8498cc6a5bcda52fc6ca562b7bafab`.

Physical iPhone execution is required for qualification. The explicit
`KNOCK_ALLOW_MLX_SIMULATOR_DIAGNOSTIC=1` switch may be used to inspect prompt
behavior while a device is unavailable, but its accuracy, latency, and memory
results must never be counted as device qualification evidence.

The 2026-08-14 iPhone 17 Pro Max qualification opened this model successfully,
but the English shard achieved only 87.5% exact commands and 90.9% exact raw
fields. Both are below the 95% gates, so this candidate must not be copied into
the application target or enabled in Release.
