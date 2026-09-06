# Overnight comparison 2026-09-06

Stack: kernel=7.0.0-31-generic fw(pfp/mec/mes)=35/24/91 mesa=Mesa 25.2.8 glslc=2023.8 llama.cpp=6a1a922d2 ollama=0.33.3 rocm=7.14

## Full bench (bench/compare.py)
```
label               n  pass  pass% wall_mean wall_med turns prompt_tok cache% out_tok     ctx
fb-ls-vk-core      27    27   100%     39.5s    36.4s  13.9      99045    97%    2147  131072
intdot-vk-core     27    27   100%     40.3s    33.4s  14.4     102142    97%    2052  131072
q36-mtp2-core      27    27   100%     12.3s    11.7s   6.4      30631    88%     522  131072
q36-vk-core        27    27   100%     14.7s    14.2s   6.4      31621    89%     509  131072

task                 fb-ls-vk-core  intdot-vk-core   q36-mtp2-core     q36-vk-core
01-fix-bug             3/3    67s      3/3    41s      3/3    12s      3/3    13s 
02-add-function        3/3    32s      3/3    44s      3/3    10s      3/3    13s 
03-rename-symbol       3/3    39s      3/3    42s      3/3    18s      3/3    22s 
04-write-script        3/3    33s      3/3    52s      3/3     9s      3/3    11s 
05-find-answer         3/3    44s      3/3     8s      3/3     5s      3/3     6s 
06-json-edit           3/3    13s      3/3    10s      3/3     8s      3/3     9s 
07-diagnose            3/3    38s      3/3    39s      3/3    14s      3/3    16s 
08-cli-flag            3/3    43s      3/3    93s      3/3    15s      3/3    20s 
09-large-module        3/3    45s      3/3    33s      3/3    21s      3/3    22s 

(* = at least one run hit the timeout)

fb-ls-vk-core: flags=--append-system-prompt-file /tmp/claude-1000/-home-mln-dev-dev/857433d9-0713-490b-82fa-f0c026685849/scratchpad/bench/sp.md --exclude-dynamic-system-prompt-sections --autocompact 120832 --tools Bash\,Read\,Edit\,Write\,Grep\,Glob 
  server=LLAMA_ARG_CTX_SIZE=131072 LLAMA_ARG_CACHE_TYPE_K=q8_0 LLAMA_ARG_UBATCH=2048 LLAMA_DEVICE=Vulkan0 LLAMA_ARG_SPEC_DRAFT_N_MAX=8
  notes=llama-server build-vulkan Vulkan0 no spec; gpu 65C at start; --tools core; kernel=7.0.0-31-generic fw(pfp/mec/mes)=31/22/86 mesa=Mesa 25.2.8 glslc=2023.8 llama.cpp=6a1a922d2 ollama=0.33.3 rocm=7.14

intdot-vk-core: flags=--append-system-prompt-file /tmp/claude-1000/-home-mln-dev-dev/857433d9-0713-490b-82fa-f0c026685849/scratchpad/bench/sp.md --exclude-dynamic-system-prompt-sections --autocompact 120832 --tools Bash\,Read\,Edit\,Write\,Grep\,Glob 
  server=LLAMA_ARG_CTX_SIZE=131072 LLAMA_ARG_CACHE_TYPE_K=q8_0 LLAMA_ARG_UBATCH=2048 LLAMA_DEVICE=Vulkan0 LLAMA_ARG_SPEC_DRAFT_N_MAX=8
  notes=llama-server 6a1a922d2 build-vulkan rebuilt with LunarG glslc 2026.3 (892 q8_1 variants); gpu 72C at start

q36-mtp2-core: flags=--append-system-prompt-file /home/mln-dev/.claude-local/system_prompt.md --exclude-dynamic-system-prompt-sections --autocompact 120832 --tools Bash\,Read\,Edit\,Write\,Grep\,Glob 
  server=LLAMA_ARG_CTX_SIZE=131072 LLAMA_ARG_CACHE_TYPE_K=q8_0 LLAMA_ARG_UBATCH=2048 LLAMA_DEVICE=Vulkan0 LLAMA_ARG_SPEC_DRAFT_N_MAX=8
  notes=Qwen3.6-35B-A3B UD-Q4_K_XL (MTP-embedded), non-thinking, draft-mtp n-max 2; kernel=7.0.0-31-generic fw(pfp/mec/mes)=35/24/91 mesa=Mesa 25.2.8 glslc=2023.8 llama.cpp=6a1a922d2 ollama=0.33.3 rocm=7.14

q36-vk-core: flags=--append-system-prompt-file /home/mln-dev/.claude-local/system_prompt.md --exclude-dynamic-system-prompt-sections --autocompact 120832 --tools Bash\,Read\,Edit\,Write\,Grep\,Glob 
  server=LLAMA_ARG_CTX_SIZE=131072 LLAMA_ARG_CACHE_TYPE_K=q8_0 LLAMA_ARG_UBATCH=2048 LLAMA_DEVICE=Vulkan0 LLAMA_ARG_SPEC_DRAFT_N_MAX=8
  notes=Qwen3.6-35B-A3B UD-Q4_K_XL, non-thinking, no speculation; kernel=7.0.0-31-generic fw(pfp/mec/mes)=35/24/91 mesa=Mesa 25.2.8 glslc=2023.8 llama.cpp=6a1a922d2 ollama=0.33.3 rocm=7.14
```

