cat > greet.py <<'PY'
import argparse

def build_parser():
    p = argparse.ArgumentParser(prog="greet")
    p.add_argument("name")
    return p

def main(argv=None):
    args = build_parser().parse_args(argv)
    print(f"Hello, {args.name}!")

if __name__ == "__main__":
    main()
PY
cat > README.md <<'MD'
# greet

Usage:

    python3 greet.py NAME

Options:

- (none yet)
MD
