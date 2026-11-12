#!/usr/bin/env python3
"""Check built launch artifacts offline; run after forge build. Does not write a manifest."""
import json
from pathlib import Path
import re

CONTRACTS = ("Arms", "ArmsForms", "ArmsResults", "IMDCourt", "MockCourt", "MockToken", "MockIntake")
ROOT = Path(__file__).resolve().parents[1]
for name in CONTRACTS:
    artifact = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
    constructors = [entry for entry in artifact["abi"] if entry["type"] == "constructor"]
    constructor = constructors[0] if constructors else {"inputs": [], "stateMutability": "nonpayable"}
    args = constructor["inputs"]
    assert len(args) <= 16, f"{name}: constructor exceeds 16 entries"
    assert constructor["stateMutability"] == "nonpayable", f"{name}: constructor takes ETH"
    for arg in args:
        assert re.fullmatch(r"address|bool|bytes32|uint(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)", arg["type"]), f"{name}: non-static argument {arg}"
    for part in ("bytecode", "deployedBytecode"):
        assert not artifact[part].get("linkReferences"), f"{name}: unlinked {part}"
    runtime = len(bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x")))
    initcode = len(bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))) + 32 * len(args)
    assert runtime <= 24_576, f"{name}: runtime {runtime} exceeds EIP-170"
    assert initcode <= 49_152, f"{name}: initcode plus arguments {initcode} exceeds EIP-3860"
    if name == "Arms":
        assert len(args) == 13
        assert [a["name"] for a in args] == [x + "_" for x in (
            "token", "court", "minFeePerArm", "maxBondPerArm", "maxTotalBonded", "trancheMultiple",
            "burnBps", "challengerRewardBps", "commitWindow", "revealWindow", "challengeWindow", "courtDeadline", "exitDelay"
        )]
    print(f"{name}: {len(args)} static constructor entries; runtime {runtime}; initcode including arguments {initcode}; no links")
