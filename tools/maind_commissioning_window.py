#!/usr/bin/env python3
"""Fail-closed dry-run for maind's dedicated commissioning-window route.

There is intentionally no HTTP client, URL option, retry loop, or credential
generation here.  A real request remains a separately authorized hardware
operation performed by the guarded station lifecycle.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass


class ValidationError(ValueError):
    pass


@dataclass(frozen=True)
class WindowRequest:
    node_id: int
    discriminator: int
    timeout: int

    @classmethod
    def validate(cls, node_id: int, discriminator: int, timeout: int) -> "WindowRequest":
        for name, value in {
            "nodeId": node_id,
            "discriminator": discriminator,
            "timeout": timeout,
        }.items():
            if isinstance(value, bool) or not isinstance(value, int):
                raise ValidationError(f"{name} must be an integer")
        if not 1 <= node_id <= 0xFFFFFFFFFFFFFFFF:
            raise ValidationError("nodeId must be in 1..2^64-1")
        if not 0 <= discriminator <= 4095:
            raise ValidationError("discriminator must be in 0..4095")
        if not 180 <= timeout <= 900:
            raise ValidationError("timeout must be in 180..900 seconds")
        return cls(node_id, discriminator, timeout)

    def dry_run(self) -> dict[str, object]:
        return {
            "result": "GO-CANDIDATE-OFFLINE",
            "status": "NOT TESTED on hardware",
            "method": "POST",
            "path": "/commissioning/window",
            "body": {
                "nodeId": self.node_id,
                "discriminator": self.discriminator,
                "timeout": self.timeout,
            },
            "maind_generates_setup_pin_salt_and_verifier": True,
            "expected_success_fields": ["message", "manualCode", "qrCode"],
            "network_attempted": False,
        }


def integer(text: str) -> int:
    return int(text, 0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--node-id", required=True, type=integer)
    parser.add_argument("--discriminator", required=True, type=integer)
    parser.add_argument("--timeout", required=True, type=integer)
    parser.add_argument("--send", action="store_true", help="always refused")
    args = parser.parse_args()
    if args.send:
        print(json.dumps({"result": "NO-GO", "reason": "send path is disabled", "network_attempted": False}))
        return 4
    try:
        request = WindowRequest.validate(args.node_id, args.discriminator, args.timeout)
    except ValidationError as error:
        print(json.dumps({"result": "INVALID", "error": str(error), "network_attempted": False}))
        return 2
    print(json.dumps(request.dry_run(), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
