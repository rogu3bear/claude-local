cat > test_geo.py <<'PY'
from geo import haversine_km, Point

def test_zero():
    a = Point(0.0, 0.0)
    assert haversine_km(a, a) == 0.0

def test_known():
    # Paris -> London ~ 343.5 km
    paris = Point(48.8566, 2.3522)
    london = Point(51.5074, -0.1278)
    d = haversine_km(paris, london)
    assert 340 < d < 347, d

if __name__ == "__main__":
    test_zero(); test_known(); print("ALL PASS")
PY
