python3 - <<'PY'
import random
rnd = random.Random(20260905)
nouns = ["order","invoice","ticket","shipment","account","report","batch","record","session","device"]
verbs = ["validate","normalize","merge","archive","score","route","expand","compact","audit","replay"]
L = []
L += ['"""Inventory processing module (generated fixture)."""', "", "from collections import defaultdict", "",
      "TIER_TABLE = {", "    'bronze': 1.0,", "    'silver': 1.15,", "    'gold': 1.3,", "}", "",
      "", "def _bucket(item):",
      '    """Return (name, qty) for an inventory item dict.',
      "",
      "    name is the item's SKU string, qty its integer quantity. Callers must",
      "    unpack in this order.",
      '    """',
      "    return item['sku'], int(item.get('qty', 0))", ""]
pairs = set()
while len(pairs) < 40:
    pairs.add((rnd.choice(verbs), rnd.choice(nouns)))
for i, (v, n) in enumerate(sorted(pairs)):
    k = rnd.randint(2, 6); m = rnd.randint(1, 9)
    L += [f"", f"def handle_{n}_{v}(records, limit={rnd.randint(5, 50)}):",
          f'    """{v.title()} each {n} record and return a summary dict.',
          f"", f"    Records are dicts with an id and a value; only the first ``limit``", f"    records are considered.",
          f'    """', "    totals = defaultdict(float)", "    for idx, rec in enumerate(records):",
          "        if idx >= limit:", "            break",
          f"        key = rec.get('{n}_id', idx) % {k}",
          f"        totals[key] += abs(rec.get('value', 0)) + {m}",
          "    return {'count': min(len(records), limit), 'totals': dict(totals)}", ""]
L += ["", "def summarize_stock(items):",
      '    """Total quantity per SKU across items, using _bucket for unpacking."""',
      "    totals = defaultdict(int)", "    for it in items:",
      "        qty, name = _bucket(it)",   # BUG: reversed unpack
      "        totals[name] += qty", "    return dict(totals)", "",
      "", "def apply_tier(totals, tier):", '    """Scale totals by the tier multiplier."""',
      "    mult = TIER_TABLE.get(tier, 1.0)", "    return {k: round(v * mult, 2) for k, v in totals.items()}", ""]
open("inventory.py", "w").write("\n".join(L))
tests = ['from inventory import *', '',
 'def test_handlers():']
names = [f"handle_{n}_{v}" for v, n in sorted(pairs)][:4]
for nm in names:
    tests.append(f"    r = {nm}([{{'value': 2}}, {{'value': -3}}]); assert r['count'] == 2 and sum(r['totals'].values()) > 0")
tests += ['', 'def test_summarize():',
 "    t = summarize_stock([{'sku': 'A1', 'qty': 2}, {'sku': 'B2', 'qty': 5}, {'sku': 'A1', 'qty': 3}])",
 "    assert t == {'A1': 5, 'B2': 5}, t", '', 'def test_tier():',
 "    assert apply_tier({'A1': 10}, 'gold') == {'A1': 13.0}", '',
 'if __name__ == "__main__":', '    test_handlers(); test_summarize(); test_tier(); print("ALL PASS")']
open("test_inventory.py", "w").write("\n".join(tests) + "\n")
PY
