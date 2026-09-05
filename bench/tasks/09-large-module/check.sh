rm -rf __pycache__
PYTHONDONTWRITEBYTECODE=1 python3 test_inventory.py 2>/dev/null | grep -q 'ALL PASS' || exit 1
git diff --quiet -- test_inventory.py || exit 1
[ "$(wc -l < inventory.py)" -ge 580 ] || exit 1
changed=$(git diff --numstat -- inventory.py | awk '{print $1+$2}'); [ "${changed:-0}" -le 20 ] || exit 1
