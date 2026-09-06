#!/usr/bin/env bash
# One-line identity of the GPU software stack, so benchmark rows stay comparable
# across kernel/firmware/driver/compiler changes. Used by bench/run.sh (stack field)
# and quoted in README result tables.
fw() { cat "/sys/class/drm/card1/device/fw_version/$1_fw_version" 2>/dev/null | sed 's/0x0*//'; }
mesa=$(vulkaninfo --summary 2>/dev/null | grep -m1 driverInfo | sed 's/.*= *//; s/-0ubuntu.*//')
glslc=$(glslc --version 2>/dev/null | head -1 | grep -oE '[0-9]{4}\.[0-9]+' | head -1)
llcommit=$(git -C "${LLAMA_CPP_DIR:-$HOME/ai/llama.cpp}" rev-parse --short HEAD 2>/dev/null)
printf 'kernel=%s fw(pfp/mec/mes)=%s/%s/%s mesa=%s glslc=%s llama.cpp=%s ollama=%s rocm=%s\n' \
  "$(uname -r)" "$(fw pfp)" "$(fw mec)" "$(fw mes)" "${mesa:-?}" "${glslc:-?}" "${llcommit:-?}" \
  "$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
  "$(basename "$(ls -d /opt/rocm/core-[0-9]* 2>/dev/null | head -1)" 2>/dev/null | grep -oE "[0-9]+\.[0-9]+" || echo "?")"
