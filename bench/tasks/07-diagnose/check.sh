python3 test_geo.py 2>/dev/null | grep -q 'ALL PASS' || exit 1
git diff --quiet -- test_geo.py || exit 1
