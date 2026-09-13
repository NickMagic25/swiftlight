"""Independent Python 3 oracle for Swift's Artemis-compatible OTP test vectors.

Synthetic credentials only. The production app does not invoke Python.
Run: python3 docs/dev/host-otp-vectors.py
"""
from hashlib import sha256

VECTORS = (
    ("1234", "000102030405060708090A0B0C0D0E0F", "Moonlight123",
     "2F4ADF9E38D2CEAA59290F38B3B552443CA2FADC9B330A08BB0668D109688DEA"),
    ("0007", "FFEEDDCCBBAA99887766554433221100", "café + &",
     "7252EB2645E5F50C7EB00770D31B1BA183C8DBA0EAE82038E0664A234103C872"),
)

for otp, salt_hex, passphrase, expected in VECTORS:
    salt = bytes.fromhex(salt_hex)
    actual = sha256((otp + salt.hex().upper() + passphrase).encode("utf-8")).hexdigest().upper()
    assert actual == expected, (actual, expected)
print(f"Verified {len(VECTORS)} Apollo OTP vectors (Python SHA-256 / UTF-8 / uppercase hexadecimal).")