## Microbench (tok/s; microbench.py --summary)
```
label                size  nout  warm  prefill_tps  decode_tps  ttft_s  wall_s prompt_n  pred_n  n
fork-vk              2700   128     -         1525        78.9    1.81     3.4     2696     128  3
fork-vk              2700   512     -         1534        79.0    1.80     8.3     2696     512  3
fork-vk             10000   128     -         1232        68.7    8.20    10.1     9972     128  3
fork-vk             10000   512     -         1226        67.8    8.26    15.8     9972     512  3
fork-vk             30000   128     -          722        51.3   41.78    44.2    29980     128  3
fork-vk             30000   512     -          666        50.4   45.39    55.7    29980     512  3
fork-vk            100000   128     -          261        25.5  384.41   389.4    99940     128  2
fork-vk              2700   128   yes          180        78.9    0.28     1.9        7     128  3
fork-vk             10000   128   yes          128        68.3    0.06     1.9        7     128  3
fork-vk             30000   128   yes           72        49.3    0.12     2.7        7     128  3
fork-vk            100000   128   yes           76        25.3    2.48     7.5      287     128  2
intdot-vk            2700   128     -         1246        73.8    2.21     3.9     2697     128  3
intdot-vk            2700   512     -         1243        73.0    2.22     9.2     2697     512  3
intdot-vk           10000   128     -          998        63.6   10.12    12.1     9973     128  3
intdot-vk           10000   512     -          985        63.1   10.26    18.4     9973     512  3
intdot-vk           30000   128     -          571        46.5   52.87    55.6    29981     128  3
intdot-vk           30000   512     -          554        45.1   54.51    65.9    29981     512  3
intdot-vk          100000   128     -          225        21.4  445.61   451.6    99941     128  2
intdot-vk            2700   128   yes          171        72.9    0.29     2.0        7     128  3
intdot-vk           10000   128   yes          120        62.1    0.07     2.1        7     128  3
intdot-vk           30000   128   yes           67        43.0    0.14     3.1        7     128  3
ls-hip               2700   128     -         1525        56.9    1.81     4.0     2696     128  3
ls-hip               2700   512     -         1520        56.3    1.82    10.9     2696     512  3
ls-hip              10000   128     -         1289        41.3    7.87    11.0     9972     128  3
ls-hip              10000   512     -         1272        40.4    8.01    20.7     9972     512  3
ls-hip              30000   128     -          762        22.6   39.73    45.3    29980     128  3
ls-hip              30000   512     -          765        22.0   39.72    63.2    29980     512  3
ls-hip             100000   128     -          302         7.6  331.79   348.6    99940     128  2
ls-hip               2700   128   yes          162        56.0    0.05     2.3        7     128  3
ls-hip              10000   128   yes          126        40.8    0.07     3.2        7     128  3
ls-hip              30000   128   yes           82        21.7    0.20     7.0        7     128  3
ls-vk                2700   128     -         1213        77.3    2.25     3.9     2696     128  3
ls-vk                2700   512     -         1183        71.5    2.34     9.5     2696     512  3
ls-vk               10000   128     -          952        62.5   10.60    12.8     9972     128  3
ls-vk               10000   512     -          959        60.7   10.53    19.0     9972     512  3
ls-vk               30000   128     -          561        43.1   53.71    56.7    29980     128  3
ls-vk               30000   512     -          427        41.1   70.85    82.8    29980     512  3
ls-vk              100000   128     -          226        22.5  443.46   449.2    99940     128  2
ls-vk                2700   128   yes          148        71.7    0.16     1.9        7     128  3
ls-vk               10000   128   yes          102        60.3    0.09     2.2        7     128  3
ls-vk               30000   128   yes           64        43.3    0.15     3.1        7     128  3
ollama-vk            2700   128     -         1106        72.9    2.48     4.2     2698     128  3
ollama-vk            2700   512     -         1091        72.4    2.53     9.6     2698     512  3
ollama-vk           10000   128     -          768        59.7   13.12    15.3     9974     128  3
ollama-vk           10000   512     -          768        58.0   13.15    21.9     9974     512  3
ollama-vk           30000   128     -          402        41.9   74.81    77.8    29982     128  3
ollama-vk           30000   512     -          399        41.3   75.71    89.4    29982     512  3
ollama-vk          100000   128     -          138         8.2  725.31   740.9    99942     128  2
ollama-vk            2700   128   yes        11327        71.1    0.29     2.1     3244     128  3
ollama-vk           10000   128   yes       164318        57.5    0.08     2.3    10520     128  3
ollama-vk           30000   128   yes       187376        40.4    0.22     3.4    30528     128  3
q36-mtp2             2700   128     -          821        68.8    3.44     5.3     2773     128  3
q36-mtp2             2700   512     -          804        73.1    3.51    10.5     2773     512  3
q36-mtp2            10000   128     -          762        65.7   13.07    15.0     9906     128  3
q36-mtp2            10000   512     -          751        68.5   13.28    20.8     9906     512  3
q36-mtp2            30000   128     -          666        53.9   45.17    47.6    29968     128  3
q36-mtp2            30000   512     -          663        64.9   45.37    53.5    29968     512  3
q36-mtp2           100000   128     -          449        43.9  222.66   225.6    99919     128  2
q36-mtp2             2700   128   yes          759        82.1    2.77     4.3     2048     128  3
q36-mtp2            10000   128   yes          683        78.6    3.04     4.7     2048     128  3
q36-mtp2            30000   128   yes          553        68.7    3.80     5.6     2048     128  3
q36-mtp2           100000   128   yes          289        45.7    8.12    11.0     2329     128  2
q36-vk               2700   128     -          937        54.4    3.01     5.4     2772     128  3
q36-vk               2700   512     -          894        54.6    3.16    12.5     2772     512  3
q36-vk              10000   128     -          856        52.4   11.64    14.1     9905     128  3
q36-vk              10000   512     -          864        51.9   11.55    21.4     9905     512  3
q36-vk              30000   128     -          739        47.3   40.68    43.4    29967     128  3
q36-vk              30000   512     -          742        47.3   40.51    51.2    29967     512  3
q36-vk             100000   128     -          522        37.4  191.87   195.3    99918     128  2
q36-vk               2700   128   yes          884        54.5    2.32     4.7     2048     128  3
q36-vk              10000   128   yes          812        52.4    2.56     5.0     2048     128  3
q36-vk              30000   128   yes          646        47.6    3.19     5.9     2048     128  3
q36-vk             100000   128   yes          347        37.0    6.79    10.2     2329     128  2
vk-kvf16             2700   128     -         1217        77.1    2.29     4.0     2698     128  3
vk-kvf16             2700   512     -         1194        75.5    2.34     9.1     2698     512  3
vk-kvf16            10000   128     -          719        57.9   14.09    16.3     9974     128  3
vk-kvf16            10000   512     -          714        58.4   14.20    23.0     9974     512  3
vk-kvf16            30000   128     -          281        32.4  107.05   112.1    29982     128  3
vk-kvf16            30000   512     -          284        31.9  106.48   122.5    29982     512  3
vk-kvf16             2700   128   yes          168        72.9    0.05     1.8        7     128  3
vk-kvf16            10000   128   yes          126        57.8    0.07     2.3        7     128  3
vk-kvf16            30000   128   yes           51        26.1    0.17     5.1        7     128  3
vk-ngram-cache       2700   512     -         1216        40.8    2.27    14.8     2697     512  3
vk-ngram-cache      10000   512     -          954        26.0   10.61    33.9     9973     512  3
vk-ngram-cache       2700   128   yes          155        39.7    0.06     3.7        7     128  3
vk-ngram-cache      10000   128   yes           72        19.3    0.12     7.3        7     128  3
vk-ngram-mod         2700   512     -          703        35.1    3.92    18.6     2697     512  3
vk-ngram-mod        10000   512     -          951        55.2   10.63    19.8     9973     512  3
vk-ngram-mod         2700   128   yes          159        75.2    0.09     1.8        7     128  3
vk-ngram-mod        10000   128   yes          101        58.0    0.09     2.3        7     128  3
vk-spec16            2700   512     -          907        10.7    3.15    52.0     2697     512  3
vk-spec16           10000   512     -          830        17.1   12.29    42.2     9973     512  3
vk-spec16            2700   128   yes          136        10.3    0.06    12.8        7     128  3
vk-spec16           10000   128   yes           98         8.1    0.09    16.8        7     128  3
vk-spec3             2700   512     -          747        24.7    3.78    24.1     2696     512  3
vk-spec3            10000   512     -          699        26.5   14.57    32.4     9972     512  3
vk-spec3             2700   128   yes           86        18.6    0.17     7.1        7     128  3
vk-spec3            10000   128   yes           53         9.2    0.16    14.2        7     128  3
vk-spec8             2700   512     -         1060        17.8    2.68    32.7     2696     512  3
vk-spec8            10000   512     -          623        13.0   16.51    55.6     9972     512  3
vk-spec8             2700   128   yes           99        10.5    0.08    12.6        7     128  3
vk-spec8            10000   128   yes           43         6.3    0.18    21.7        7     128  3
```

