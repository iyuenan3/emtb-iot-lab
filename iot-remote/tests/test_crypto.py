import hashlib
import unittest

from iot_remote.crypto import (
    GX, GY, N, _scalar_multiply, canonical_query, canonical_request,
    verify_p256_raw,
)


def sign_for_test(private_key: int, nonce: int, message: bytes) -> tuple[bytes, bytes]:
    public = _scalar_multiply(private_key, (GX, GY))
    point = _scalar_multiply(nonce, (GX, GY))
    assert public and point
    r = point[0] % N
    digest = int.from_bytes(hashlib.sha256(message).digest(), "big")
    s = (pow(nonce, -1, N) * (digest + r * private_key)) % N
    public_bytes = b"\x04" + public[0].to_bytes(32, "big") + public[1].to_bytes(32, "big")
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return public_bytes, signature


class CryptoTests(unittest.TestCase):
    def test_raw_p256_signature(self):
        message = b"POST\n/api/v1/commands\n\n123\nnonce-1234567890\nabc"
        public, signature = sign_for_test(7, 11, message)
        self.assertTrue(verify_p256_raw(public, message, signature))
        self.assertFalse(verify_p256_raw(public, message + b"x", signature))

    def test_canonical_request(self):
        self.assertEqual(canonical_query("z=2&a=hello%20world"), "a=hello%20world&z=2")
        value = canonical_request("post", "/x", "b=2&a=1", "10", "n", "AB")
        self.assertEqual(value, b"POST\n/x\na=1&b=2\n10\nn\nab")


if __name__ == "__main__":
    unittest.main()
