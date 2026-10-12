import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("asc_token", Path(__file__).parents[1] / "asc-token.py")
token = importlib.util.module_from_spec(spec)
spec.loader.exec_module(token)


class TokenTests(unittest.TestCase):
    def test_es256_signature_verifies_with_openssl(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / "key.pem"
            public = root / "public.pem"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt",
                            "ec_paramgen_curve:P-256", "-out", str(key)], check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(public)],
                           check=True, capture_output=True)
            for _ in range(20):
                header, claims, signature = token.make_token("KEY", "issuer", str(key)).split(".")
                def decode(value):
                    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
                self.assertEqual(json.loads(decode(header)), {"alg": "ES256", "kid": "KEY", "typ": "JWT"})
                payload = json.loads(decode(claims))
                self.assertEqual(payload["iss"], "issuer")
                self.assertEqual(payload["aud"], "appstoreconnect-v1")
                self.assertEqual(payload["exp"] - payload["iat"], 1200)
                raw = decode(signature)
                self.assertEqual(len(raw), 64)
                def integer(value):
                    value = value.lstrip(b"\0") or b"\0"
                    if value[0] & 0x80:
                        value = b"\0" + value
                    return b"\x02" + bytes([len(value)]) + value
                body = integer(raw[:32]) + integer(raw[32:])
                signature_file = root / "signature.der"
                signature_file.write_bytes(b"\x30" + bytes([len(body)]) + body)
                subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public),
                                "-signature", str(signature_file)], input=f"{header}.{claims}".encode(),
                               check=True, capture_output=True)

    def test_padding_and_invalid_der(self):
        self.assertEqual(token.raw_signature(bytes.fromhex("30080202008102020102")),
                         b"\0" * 31 + b"\x81" + b"\0" * 30 + b"\x01\x02")
        for value in (b"", bytes.fromhex("3006020101020101ff"),
                      bytes.fromhex("3006020101020181")):
            with self.assertRaises(ValueError):
                token.raw_signature(value)

    def test_token_refresh_before_expiry(self):
        library = Path(__file__).parents[1] / "asc-lib.sh"
        result = subprocess.run(["bash", "-eu", "-c", '''
          date() { echo "$test_time"; }
          python3() { echo "token-$test_time"; }
          test_time=1000
          source "$1"
          test "$TOKEN" = token-1000
          test_time=1899
          refresh_token
          test "$TOKEN" = token-1000
          test_time=1900
          refresh_token
          test "$TOKEN" = token-1900
        ''', "test", str(library)], env={"PATH": "/usr/bin:/bin", "ASC_KEY_ID": "test",
                                          "ASC_ISSUER_ID": "test", "ASC_KEY_P8": "unused"},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
