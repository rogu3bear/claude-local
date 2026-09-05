[ -f ANSWER.txt ] || exit 1
[ "$(tr -d '[:space:]"' < ANSWER.txt)" = "src/core/settings.py:4.7.1" ] || exit 1
