python3 - <<'PY' || exit 1
from utils import slugify, truncate
assert slugify("Hello,  World! 2024") == "hello-world-2024"
assert slugify("--A_b--") == "a-b"
assert slugify("") == ""
assert truncate("abcdef", 3) == "abc"
PY
