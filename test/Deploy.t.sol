// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Arms} from "../src/Arms.sol";
import {IMDCourt} from "../src/IMDCourt.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

contract DeployTest is Test {
    function test_deploySepoliaConfig() public {
        Deploy d = new Deploy();
        Deploy.Config memory c = d.sepoliaConfig();
        vm.recordLogs();
        (MockToken token, IMDCourt court, Arms arms) = d.deploy(c);
        assertEq(token.owner(), d.SEPOLIA_OWNER(), "token owner is the launch owner, not the deployer");
        assertEq(address(court.intake()), d.SEPOLIA_INTAKE());
        assertEq(address(court.asset()), d.SEPOLIA_IMDTEST());
        assertEq(court.action(), bytes32("oracle.request@oracle-1"));
        assertEq(court.oracleSigner(), d.ORACLE_SIGNER());
        assertEq(address(arms.token()), address(token));
        assertEq(address(arms.court()), address(court));
        assertTrue(arms.chainAllowed(11155111));
        assertTrue(arms.chainAllowed(4663));
        assertFalse(arms.chainAllowed(1));
        // The Deployed event carries every parameter.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(arms) && logs[i].topics[0] == keccak256(bytes(_deployedSig()))) {
                Arms.Params memory p = abi.decode(logs[i].data, (Arms.Params));
                assertEq(p.trancheMultiple, 10);
                assertEq(p.stakeMultiple, 2);
                assertEq(p.minBond, 20 ether);
                assertEq(p.burnBps, 1000);
                assertEq(p.challengerRewardBps, 3000);
                assertEq(p.spotCheckOneIn, 10);
                assertEq(p.commitWindow, 6 hours);
                assertEq(p.revealWindow, 2 hours);
                assertEq(p.fillDeadline, 1 days);
                assertEq(p.challengeWindow, 7 days);
                assertEq(p.courtDeadline, 7 days);
                assertEq(p.exitDelay, 14 days);
                assertEq(p.strikesToDeactivate, 3);
                assertEq(p.strikeCooldown, 1 days);
                found = true;
            }
        }
        assertTrue(found, "Deployed event");
        // Constructors touch no other contract: the same deployment works on an empty chain too.
        assertGt(address(arms).code.length, 0);
        assertLe(address(arms).code.length, 24_576, "EIP-170");
    }

    function _deployedSig() internal pure returns (string memory) {
        return "Deployed((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool))";
    }
}
