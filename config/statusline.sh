#!/usr/bin/env bash
# claude-local statusline: a task-manager-style operator cockpit for the
# isolated local setup. Claude Code pipes a JSON payload on stdin after every
# turn; the script also reads live server state, the usage proxy log, GPU
# activity (for a "thinking" signal), per-core CPU, VRAM, RAM. All reads are
# local and fast.
#
# Layout:
#   mln-web:main *3   ● qwen3-coder:30b  12m4s               <- repo | api+model | timer
#   ◐ thinking  84 tok/s   cache 98%  prompt 47K (+312)  3.1s <- live turn + cache stats
#   context ▕████░░░░░░░░░░▏ 24% 47K/200K ~1h12m left        <- context pressure gauge
#   cpu 22%  [bricks]  hot:c00,c06  vram 39% ram 43%
#
# State is per session: the launcher exports CLAUDE_LOCAL_SESSION_DIR (falls
# back to the config dir when claude is launched by hand). No blocking sleeps;
# CPU % is a delta against counters persisted from the previous tick; git
# status is cached for 10s.
set -uo pipefail

input=$(cat)
RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
GREY=$'\033[90m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
CYAN=$'\033[36m'; MAGENTA=$'\033[35m'

CONFIG_DIR="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
SESSION_DIR="${CLAUDE_LOCAL_SESSION_DIR:-$CONFIG_DIR}"
[ -r "$CONFIG_DIR/env" ] && . "$CONFIG_DIR/env"
PORT="${CLAUDE_LOCAL_PORT:-1234}"
STATE="$SESSION_DIR/statusline.state"
NCPU=$(nproc 2>/dev/null || echo 8)
GIT_CACHE_S=10

# -------------------------------------------------------- helpers/state ----
load_state() { declare -gA S; [ -f "$STATE" ] && while IFS='=' read -r k v; do [ -n "$k" ] && S["$k"]="$v"; done < "$STATE"; }
save_state() { local f k; f=$(mktemp); for k in "${!S[@]}"; do printf '%s=%s\n' "$k" "${S[$k]}" >> "$f"; done; mv "$f" "$STATE"; }
load_state

col_pct() { if   [ "$1" -lt 70 ]; then printf '\033[32m'
  elif [ "$1" -lt 90 ]; then printf '\033[33m'; else printf '\033[31m'; fi; }
core_color() { if   [ "$1" -lt 20 ]; then printf '\033[2m'
  elif [ "$1" -lt 50 ]; then printf '\033[32m'
  elif [ "$1" -lt 80 ]; then printf '\033[33m'; else printf '\033[31m'; fi; }
fmt_k() { if [ "$1" -ge 1000 ]; then echo "$(( $1 / 1000 ))K"; else echo "$1"; fi; }

now=$(date +%s)

# ------------------------------------------------------------------ L1 ----
# Repo+git (cached), server/model state, session timer.
line1=""
cur_dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null)
[ -z "$cur_dir" ] && cur_dir="$PWD"
gitroot=$cur_dir
while [ "$gitroot" != "/" ] && [ ! -d "$gitroot/.git" ]; do gitroot=$(dirname "$gitroot"); done
if [ -d "$gitroot/.git" ]; then
  proj=$(basename "$gitroot")
  if [ "${S[git_root]:-}" = "$gitroot" ] && [ $(( now - ${S[git_ts]:-0} )) -lt "$GIT_CACHE_S" ]; then
    branch=${S[git_branch]:-}; dirty=${S[git_dirty]:-0}
  else
    branch=$(git -C "$gitroot" branch --show-current 2>/dev/null); branch=${branch:-detached}
    dirty=$(git -C "$gitroot" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    S[git_root]=$gitroot; S[git_ts]=$now; S[git_branch]=$branch; S[git_dirty]=$dirty
  fi
  line1="${BOLD}${proj}${RESET}${GREY}:${RESET}${BOLD}${branch}${RESET}"
  [ "${dirty:-0}" -gt 0 ] && line1+="${YELLOW}*${dirty}${RESET}"
else
  line1="${BOLD}$(basename "$cur_dir")${RESET}"
fi

# Server status + the model in use. The model comes from Claude Code's payload, so it
# follows a mid-session `/model <preset>`; the server says whether it is resident.
# States: online+loaded, online+loading, online+not loaded, online+empty, offline.
session_model=$(cat "$SESSION_DIR/session_model" 2>/dev/null || echo "")
want=$(printf '%s' "$input" | jq -r '.model.id // .model.display_name // empty' 2>/dev/null)
[ -z "$want" ] && want="$session_model"
model=""; resp=""; loaded=""; mstate=""
BACKEND="${CLAUDE_LOCAL_BACKEND:-ollama}"
if [ "$BACKEND" = ollama ]; then
  resp=$(curl -s --max-time 1 "http://localhost:${PORT}/api/ps" 2>/dev/null)
  [ -n "$resp" ] && loaded=$(printf '%s' "$resp" | jq -r '[.models[].name] | join(",")' 2>/dev/null)
else
  resp=$(curl -sf --max-time 1 "http://localhost:${PORT}/models" 2>/dev/null)
  if [ -n "$resp" ] && printf '%s' "$resp" | jq -e '.data[0].status != null' >/dev/null 2>&1; then   # router mode
    loaded=$(printf '%s' "$resp" | jq -r '[.data[] | select(.status.value == "loaded") | .id] | join(",")' 2>/dev/null)
    [ -n "$want" ] && mstate=$(printf '%s' "$resp" | jq -r --arg m "$want" '.data[] | select(.id == $m) | (.status.value // "unloaded")' 2>/dev/null)
  elif [ -n "$resp" ]; then                                                                              # single-model server
    loaded=$(printf '%s' "$resp" | jq -r '[.data[].id] | join(",")' 2>/dev/null)
  fi
fi
if [ -n "$want" ] && [ -z "$mstate" ]; then
  case ",$loaded," in *",$want,"*) mstate=loaded ;; *) mstate=unloaded ;; esac
