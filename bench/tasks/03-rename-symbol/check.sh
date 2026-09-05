out=$(python3 test_app.py 2>/dev/null) || exit 1
[ "$out" = $'9.0\ntotal=9.0' ] || exit 1
! grep -rqw 'calc' app/ test_app.py || exit 1
grep -q 'def compute_total' app/pricing.py || exit 1
