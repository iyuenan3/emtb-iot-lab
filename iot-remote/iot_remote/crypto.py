"""无第三方依赖的请求摘要和 P-256 原始签名验证。"""

import base64
import hashlib
import hmac
from typing import Optional
from urllib.parse import parse_qsl, quote


P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
A = P - 3
B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5
Point = Optional[tuple[int, int]]


def sha256_hex(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def token_digest(value: str) -> str:
    return sha256_hex(value.encode("utf-8"))


def constant_time_token_matches(value: str, expected_digest: str) -> bool:
    return hmac.compare_digest(token_digest(value), expected_digest)


def canonical_query(query: str) -> str:
    pairs = sorted(parse_qsl(query, keep_blank_values=True))
    return "&".join(
        f"{quote(key, safe='~-._')}={quote(value, safe='~-._')}"
        for key, value in pairs
    )


def canonical_request(method: str, path: str, query: str, timestamp: str,
                      nonce: str, body_digest: str) -> bytes:
    return "\n".join((
        method.upper(), path, canonical_query(query), timestamp, nonce, body_digest.lower()
    )).encode("utf-8")


def _inverse(value: int) -> int:
    return pow(value, -1, P)


def _point_add(left: Point, right: Point) -> Point:
    if left is None:
        return right
    if right is None:
        return left
    x1, y1 = left
    x2, y2 = right
    if x1 == x2 and (y1 != y2 or y1 == 0):
        return None
    if left == right:
        slope = ((3 * x1 * x1 + A) * _inverse(2 * y1 % P)) % P
    else:
        slope = ((y2 - y1) * _inverse((x2 - x1) % P)) % P
    x3 = (slope * slope - x1 - x2) % P
    return x3, (slope * (x1 - x3) - y1) % P


def _scalar_multiply(value: int, point: Point) -> Point:
    result: Point = None
    addend = point
    while value:
        if value & 1:
            result = _point_add(result, addend)
        addend = _point_add(addend, addend)
        value >>= 1
    return result


def _decode_public_key(encoded: bytes) -> Point:
    if len(encoded) != 65 or encoded[0] != 4:
        return None
    x = int.from_bytes(encoded[1:33], "big")
    y = int.from_bytes(encoded[33:65], "big")
    if x >= P or y >= P or (y * y - (x * x * x + A * x + B)) % P:
        return None
    return x, y


def verify_p256_raw(public_key: bytes, message: bytes, signature: bytes) -> bool:
    """验证 65 字节未压缩公钥和 64 字节 r||s 签名。"""
    point = _decode_public_key(public_key)
    if point is None or len(signature) != 64:
        return False
    r = int.from_bytes(signature[:32], "big")
    s = int.from_bytes(signature[32:], "big")
    if not (1 <= r < N and 1 <= s < N):
        return False
    digest = int.from_bytes(hashlib.sha256(message).digest(), "big")
    inverse = pow(s, -1, N)
    candidate = _point_add(
        _scalar_multiply(digest * inverse % N, (GX, GY)),
        _scalar_multiply(r * inverse % N, point),
    )
    return candidate is not None and candidate[0] % N == r


def decode_base64(value: str, expected_length: int) -> Optional[bytes]:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        return None
    return decoded if len(decoded) == expected_length else None