fi
model="${want:-${loaded%%,*}}"
if [ -z "$resp" ]; then
  line1+="  ${RED}● offline${RESET}   ${RED}api down${RESET}"
elif [ -z "$model" ]; then
  line1+="  ${YELLOW}● no model loaded${RESET} ${GREY}(idle)${RESET}"
else
  case "$mstate" in
    loaded)  line1+="  ${GREEN}●${RESET} ${BOLD}${model}${RESET}" ;;
    loading) line1+="  ${YELLOW}◐${RESET} ${BOLD}${model}${RESET} ${YELLOW}loading${RESET}" ;;
    *)       line1+="  ${YELLOW}●${RESET} ${BOLD}${model}${RESET} ${YELLOW}not loaded${RESET}" ;;
  esac
  [ -n "$session_model" ] && [ "$model" != "$session_model" ] && line1+=" ${GREY}(was ${session_model})${RESET}"
fi

src=$(cat "$SESSION_DIR/session_start" 2>/dev/null || echo "")
if [ -n "$src" ]; then
  el=$(( now - src )); [ "$el" -lt 0 ] && el=0
  m=$(( el/60 )); s=$(( el%60 ))
  if [ "$m" -lt 60 ]; then rt="${m}m${s}s"; else rt="$((m/60))h$((m%60))m"; fi
  line1+="  ${GREY}${rt}${RESET}"
fi

