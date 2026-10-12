#!/usr/bin/env python3
"""Create an ES256 App Store Connect token using Python and OpenSSL on macOS/Linux."""
import base64
import json
import subprocess
import sys
import time


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def raw_signature(der):
    # P-256 signatures fit in a short-form DER sequence with two INTEGERs.
    if len(der) < 2 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ValueError("Invalid P-256 signature sequence")
    offset = 2
    parts = []
    for _ in range(2):
        if offset + 2 > len(der) or der[offset] != 2:
            raise ValueError("Invalid P-256 signature integer")
        length = der[offset + 1]
        value = der[offset + 2:offset + 2 + length]
        if not value or len(value) != length or value[0] & 0x80:
            raise ValueError("Invalid P-256 signature value")
        value = value.lstrip(b"\0")
        if len(value) > 32:
            raise ValueError("Invalid P-256 signature width")
        parts.append(value.rjust(32, b"\0"))
        offset += 2 + length
    if offset != len(der):
        raise ValueError("Trailing P-256 signature data")
    return b"".join(parts)


def make_token(key_id, issuer_id, key_path):
    now = int(time.time())
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = b64(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 1200,
                            "aud": "appstoreconnect-v1"}).encode())
    message = f"{header}.{claims}"
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                               input=message.encode(), capture_output=True, check=True).stdout
    return f"{message}.{b64(raw_signature(signature))}"


if __name__ == "__main__":
    print(make_token(*sys.argv[1:]))
