#!/usr/bin/env bash
# claude-local statusline: a task-manager-style operator cockpit for the
# isolated local Ollama setup. Claude Code pipes a JSON payload on stdin after
# every turn; the script also reads live Ollama API state, GPU activity (for a
# "thinking" signal), per-core CPU, VRAM, RAM. All reads are local and fast.
#
# Layout:
#   mln-web:main *   online qwen3-coder:30b  12m    <- repo | api+model | timer
#   ⏳ thinking  ~85 tok/s                        <- clear working indicator (or "· idle")
#   context 47% 106K/262K  ▕bar▏ ~17m left         <- context pressure gauge
#   cpu 22%  [bricks]  hot:c00,c06  ·  vram 39% ram 43%
#
# Speed/robustness:
#   * No blocking sleeps. CPU % is computed as a delta against the raw counters
#     captured on the previous invocation (persisted), so each tick is ~ms.
#   * Fail-safe: an API/gpu/context failure never blanks the line; essential
#     identity + status always render.
set -uo pipefail

input=$(cat)
RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
GREY=$'\033[90m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
WHITE=$'\033[97m'; CYAN=$'\033[36m'; MAGENTA=$'\033[35m'

CONFIG_DIR="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
STATE="$CONFIG_DIR/statusline.state"
NCPU=16

# -------------------------------------------------------- helpers/state ----
load_state() { declare -gA S; [ -f "$STATE" ] && while IFS='=' read -r k v; do [ -n "$k" ] && S["$k"]="$v"; done < "$STATE"; }
save_state() { local f k; f=$(mktemp); for k in "${!S[@]}"; do printf '%s=%s\n' "$k" "${S[$k]}" >> "$f"; done; mv "$f" "$STATE"; }
load_state

col_pct() { if   [ "$1" -lt 70 ]; then printf '\033[32m'
  elif [ "$1" -lt 90 ]; then printf '\033[33m'; else printf '\033[31m'; fi; }
core_color() { if   [ "$1" -lt 20 ]; then printf '\033[2m'
  elif [ "$1" -lt 50 ]; then printf '\033[32m'
  elif [ "$1" -lt 80 ]; then printf '\033[33m'; else printf '\033[31m'; fi; }

now=$(date +%s)

