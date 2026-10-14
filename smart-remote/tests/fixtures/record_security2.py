"""Record public synthetic vectors using the unchanged ESP-IDF v5.5 client.

Run inside the isolated test container: python3 tests/fixtures/record_security2.py
Uses test-only protoc/Python protobuf/cryptography; production builds use protox.
"""
from pathlib import Path
import hashlib
import importlib
import json
import subprocess
import sys
import tempfile
import types

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent
EXPECTED = {
    "srp6a.py": "6074ab48d653669b6da24525cf7b7d6ac6ab4b88e4274ae69c2df8597c2a0834",
    "security2.py": "bdc90f36a754a9a767aa7298bd697b7ed0ddf42777bda159d13ed646a7c39445",
}


def record(secret: bytes, proto: types.SimpleNamespace) -> dict[str, bytes]:
    from espsecurity import srp6a, security2
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    srp6a.get_random_of_length = lambda size: int.from_bytes(secret, "big")
    salt = bytes(range(1, 17))
    srp6a.get_random = lambda size: int.from_bytes(salt, "big")
    salt, verifier = srp6a.generate_salt_and_verifier("minerva-remote", "000123", 16)
    modulus, generator = srp6a.get_ng(srp6a.NG_3072)
    k = srp6a.H(hashlib.sha512, modulus, generator, width=384)
    # Server challenge uses SRP6a's public B = (k*v + g^b) mod N.
    public = (k * int.from_bytes(verifier, "big") + pow(generator, 31, modulus)) % modulus
    client = security2.Security2(1, "minerva-remote", "000123", False)
    start = client.security2_session(None).encode("latin-1")
    challenge = proto.session_pb2.SessionData(sec_ver=2)
    challenge.sec2.msg = 1
    challenge.sec2.sr0.device_pubkey = srp6a.long_to_bytes(public)
    challenge.sec2.sr0.device_salt = salt
    challenge_wire = challenge.SerializeToString()
    proof = client.security2_session(challenge_wire.decode("latin-1")).encode("latin-1")
    finish = proto.session_pb2.SessionData(sec_ver=2)
    finish.sec2.msg = 3
    finish.sec2.sr1.device_proof = srp6a.calculate_H_AMK(
        hashlib.sha512, client.srp6a_ctx.A, client.client_pop_key, client.srp6a_ctx.K
    )
    nonce = bytes(range(8)) + (1).to_bytes(4, "big")
    finish.sec2.sr1.device_nonce = nonce
    finish_wire = finish.SerializeToString()
    assert client.security2_session(finish_wire.decode("latin-1")) is None
    key = client.srp6a_ctx.get_session_key()
    request = json.dumps({"v": 1, "host": "minerva.local", "port": 47821,
                          "token": "A" * 43}, separators=(",", ":")).encode()
    reply = b'{"v":1,"ok":true,"device_id":"a4cf12b03e5d"}'
    encrypted = client.encrypt_data(request)
    server = AESGCM(key[:32])
    encrypted_reply = server.encrypt(nonce[:8] + (2).to_bytes(4, "big"), reply, None)
    assert client.decrypt_data(encrypted_reply) == reply
    wifi = proto.wifi_config_pb2.WiFiConfigPayload(msg=2)
    wifi.cmd_set_config.ssid = b"synthetic-network"
    wifi.cmd_set_config.passphrase = b"public-test-password"
    wifi_plain = wifi.SerializeToString()
    wifi_encrypted = client.encrypt_data(wifi_plain)
    wifi_reply = proto.wifi_config_pb2.WiFiConfigPayload(msg=3)
    wifi_reply.resp_set_config.status = 0
    wifi_response = server.encrypt(nonce[:8] + (4).to_bytes(4, "big"), wifi_reply.SerializeToString(), None)
    assert client.decrypt_data(wifi_response) == wifi_reply.SerializeToString()
    return dict(ephemeral=secret, start=start, challenge=challenge_wire, proof=proof,
                finish=finish_wire, session_key=key, config=request,
                config_encrypted=encrypted, config_reply=reply, config_response=encrypted_reply,
                wifi=wifi_plain, wifi_encrypted=wifi_encrypted, wifi_response=wifi_response)


def main() -> None:
    for name, expected in EXPECTED.items():
        assert hashlib.sha256((FIXTURES / "espsecurity" / name).read_bytes()).hexdigest() == expected
    with tempfile.TemporaryDirectory() as directory:
        source = ROOT / "proto" / "espressif"
        subprocess.run(["protoc", "-I", str(source), "--python_out=" + directory,
                        *map(str, sorted(source.glob("*.proto")))], check=True)
        sys.path.insert(0, directory)
        sys.path.insert(0, str(FIXTURES))
        sys.modules["utils"] = importlib.import_module("espsecurity.utils")
        proto = types.SimpleNamespace(**{name: importlib.import_module(name)
                                       for name in ("session_pb2", "sec2_pb2", "wifi_config_pb2")})
        sys.modules["proto"] = proto
        vectors = [record(bytes(range(1, 33)), proto), record(bytes(31) + b"\x01", proto)]
    lines = ["// Public synthetic fixtures recorded by record_security2.py, not real device secrets.",
             "// Oracle: ESP-IDF commit 8c750b088c7cd857d079c0eeb495da199b359461; Apache-2.0."]
    lines += [f"// {name}: SHA-256 {digest}" for name, digest in EXPECTED.items()]
    lines += ["pub struct Vector {"] + [f"    pub {name}: &'static str," for name in vectors[0]] + ["}"]
    lines += ["pub const VECTORS: &[Vector] = &["]
    for vector in vectors:
        lines += ["    Vector {"] + [f'        {name}: "{value.hex()}",' for name, value in vector.items()] + ["    },"]
    lines += ["];"]
    (FIXTURES / "security2.rs").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
