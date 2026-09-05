python3 test_stats.py 2>/dev/null | grep -q 'ALL PASS' || exit 1
git diff --quiet -- test_stats.py || exit 1   # test must be untouched
