#!/usr/bin/env bash
# One-line identity of the GPU software stack, so benchmark rows stay comparable
# across kernel/firmware/driver/compiler changes. Used by bench/run.sh (stack field)
# and quoted in README result tables.
fw() { cat "/sys/class/drm/card1/device/fw_version/$1_fw_version" 2>/dev/null | sed 's/0x0*//'; }
ver() { "$1" --version 2>/dev/null | head -1 | grep -oE '[0-9]{4}\.[0-9]+' | head -1; }
llama_dir="${LLAMA_CPP_DIR:-$HOME/ai/llama.cpp}"
mesa=$(vulkaninfo --summary 2>/dev/null | grep -m1 driverInfo | sed 's/.*= *//; s/-0ubuntu.*//')
# The Vulkan backend's shaders come from the glslc named in its CMakeCache, not the one on PATH:
# the 2026-09-05 rebuild used LunarG glslc 2026.3 (892 _q8_1 shader variants in libggml-vulkan.so)
# while PATH still has Ubuntu's 2023.8 (20 variants), so rows that quoted PATH named the wrong
# compiler. Report the build compiler as (build); PATH is only the fallback, tagged (path).
vk_glslc=$(sed -n 's/^Vulkan_GLSLC_EXECUTABLE:FILEPATH=//p' "$llama_dir/build-vulkan/CMakeCache.txt" 2>/dev/null | head -1)
v=$([ -x "$vk_glslc" ] && ver "$vk_glslc")
if [ -n "$v" ]; then glslc="${v}(build)"; else v=$(ver glslc); glslc="${v:+${v}(path)}"; fi
vklib="$llama_dir/build-vulkan/bin/libggml-vulkan.so"
vkshaders=$([ -r "$vklib" ] && strings "$vklib" 2>/dev/null | grep -c _q8_1)
llcommit=$(git -C "$llama_dir" rev-parse --short HEAD 2>/dev/null)
printf 'kernel=%s fw(pfp/mec/mes)=%s/%s/%s mesa=%s glslc=%s vkshaders=%s llama.cpp=%s ollama=%s rocm=%s\n' \
  "$(uname -r)" "$(fw pfp)" "$(fw mec)" "$(fw mes)" "${mesa:-?}" "${glslc:-?}" "$vkshaders" "${llcommit:-?}" \
  "$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
  "$(ls -d /opt/rocm/core-[0-9]* 2>/dev/null | sort -V | tail -1 | sed "s|.*/core-||")"
