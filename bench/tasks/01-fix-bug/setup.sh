cat > stats.py <<'PY'
def running_max(xs):
    """Return a list where element i is the max of xs[0..i] inclusive."""
    out = []
    cur = None
    for i in range(1, len(xs)):
        v = xs[i]
        cur = v if cur is None or v > cur else cur
        out.append(cur)
    return out
PY
cat > test_stats.py <<'PY'
from stats import running_max
def test_basic():
    assert running_max([3, 1, 4, 1, 5]) == [3, 3, 4, 4, 5]
def test_single():
    assert running_max([7]) == [7]
def test_empty():
    assert running_max([]) == []
if __name__ == "__main__":
    test_basic(); test_single(); test_empty(); print("ALL PASS")
PY
