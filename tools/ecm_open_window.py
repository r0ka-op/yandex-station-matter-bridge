#!/usr/bin/env python3
"""Fail-closed validator for a future Enhanced Commissioning experiment.

This tool has deliberately no HTTP transport.  It never generates credentials,
never prints byte values, and cannot invoke Administrator Commissioning.
"""
from __future__ import annotations

import argparse
import base64
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class ValidationError(ValueError):
    pass


@dataclass(frozen=True)
class EcmRequest:
    commissioning_timeout: int
    verifier: bytes
    discriminator: int
    iterations: int
    salt: bytes

    @staticmethod
    def _integer(data: dict[str, Any], name: str, minimum: int, maximum: int) -> int:
        value = data.get(name)
        if isinstance(value, bool) or not isinstance(value, int):
            raise ValidationError(f"{name} must be an integer")
        if not minimum <= value <= maximum:
            raise ValidationError(f"{name} must be in {minimum}..{maximum}")
        return value

    @staticmethod
    def _bytes(data: dict[str, Any], name: str) -> bytes:
        value = data.get(name)
        if not isinstance(value, dict) or set(value) != {"base64"}:
            raise ValidationError(f"{name} must be an object containing only base64")
        encoded = value["base64"]
        if not isinstance(encoded, str):
            raise ValidationError(f"{name}.base64 must be a string")
        try:
            return base64.b64decode(encoded, validate=True)
        except Exception as error:
            raise ValidationError(f"{name}.base64 is not canonical base64") from error

    @classmethod
    def from_mapping(cls, data: Any) -> "EcmRequest":
        if not isinstance(data, dict):
            raise ValidationError("input must be a JSON object")
        expected = {
            "commissioningTimeout",
            "PAKEPasscodeVerifier",
            "discriminator",
            "iterations",
            "salt",
        }
        if set(data) != expected:
            raise ValidationError(f"fields must be exactly: {', '.join(sorted(expected))}")
        verifier = cls._bytes(data, "PAKEPasscodeVerifier")
        salt = cls._bytes(data, "salt")
        if len(verifier) != 97:
            raise ValidationError("PAKEPasscodeVerifier must be exactly 97 bytes")
        if not 16 <= len(salt) <= 32:
            raise ValidationError("salt must be 16..32 bytes")
        return cls(
            commissioning_timeout=cls._integer(data, "commissioningTimeout", 1, 65535),
            verifier=verifier,
            discriminator=cls._integer(data, "discriminator", 0, 4095),
            iterations=cls._integer(data, "iterations", 1000, 100000),
            salt=salt,
        )

    def redacted_plan(self) -> dict[str, Any]:
        return {
            "result": "NO-GO",
            "reason": (
                "maind's generic invokeCommand JSON parser does not dispatch cluster 0x003C; "
                "use the separately reviewed dedicated commissioning-window route; transport is intentionally absent"
            ),
            "target": {"endpointId": 0, "clusterId": 0x003C, "commandId": 0},
            "mustUseTimedInvoke": True,
            "genericHttpParserSupportsCluster003C": False,
            "dedicatedRouteCandidate": "/commissioning/window",
            "fields": [
                {"tag": 0, "name": "commissioningTimeout", "type": "uint16", "value": self.commissioning_timeout},
                {"tag": 1, "name": "PAKEPasscodeVerifier", "type": "octet-string", "length": len(self.verifier)},
                {"tag": 2, "name": "discriminator", "type": "uint16", "value": self.discriminator},
                {"tag": 3, "name": "iterations", "type": "uint32", "value": self.iterations},
                {"tag": 4, "name": "salt", "type": "octet-string", "length": len(self.salt)},
            ],
            "secrets_logged": False,
            "network_attempted": False,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="synthetic JSON fixture; byte values are never printed")
    parser.add_argument("--send", action="store_true", help="always refused until maind prerequisites are proven")
    args = parser.parse_args()
    if args.send:
        print(json.dumps({"result": "NO-GO", "network_attempted": False, "reason": "send path is disabled"}))
        return 4
    try:
        request = EcmRequest.from_mapping(json.loads(args.input.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, ValidationError) as error:
        print(json.dumps({"result": "INVALID", "network_attempted": False, "error": str(error)}))
        return 2
    print(json.dumps(request.redacted_plan(), indent=2))
    return 3  # Valid dry-run is still NO-GO for a real invocation.


if __name__ == "__main__":
    raise SystemExit(main())
