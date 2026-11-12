// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICourt} from "../src/ICourt.sol";
import {IMDCourt} from "../src/IMDCourt.sol";

/// @title One real oracle question on Sepolia through a deployed IMDCourt
/// @notice `IMDCourt.ask` is open to any caller that pays the intake's price, and cases are namespaced
/// by caller, so the owner can ask one question straight from a wallet after the launch:
///
///   forge script script/AskSepolia.s.sol --sig "ask(address,bytes32,address,uint256)" \
///     <court> <formId> <target> <atBlock> --rpc-url $SEPOLIA_RPC --broadcast --account <wallet>
///
/// then, once api.imd.fun shows the request attested (minutes later):
///
///   forge script script/AskSepolia.s.sol --sig "read(address,address,bytes32)" <court> <wallet> <caseId> --rpc-url $SEPOLIA_RPC
///
/// The wallet needs 0.5 imdTEST (the Sepolia Intake's price; ask the IMD team for test tokens).
contract AskSepolia is Script {
    bytes32 public constant CASE_ID = keccak256("arms-v1-sepolia-smoke-1");

    function ask(address court, bytes32 formId, address target, uint256 atBlock) external {
        IMDCourt c = IMDCourt(court);
        uint256 price = c.fee();
        vm.startBroadcast();
        IERC20(c.feeAsset()).approve(court, price);
        c.ask(
            CASE_ID,
            formId,
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/form.md",
            0,
            block.chainid,
            target,
            atBlock,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            msg.sender,
            price
        );
        vm.stopBroadcast();
        console.log("caseId:");
        console.logBytes32(CASE_ID);
    }

    function read(address court, address asker, bytes32 caseId) external view {
        IMDCourt.Case memory k = IMDCourt(court).caseOf(asker, caseId);
        console.log("open:", k.open);
        console.log("ruling (0 NONE, 1 STORED, 2 CLAIMED, 3 NEITHER):", uint8(k.ruling));
        console.logBytes32(k.requestId);
    }
}
