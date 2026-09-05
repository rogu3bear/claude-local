[ -x count_lines.sh ] || exit 1
[ "$(./count_lines.sh words.txt)" = "3" ] || exit 1
./count_lines.sh >/dev/null 2>&1; [ $? -eq 2 ] || exit 1
