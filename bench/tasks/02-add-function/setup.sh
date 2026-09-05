cat > utils.py <<'PY'
"""Small string helpers."""

def truncate(s, n):
    return s if len(s) <= n else s[:n]
PY