Device-loss / ring-timeout lines this boot: 0

## Follow-up: fork + Qwen3.6 + MTP (chain B, 01:59)
```
label               n  pass  pass% wall_mean wall_med turns prompt_tok cache% out_tok     ctx
fb-ollama-vk-core  27    27   100%     21.4s    20.8s   8.5      50060    95%    1071  131072
q36-vk-core        27    27   100%     14.7s    14.2s   6.4      31621    89%     509  131072
q36-mtp2-core      27    27   100%     12.3s    11.7s   6.4      30631    88%     522  131072
q36-fork-mtp2-core 27    26    96%     10.4s     9.5s   6.2      29651    88%     504  131072

task                fb-ollama-vk-c     q36-vk-core   q36-mtp2-core  q36-fork-mtp2-
01-fix-bug             3/3    23s      3/3    13s      3/3    12s      3/3    10s 
```
```
label                size  nout  warm  prefill_tps  decode_tps  ttft_s  wall_s prompt_n  pred_n  n
q36-fork-mtp2        2700   128     -         1414        64.8    2.02     4.1     2775     128  3
q36-fork-mtp2        2700   512     -         1414        67.8    2.02     9.6     2775     512  3
q36-fork-mtp2       10000   128     -         1378        58.1    7.28     9.5     9908     128  3
q36-fork-mtp2       10000   512     -         1376        66.5    7.29    15.0     9908     512  3
q36-fork-mtp2       30000   128     -         1148        52.8   26.27    28.6    29970     128  3
q36-fork-mtp2       30000   512     -         1146        61.1   26.32    34.7    29970     512  3
q36-fork-mtp2      100000   128     -          675        44.2  148.37   151.3    99921     128  2
q36-fork-mtp2        2700   128   yes         1415        85.1    1.45     3.4     2048     128  3
q36-fork-mtp2       10000   128   yes         1233        81.7    1.67     3.2     2048     128  3
q36-fork-mtp2       30000   128   yes          881        69.6    2.34     4.2     2048     128  3
q36-fork-mtp2      100000   128   yes          394        45.0    5.98     8.9     2329     128  2
q36-mtp2             2700   128     -          821        68.8    3.44     5.3     2773     128  3
q36-mtp2             2700   512     -          804        73.1    3.51    10.5     2773     512  3
q36-mtp2            10000   128     -          762        65.7   13.07    15.0     9906     128  3
q36-mtp2            10000   512     -          751        68.5   13.28    20.8     9906     512  3
q36-mtp2            30000   128     -          666        53.9   45.17    47.6    29968     128  3
q36-mtp2            30000   512     -          663        64.9   45.37    53.5    29968     512  3
q36-mtp2           100000   128     -          449        43.9  222.66   225.6    99919     128  2
q36-mtp2             2700   128   yes          759        82.1    2.77     4.3     2048     128  3
q36-mtp2            10000   128   yes          683        78.6    3.04     4.7     2048     128  3
q36-mtp2            30000   128   yes          553        68.7    3.80     5.6     2048     128  3
q36-mtp2           100000   128   yes          289        45.7    8.12    11.0     2329     128  2
q36-vk               2700   128     -          937        54.4    3.01     5.4     2772     128  3
q36-vk               2700   512     -          894        54.6    3.16    12.5     2772     512  3
q36-vk              10000   128     -          856        52.4   11.64    14.1     9905     128  3
q36-vk              10000   512     -          864        51.9   11.55    21.4     9905     512  3
q36-vk              30000   128     -          739        47.3   40.68    43.4    29967     128  3
q36-vk              30000   512     -          742        47.3   40.51    51.2    29967     512  3
q36-vk             100000   128     -          522        37.4  191.87   195.3    99918     128  2
q36-vk               2700   128   yes          884        54.5    2.32     4.7     2048     128  3
q36-vk              10000   128   yes          812        52.4    2.56     5.0     2048     128  3
q36-vk              30000   128   yes          646        47.6    3.19     5.9     2048     128  3
q36-vk             100000   128   yes          347        37.0    6.79    10.2     2329     128  2
```
