#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path


DECODER = Path(__file__).resolve().parents[1] / "scripts" / "decode_matter_tlv.py"


def decode(value, success=True):
    result = subprocess.run(
        [sys.executable, str(DECODER), "--hex", value],
        text=True, capture_output=True, check=False,
    )
    if success and result.returncode != 0:
        raise AssertionError(result.stderr)
    if not success and result.returncode == 0:
        raise AssertionError(f"malformed TLV accepted: {value}")
    return json.loads(result.stdout if success else result.stderr)


def main():
    assert decode("0x08")["elements"][0]["value"] is False
    assert decode("0x09")["elements"][0]["value"] is True
    assert decode("0x0408")["elements"][0]["value"] == 8
    tagged = decode("0x240105")["elements"][0]
    assert tagged["tag"] == {"control": "context", "number": 1}
    assert tagged["value"] == 5

    server_list = decode("0x16041d0406040805000318")["elements"][0]
    assert server_list["type"] == "array"
    assert [item["value"] for item in server_list["children"]] == [29, 6, 8, 768]

    structure = decode("0x15240105290218")["elements"][0]
    assert structure["type"] == "structure"
    assert structure["children"][1]["value"] is True

    assert decode("0x00ff")["elements"][0]["value"] == -1
    assert decode("0x0c056c616d7021")["elements"][0]["value"] == "lamp!"
    assert decode("0x10030102ff")["elements"][0]["value_hex"] == "0102ff"
    assert decode("0x14")["elements"][0]["value"] is None
    nested = decode("0x161510030102031818")["elements"][0]
    assert nested["children"][0]["type"] == "structure"
    assert nested["children"][0]["children"][0]["value_hex"] == "010203"

    for malformed in ("0x", "0x0", "0x16", "0x18", "0x1f", "0x0c05aa"):
        decode(malformed, success=False)

    print(json.dumps({
        "all_pass": True,
        "server_list_fixture": [29, 6, 8, 768],
        "malformed_rejected": 6,
        "typed_scalars": ["boolean", "signed", "unsigned", "utf8", "bytes", "null"],
        "nested_containers": True,
    }))


if __name__ == "__main__":
    main()