# ------------------------------------------------------------------ L1 ----
# Repo+git (first) and session timer.
line1=""
cur_dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null)
[ -z "$cur_dir" ] && cur_dir="$PWD"
gitroot=$cur_dir
while [ "$gitroot" != "/" ] && [ ! -d "$gitroot/.git" ]; do gitroot=$(dirname "$gitroot"); done
if [ -d "$gitroot/.git" ]; then
  proj=$(basename "$gitroot")
  branch=$(git -C "$gitroot" branch --show-current 2>/dev/null); branch=${branch:-detached}
  dirty=$(git -C "$gitroot" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  line1="${BOLD}${proj}${RESET}${GREY}:${RESET}${BOLD}${branch}${RESET}"
  [ "${dirty:-0}" -gt 0 ] && line1+="${YELLOW}*${dirty}${RESET}"
else
  line1="${BOLD}$(basename "$cur_dir")${RESET}"
fi

# API status + served/loaded model (Ollama). Three distinct states:
#   online + model loaded   -> green ● <model>  (also marks when it is NOT the
#                                                 model this session launched)
#   online + nothing loaded -> amber ● no model loaded  (VRAM empty)
#   offline (api down)      -> red ● offline / api down
online=""; model=""
resp=$(curl -s --max-time 1 http://localhost:1234/api/ps 2>/dev/null)
if [ -n "$resp" ]; then
  model=$(printf '%s' "$resp" | jq -r '.models[0].name // empty' 2>/dev/null)
fi
session_model=$(cat "$CONFIG_DIR/session_model" 2>/dev/null || echo "")
if [ -n "$model" ]; then
  if [ -n "$session_model" ] && [ "$model" != "$session_model" ]; then
    # Another session (or a manual load) swapped the model; say so clearly.
    line1+="  ${GREEN}●${RESET} ${BOLD}${model}${RESET}${YELLOW}≠${RESET}${GREY}${session_model}${RESET}"
  else
    line1+="  ${GREEN}●${RESET} ${BOLD}${model}${RESET}"
  fi
elif [ -n "$resp" ]; then
  line1+="  ${YELLOW}● no model loaded${RESET} ${GREY}(idle)${RESET}"
else
  line1+="  ${RED}● offline${RESET}   ${RED}api down${RESET}"
fi

# session timer
src=$(cat "$CONFIG_DIR/session_start" 2>/dev/null || echo "")
if [ -n "$src" ]; then
  el=$(( now - src )); [ "$el" -lt 0 ] && el=0
  m=$(( el/60 )); s=$(( el%60 ))
  if [ "$m" -lt 60 ]; then rt="${m}m${s}s"; else rt="$((m/60))h$((m%60))m"; fi
  line1+="  ${GREY}${rt}${RESET}"
fi

# ------------------------------------------------------------------ L2 ----
# Thinking indicator. "Generating now" is detected two complementary ways and
# OR'd so it never flickers mid-generation:
#   (a) live GPU busy % -- ~98 when Ollama is computing, ~2 at idle;
#   (b) llama-server cumulative utime+stime growth across ticks (rate >= 1
#       core-sec/sec). GPU catches sustained compute; CPU-delta covers brief
#       windows where the GPU moving-average reads low.
line2=""
thinking=""
if [ -n "$resp" ]; then
  gbusy=0
  for f in /sys/class/drm/card*/device/gpu_busy_percent; do
    [ -r "$f" ] && { gbusy=$(cat "$f" 2>/dev/null); break; }
  done
  [ "${gbusy:-0}" -ge 20 ] 2>/dev/null && thinking=1
  lls=$(pgrep -f "llama-server" | head -1)
  if [ -n "$lls" ]; then
    # read cpu-ms (utime+stime in clock ticks * 10 ~= ms at CLK_TCK=100)
    mcs=$(awk -v p="$lls" '$1==p { ut=$14; st=$15; print (ut+st)*10 }' /proc/"$lls"/stat 2>/dev/null)
    if [ -n "$mcs" ]; then
      pm=${S[lmcs]:-}; pts=${S[lmts]:-}
      if [ -n "$pm" ] && [ -n "$pts" ] && [ "$now" -gt "$pts" ]; then
        dt=$(( now - pts )); [ "$dt" -lt 1 ] && dt=1
        dm=$(( mcs - pm )); [ "$dm" -lt 0 ] && dm=0
        rate_ms=$(( dm / dt ))
        [ "$rate_ms" -ge 800 ] && thinking=1
      fi
      S[lmcs]=$mcs; S[lmts]=$now
    fi
  fi
  if [ -n "$thinking" ]; then
    spinners=( "◐" "◓" "◑" "◒" )
    frame=$(( (now) % ${#spinners[@]} ))
    line2="${MAGENTA}${spinners[$frame]}${RESET} ${BOLD}thinking${RESET}"
  else
    line2="${DIM}· idle${RESET} ${GREY}(model loaded)${RESET}"
  fi
else
  line2="${RED}!! offline${RESET}"
fi

# live tok/s: context tokens grown across ticks (persist last tokens + ts).
ctx_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
toks=""
if [ -n "$ctx_pct" ]; then
  ti=$(printf '%s' "$input" | jq -r '.context_window.total_input_tokens // 0')
  to=$(printf '%s' "$input" | jq -r '.context_window.total_output_tokens // 0')
  tot=$(( ti + to ))
  pt=${S[last_toks]:-}; pts=${S[last_ts]:-}
  rate=""
  if [ -n "$pt" ] && [ -n "$pts" ] && [ "$now" -gt "$pts" ]; then
    dt=$(( now - pts )); dT=$(( tot - pt ))
    if [ "$dt" -gt 0 ] && [ "$dT" -gt 0 ] && [ "$dT" -lt 400000 ]; then
      r=$(( dT * 1000 / dt ))
      if [ "$r" -lt 1500 ]; then rate="  ~${r} tok/s"; fi
    fi
  else
    # seed with the model's typical steady-state rate so it isn't blank first tick
    rate=""
  fi
  line2+="${rate}"
  S[last_toks]=$tot; S[last_ts]=$now
fi

# ------------------------------------------------------------------ L3 ----
# Context pressure gauge.
line3=""
if [ -n "$ctx_pct" ]; then
  used=$(printf '%s' "$input" | jq -r '.context_window.total_input_tokens // 0')
  out=$(printf '%s' "$input" | jq -r '.context_window.total_output_tokens // 0')
  max=$(printf '%s' "$input" | jq -r '.context_window.context_window_size // 0')
  pct_i=$(printf '%.0f' "$ctx_pct"); [ "$pct_i" -gt 100 ] && pct_i=100; [ "$pct_i" -lt 0 ] && pct_i=0
  total=$(( used + out )); rem=$(( max - total )); [ "$rem" -lt 0 ] && rem=0
  CCOL=$(col_pct "$pct_i")
  # 1/8-cell precision gauge, colored by pressure
  W=14; cells=$(( pct_i*W/100 )); frac=$(( (pct_i*W)%100 ))
  F=( " " "▏" "▎" "▍" "▌" "▋" "▊" "▉" "█" )
  gauge="▕"; for ((i=0;i<cells;i++)); do gauge+="${CCOL}█${RESET}"; done
  t=0; if [ "$frac" -gt 0 ] && [ "$cells" -lt "$W" ]; then gauge+="${CCOL}${F[$((frac*8/100))]}${RESET}"; t=1; fi
  for ((i=0;i< W-cells-t; i++)); do gauge+="${DIM}░${RESET}"; done
  gauge+="▏"
  eta=""
  if [ -n "$src" ] && [ "$total" -gt 0 ]; then
    el2=$(( now - src )); [ "$el2" -lt 1 ] && el2=1
    ml=$(( el2 * rem / total / 60 ))
    if [ "$ml" -lt 60 ]; then eta=" ~${ml}m left"; else eta=" ~$((ml/60))h$((ml%60))m left"; fi
  fi
  line3="${DIM}context${RESET} ${gauge} ${CCOL}${pct_i}%${RESET}${DIM} $((total/1000))K/$((max/1000))K${RESET}${GREY}${eta}${RESET}"
fi

# ------------------------------------------------------------------ L4 ----
# CPU per-core bricks + pressure (fast: delta vs stored counters, no sleep).
line4=""
if [ -r /proc/stat ]; then
  declare -A c
  for i in $(seq 0 $((NCPU-1))); do
    line=$(awk -v ccu="cpu$i" '$1==ccu{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat 2>/dev/null)
    read -r us ni sy id io ir sft st <<<"$line"
    c[${i}_t]=$(( us+ni+sy+id+io+ir+sft+st )); c[${i}_i]=$(( id+io ))
  done
  BRICKS=( "⣀" "⣠" "⣤" "⣴" "⣶" "⣾" "⣿" )
  strip=""; tsum=0; hot=""
  for i in $(seq 0 $((NCPU-1))); do
    pct=0
    pt2=${S[c${i}_t]:-}; pi2=${S[c${i}_i]:-}
    if [ -n "$pt2" ] && [ -n "$pi2" ]; then
      td=$(( c[${i}_t] - pt2 )); [ "$td" -lt 1 ] && td=1
      busy=$(( td - (c[${i}_i] - pi2) ))
      pct=$(( busy*100/td )); [ "$pct" -gt 100 ] && pct=100
    fi
    tsum=$(( tsum + pct ))
    idx=$(( pct*6/100 )); [ "$idx" -gt 6 ] && idx=6
    strip+="$(core_color "$pct")${BRICKS[$idx]}${RESET}"
    [ "$pct" -ge 80 ] && hot="${hot:+$hot,}c$(printf '%02d' "$i")"
    S[c${i}_t]=${c[${i}_t]}; S[c${i}_i]=${c[${i}_i]}
  done
  overall=$(( tsum/NCPU ))
  line4="${DIM}cpu${RESET} $(col_pct "$overall")${overall}%${RESET}  ${strip}"
  [ -n "$hot" ] && line4+="  ${RED}hot:${hot}${RESET}"
fi

# GPU/VRAM + RAM pressure (cheap local reads).
ghost=$(printf '%s' "$resp" | jq -r '.models[0].size_vram // 0' 2>/dev/null)
gtt=$(cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1 | tr -d ' ')
if [ -n "$ghost" ] && [ -n "$gtt" ] && [ "${ghost:-0}" -gt 0 ] 2>/dev/null && [ "${gtt:-0}" -gt 0 ]; then
  gp=$(( ghost*100/gtt )); [ "$gp" -gt 100 ] && gp=100
  line4+="  ${DIM}vram${RESET} $(col_pct "$gp")${gp}%${RESET}"
fi
memtotal=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
memavail=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
if [ -n "$memtotal" ] && [ -n "$memavail" ] && [ "$memtotal" -gt 0 ] 2>/dev/null; then
  ru=$(( memtotal - memavail )); rpct=$(( ru*100/memtotal )); [ "$rpct" -gt 100 ] && rpct=100
  line4+="  ${DIM}ram${RESET} $(col_pct "$rpct")${rpct}%${RESET}"
fi

save_state

# ------------------------------------------------------------------ emit ----
out=""
[ -n "$line1" ] && out+="${line1}\n"
[ -n "$line2" ] && out+="${line2}\n"
[ -n "$line3" ] && out+="${line3}\n"
[ -n "$line4" ] && out+="${line4}\n"
printf '%b' "$out"
