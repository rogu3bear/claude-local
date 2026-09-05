[ "$(python3 greet.py --shout bob 2>/dev/null)" = "HELLO, BOB!" ] || exit 1
[ "$(python3 greet.py bob 2>/dev/null)" = "Hello, bob!" ] || exit 1
grep -q -- '--shout' README.md || exit 1