# ------------------------------------------------------------------ L2 ----
# Thinking indicator (GPU busy % OR runner CPU-time growth), then the last
# turn's real numbers from the usage proxy: output tok/s, cache hit %, prompt
# size (+uncached tokens), turn latency.
line2=""
thinking=""
if [ -n "$resp" ]; then
  gbusy=0
  for f in /sys/class/drm/card*/device/gpu_busy_percent; do
    [ -r "$f" ] && { gbusy=$(cat "$f" 2>/dev/null); break; }
  done
  [ "${gbusy:-0}" -ge 20 ] 2>/dev/null && thinking=1
  # the runner that owns our port (Ollama's runner and our llama-server both match by name)
  lls=$(ss -ltnp 2>/dev/null | awk -v p=":${PORT}" '$4 ~ p"$" {print $NF}' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
  [ -n "$lls" ] && [ "$BACKEND" = ollama ] && lls=$(pgrep -P "$lls" -f llama-server | head -1)
  [ -n "$lls" ] || lls=$(pgrep -f "llama-server" | head -1)
  if [ -n "$lls" ]; then
    mcs=$(awk -v p="$lls" '$1==p { print ($14+$15)*10 }' /proc/"$lls"/stat 2>/dev/null)
    if [ -n "$mcs" ]; then
      pm=${S[lmcs]:-}; pts=${S[lmts]:-}
      if [ -n "$pm" ] && [ -n "$pts" ] && [ "$now" -gt "$pts" ]; then
        dt=$(( now - pts )); [ "$dt" -lt 1 ] && dt=1
        dm=$(( mcs - pm )); [ "$dm" -lt 0 ] && dm=0
        [ $(( dm / dt )) -ge 800 ] && thinking=1
      fi
      S[lmcs]=$mcs; S[lmts]=$now
    fi
  fi
  if [ -n "$thinking" ]; then
    spinners=( "◐" "◓" "◑" "◒" )
    line2="${MAGENTA}${spinners[$(( now % 4 ))]}${RESET} ${BOLD}thinking${RESET}"
  else
    line2="${DIM}· idle${RESET}"
  fi
else
  line2="${RED}!! offline${RESET}"
fi

usage_line=$(tail -n 1 "$SESSION_DIR/usage.jsonl" 2>/dev/null || true)
if [ -n "$usage_line" ]; then
  read -r u_tps u_cache u_prompt u_new u_ms <<<"$(printf '%s' "$usage_line" \
    | jq -r '[(.out_tps|floor), .cache_pct, .prompt, .input, .ms] | @tsv' 2>/dev/null | tr '\t' ' ')"
  if [ -n "${u_ms:-}" ]; then
    CC=$(col_pct $(( 100 - u_cache )))
    line2+="  ${BOLD}${u_tps}${RESET}${DIM} tok/s${RESET}"
    line2+="  ${DIM}cache${RESET} ${CC}${u_cache}%${RESET}"
    line2+="  ${DIM}prompt${RESET} $(fmt_k "$u_prompt") ${GREY}(+${u_new})${RESET}"
    line2+="  ${GREY}$(awk -v ms="$u_ms" 'BEGIN{printf "%.1fs", ms/1000}')${RESET}"
  fi
fi

# ------------------------------------------------------------------ L3 ----
# Context pressure gauge.
line3=""
ctx_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
if [ -n "$ctx_pct" ]; then
  used=$(printf '%s' "$input" | jq -r '.context_window.total_input_tokens // 0')
  out=$(printf '%s' "$input" | jq -r '.context_window.total_output_tokens // 0')
  max=$(printf '%s' "$input" | jq -r '.context_window.context_window_size // 0')
  # Claude assumes 200K for unknown models; the launcher records the real
  # autocompact window (server context minus output headroom). Use that.
  cmax=$(cat "$SESSION_DIR/context_max" 2>/dev/null || echo "")
  if [ -n "$cmax" ] && [ "$cmax" -gt 0 ] 2>/dev/null; then
    max=$cmax
    ctx_pct=$(( (used + out) * 100 / max ))
  fi
  pct_i=$(printf '%.0f' "$ctx_pct"); [ "$pct_i" -gt 100 ] && pct_i=100; [ "$pct_i" -lt 0 ] && pct_i=0
  total=$(( used + out )); rem=$(( max - total )); [ "$rem" -lt 0 ] && rem=0
  CCOL=$(col_pct "$pct_i")
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
# CPU per-core bricks + pressure (delta vs stored counters, no sleep).
line4=""
if [ -r /proc/stat ]; then
  declare -A c
  while read -r name us ni sy id io ir sft st _; do
    [[ "$name" =~ ^cpu([0-9]+)$ ]] || continue
    i=${BASH_REMATCH[1]}
    c[${i}_t]=$(( us+ni+sy+id+io+ir+sft+st )); c[${i}_i]=$(( id+io ))
  done < /proc/stat
  BRICKS=( "⣀" "⣠" "⣤" "⣴" "⣶" "⣾" "⣿" )
  strip=""; tsum=0; hot=""; ncount=0
  for i in $(seq 0 $((NCPU-1))); do
    [ -n "${c[${i}_t]:-}" ] || continue
    pct=0
    pt2=${S[c${i}_t]:-}; pi2=${S[c${i}_i]:-}
    if [ -n "$pt2" ] && [ -n "$pi2" ]; then
      td=$(( c[${i}_t] - pt2 )); [ "$td" -lt 1 ] && td=1
      busy=$(( td - (c[${i}_i] - pi2) ))
      pct=$(( busy*100/td )); [ "$pct" -gt 100 ] && pct=100; [ "$pct" -lt 0 ] && pct=0
    fi
    tsum=$(( tsum + pct )); ncount=$(( ncount + 1 ))
    idx=$(( pct*6/100 )); [ "$idx" -gt 6 ] && idx=6
    strip+="$(core_color "$pct")${BRICKS[$idx]}${RESET}"
    [ "$pct" -ge 80 ] && hot="${hot:+$hot,}c$(printf '%02d' "$i")"
    S[c${i}_t]=${c[${i}_t]}; S[c${i}_i]=${c[${i}_i]}
  done
  overall=$(( tsum / (ncount > 0 ? ncount : 1) ))
  line4="${DIM}cpu${RESET} $(col_pct "$overall")${overall}%${RESET}  ${strip}"
  [ -n "$hot" ] && line4+="  ${RED}hot:${hot}${RESET}"
fi

ghost=$(printf '%s' "$resp" | jq -r '.models[0].size_vram // .data[0].meta.size // 0' 2>/dev/null)
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

out=""
[ -n "$line1" ] && out+="${line1}\n"
[ -n "$line2" ] && out+="${line2}\n"
[ -n "$line3" ] && out+="${line3}\n"
[ -n "$line4" ] && out+="${line4}\n"
printf '%b' "$out"
