mkdir -p app
cat > app/__init__.py <<'PY'
PY
cat > app/pricing.py <<'PY'
def calc(items):
    return sum(p * q for p, q in items)
PY
cat > app/report.py <<'PY'
from app.pricing import calc

def summary(items):
    return f"total={calc(items)}"
PY
cat > app/cli.py <<'PY'
from app.pricing import calc
from app.report import summary

def main():
    items = [(2.0, 3), (1.5, 2)]
    print(calc(items))
    print(summary(items))

if __name__ == "__main__":
    main()
PY
cat > test_app.py <<'PY'
from app.cli import main
main()
PY
