// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArmsBase} from "./ArmsBase.t.sol";
import {Arms} from "../src/Arms.sol";
import {ICourt} from "../src/ICourt.sol";
import {IMDCourt} from "../src/IMDCourt.sol";
import {IIntake} from "../src/IIntake.sol";
import {IArbSys} from "../src/Blocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleQuestion} from "../src/OracleQuestion.sol";

/// @notice Reproductions of the findings in the continuation brief and the previous rejection.
/// The original auditors' scratch files were not present in this checkout.
contract AuditRegressionsTest is ArmsBase {
    function _kind(bool spot, uint256 fee) internal returns (uint256 id) {
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(poster);
        id = arms.post(formId, CHAIN, target, AT_BLOCK, fee);
        uint256 seedBlock = _job(id).seedBlock;
        vm.roll(seedBlock + 1);
        for (uint256 i = 1;; ++i) {
            bytes32 h = keccak256(abi.encode("test seed", i));
            uint256 seed = uint256(keccak256(abi.encode(h, id, uint256(0))));
            if ((seed % 10 == 0) == spot) {
                vm.setBlockhash(seedBlock, h);
                break;
            }
        }
    }

    function _pair() internal returns (uint256 id) {
        id = _kind(false, FEE);
        _fill(id);
        assertEq(arms.armsOf(id).length, 2);
    }

    function _tie() internal returns (uint256 id) {
        id = _pair();
        address[] memory drawn = arms.armsOf(id);
        bytes32[] memory a = _vals("one");
        bytes32[] memory b = _vals("two");
        _commit(id, drawn[0], a);
        _commit(id, drawn[1], b);
        _reveal(id, drawn[0], a);
        _reveal(id, drawn[1], b);
        arms.settle(id);
        _fillTie(id);
    }

    function _balanced() internal view {
        assertEq(
            token.balanceOf(address(arms)),
            arms.totalBonded() + arms.totalEscrow() + arms.totalStakes() + arms.totalRewards()
        );
    }

    function test_audit1_flatConstructorConstantsAndDerivedMinBond() public {
        assertEq(arms.minBond(), 2 * TRANCHE);
        assertEq(arms.stakeMultiple(), 2);
        assertEq(arms.spotCheckOneIn(), 10);
        assertEq(arms.strikesToDeactivate(), 3);
        assertEq(arms.strikeCooldown(), 1 days);
        assertEq(arms.fillDeadline(), 1 days);
        Arms.Params memory p = sepoliaParams(address(token), address(court));
        p.trancheMultiple = 7;
        p.minFeePerArm = 2 ether;
        Arms other = _deploy(p);
        assertEq(other.minBond(), 28 ether);
        p.maxBondPerArm = 28 ether - 1;
        vm.expectRevert(Arms.BadParams.selector);
        _deploy(p);
    }

    function test_audit2_jobRecordsLengthBlockAndPicksByFormula() public {
        uint256 id = _kind(false, FEE);
        Arms.Job memory before = _job(id);
        address[] memory servers = arms.formRegistry().serversOf(formId);
        assertEq(before.serverCount, servers.length);
        assertEq(before.postedBlock + 1, before.seedBlock);
        uint256 seed = uint256(keccak256(abi.encode(blockhash(before.seedBlock), id, uint256(0))));
        arms.draw(id);
        Arms.Job memory after_ = _job(id);
        address[] memory selected = arms.armsOf(id);
        uint256 found;
        for (uint256 attempt; attempt < after_.drawNonce; ++attempt) {
            address a = servers[uint256(keccak256(abi.encode(seed, attempt))) % before.serverCount];
            bool duplicate;
            for (uint256 i; i < found; ++i) {
                if (selected[i] == a) duplicate = true;
            }
            if (!duplicate) assertEq(selected[found++], a, "fixed-index pick");
        }
        assertEq(found, 2);
        assertEq(after_.drawSeed, seed);
        assertLe(after_.drawNonce, arms.MAX_DRAW_TRIES());
    }

    function test_audit2_listIsAppendOnlyAndLateEntriesCannotReshapeDraw() public {
        uint256 id = _kind(false, FEE);
        address[] memory before = arms.formRegistry().serversOf(formId);
        vm.prank(armSet[1]);
        arms.stopServing(formId);
        vm.prank(armSet[4]);
        arms.stopServing(formId);
        address added = makeAddr("late arm");
        _fund(added, ARM_BOND);
        vm.startPrank(added);
        arms.bond(ARM_BOND);
        arms.serve(formId, FEE);
        vm.stopPrank();
        address[] memory after_ = arms.formRegistry().serversOf(formId);
        assertEq(after_.length, before.length + 1);
        for (uint256 i; i < before.length; ++i) {
            assertEq(before[i], after_[i]);
        }
        assertEq(after_[before.length], added);
        _fill(id);
        assertEq(_job(id).serverCount, before.length);
        assertFalse(arms.wasDrawn(id, added));
        vm.prank(armSet[1]);
        arms.serve(formId, FEE);
        assertEq(arms.formRegistry().serversOf(formId).length, after_.length, "re-serving never appends twice");
        assertEq(arms.formRegistry().serversOf(formId)[1], armSet[1]);
    }

    function test_audit2_exitAndStopOnlyExcludeLaterJobs() public {
        uint256 old = _kind(false, FEE);
        for (uint256 i; i < armSet.length; ++i) {
            vm.startPrank(armSet[i]);
            arms.stopServing(formId);
            arms.requestExit();
            vm.stopPrank();
        }
        _fill(old);
        assertEq(arms.armsOf(old).length, 2, "cannot opt out after seeing seed");
        uint256 later = _kind(false, FEE);
        arms.draw(later);
        assertEq(arms.armsOf(later).length, 0);
        assertEq(_job(later).drawNonce, arms.MAX_DRAW_TRIES());
        _balanced();
    }

    function test_audit2_stateChangeInPostingBlockOrAfterExcludesOldJob() public {
        uint256 id = _post();
        for (uint256 i; i < armSet.length; ++i) {
            vm.prank(armSet[i]);
            arms.bond(1);
        }
        vm.roll(vm.getBlockNumber() + 2);
        arms.draw(id);
        assertEq(arms.armsOf(id).length, 0, "same-block mutation is excluded");
        uint256 next = _kind(false, FEE);
        for (uint256 i; i < armSet.length; ++i) {
            vm.prank(armSet[i]);
            arms.serve(formId, FEE);
        }
        arms.draw(next);
        assertEq(arms.armsOf(next).length, 0, "post-seed fee update cannot join");
        uint256 later = _pair();
        assertEq(arms.armsOf(later).length, 2);
    }

    function test_audit2_exitAndStopRespectPostingOrderWithinOneBlock() public {
        uint256 old = _post();
        for (uint256 i; i < armSet.length; ++i) {
            vm.startPrank(armSet[i]);
            arms.stopServing(formId);
            arms.requestExit();
            vm.stopPrank();
        }
        vm.prank(poster);
        uint256 later = arms.post(formId, CHAIN, target, AT_BLOCK, FEE);
        assertEq(_job(old).postedBlock, _job(later).postedBlock, "both posted in one block");
        _fill(old);
        arms.draw(later);
        assertEq(arms.armsOf(old).length, 2, "earlier post retains eligibility");
        assertEq(arms.armsOf(later).length, 0, "later post respects stop/exit");
    }

    function test_audit2_attemptsContinueWithOneSeedAndAreBounded() public {
        for (uint256 i; i < armSet.length; ++i) {
            vm.prank(armSet[i]);
            arms.stopServing(formId);
        }
        uint256 id = _kind(false, FEE);
        arms.draw(id);
        Arms.Job memory a = _job(id);
        assertEq(a.drawNonce, arms.MAX_DRAW_TRIES());
        vm.roll(vm.getBlockNumber() + 300);
        arms.draw(id);
        Arms.Job memory b = _job(id);
        assertEq(b.drawNonce, 2 * arms.MAX_DRAW_TRIES());
        assertEq(b.drawSeed, a.drawSeed, "later calls cannot select another seed");
        assertEq(b.seedBlock, a.seedBlock);
        assertEq(arms.armsOf(id).length, 0);
        bytes32 empty = arms.registerForm(keccak256("empty"), 1, "ipfs://empty");
        vm.prank(poster);
        uint256 noServers = arms.post(empty, CHAIN, target, AT_BLOCK, FEE);
        vm.roll(vm.getBlockNumber() + 2);
        arms.draw(noServers);
        assertEq(_job(noServers).drawNonce, 0, "empty list never takes a modulo");
    }

    function test_audit3_serveRequiresMinimumBond() public {
        address a = makeAddr("empty arm");
        _fund(a, 20 ether);
        uint256 n = arms.formRegistry().serversOf(formId).length;
        vm.startPrank(a);
        vm.expectRevert(Arms.InsufficientBond.selector);
        arms.serve(formId, FEE);
        arms.bond(20 ether - 1);
        vm.expectRevert(Arms.InsufficientBond.selector);
        arms.serve(formId, FEE);
        arms.bond(1);
        arms.serve(formId, FEE);
        vm.stopPrank();
        assertEq(arms.formRegistry().serversOf(formId).length, n + 1);
    }

    function test_audit2_slashAfterPostingInvalidatesEligibility() public {
        (uint256 settled,) = _settledJob();
        address[] memory slashed = arms.armsOf(settled);
        uint256 open = _kind(false, FEE);
        bytes32 claim = keccak256("correction");
        bytes32 caseId = _challenge(settled, 0, claim);
        _rule(caseId, ICourt.Ruling.CLAIMED);
        arms.resolve(settled, 0, claim);
        _fill(open);
        for (uint256 i; i < slashed.length; ++i) {
            assertTrue(arms.isActive(slashed[i]), "still enough bond for future jobs");
            assertGe(arms.lastStateChange(slashed[i]), _job(open).postedBlock);
            assertFalse(arms.wasDrawn(open, slashed[i]), "changed since posting");
        }
        _balanced();
    }

    function test_audit6_noShowCompensationPreservesOtherJobsLocks() public {
        uint256 id = _pair();
        address[] memory first = arms.armsOf(id);
        // Stop unused servers for the next job, while the two arms' other obligations remain locked.
        for (uint256 i; i < armSet.length; ++i) {
            if (armSet[i] == first[0] || armSet[i] == first[1]) continue;
            vm.prank(armSet[i]);
            arms.stopServing(formId);
        }
        uint256 second = _pair();
        assertEq(_arm(first[0]).locked, 2 * TRANCHE);
        assertEq(_arm(first[1]).locked, 2 * TRANCHE);
        bytes32[] memory unknowns = new bytes32[](KEYS);
        for (uint256 k; k < KEYS; ++k) {
            unknowns[k] = arms.UNKNOWN();
        }
        _commit(id, first[0], unknowns);
        _commit(id, first[1], unknowns);
        _reveal(id, first[0], unknowns);
        uint256 before = token.balanceOf(first[0]);
        vm.warp(uint256(_job(id).deadline) + 1);
        arms.timeout(id);
        assertEq(token.balanceOf(first[0]) - before, FEE, "timely UNKNOWN also receives no-show compensation");
        assertEq(_arm(first[0]).locked, TRANCHE);
        assertEq(_arm(first[1]).locked, TRANCHE);
        _answerAll(second, _vals("truth"));
        arms.settle(second);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        arms.release(second);
        assertEq(_arm(first[0]).locked, 0);
        assertEq(_arm(first[1]).locked, 0);
        _balanced();
    }

    function test_audit4_threeArmsNeverDrawFourthMixedKeys() public {
        uint256 id = _kind(true, FEE);
        _fill(id);
        address[] memory drawn = arms.armsOf(id);
        assertEq(drawn.length, 3);
        bytes32[][] memory answers = new bytes32[][](3);
        for (uint256 i; i < 3; ++i) {
            answers[i] = _vals(bytes32(i + 1));
            answers[i][1] = i < 2 ? bytes32("majority") : bytes32("minority");
            answers[i][2] = bytes32("agreed");
            answers[i][3] = arms.UNKNOWN();
            _commit(id, drawn[i], answers[i]);
        }
        for (uint256 i; i < 3; ++i) {
            _reveal(id, drawn[i], answers[i]);
        }
        arms.settle(id);
        Arms.Verdict memory v = arms.verdict(id);
        assertEq(uint8(v.phase), uint8(Arms.Phase.SETTLED));
        assertEq(v.tieBreaker, address(0));
        assertEq(uint8(v.statuses[0]), uint8(Arms.Status.UNRESOLVED));
        assertEq(uint8(v.statuses[1]), uint8(Arms.Status.MAJORITY));
        assertEq(uint8(v.statuses[2]), uint8(Arms.Status.AGREED));
        assertEq(uint8(v.statuses[3]), uint8(Arms.Status.UNRESOLVED));
        assertEq(_job(id).spent, 5 * FEE / 4);
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.draw(id);
        _balanced();
    }

    function test_audit4_threeDistinctAnswersRefundAllEscrow() public {
        uint256 id = _kind(true, FEE);
        _fill(id);
        address[] memory drawn = arms.armsOf(id);
        for (uint256 i; i < 3; ++i) {
            _commit(id, drawn[i], _vals(bytes32(i)));
        }
        for (uint256 i; i < 3; ++i) {
            _reveal(id, drawn[i], _vals(bytes32(i)));
        }
        uint256 before = token.balanceOf(poster);
        arms.settle(id);
        assertEq(token.balanceOf(poster) - before, 3 * FEE);
        assertEq(_job(id).spent, 0);
        for (uint8 k; k < KEYS; ++k) {
            assertEq(uint8(arms.verdict(id).statuses[k]), uint8(Arms.Status.UNRESOLVED));
        }
        _balanced();
    }

    function test_audit5_timeoutNeverStrikesTimelyTieRevealer() public {
        uint256 id = _tie();
        address tb = _job(id).tieBreaker;
        bytes32[] memory v = _vals("one");
        _commit(id, tb, v);
        vm.warp(_job(id).deadline);
        _reveal(id, tb, v);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(Arms.NotPending.selector);
        arms.timeout(id);
        assertEq(_arm(tb).strikes, 0);
        assertEq(_arm(tb).locked, TRANCHE);
        arms.settle(id);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.SETTLED));
    }

    function test_audit6_revealNoShowPaysRevealerRefundsPosterAndCannotCancel() public {
        uint256 id = _pair();
        address[] memory drawn = arms.armsOf(id);
        bytes32[] memory v = _vals("truth");
        _commit(id, drawn[0], v);
        _commit(id, drawn[1], v);
        vm.warp(_job(id).deadline);
        _reveal(id, drawn[0], v);
        uint256 before = token.balanceOf(drawn[0]);
        uint256 posterBefore = token.balanceOf(poster);
        uint256 supply = token.totalSupply();
        vm.warp(vm.getBlockTimestamp() + 1);
        arms.timeout(id);
        assertEq(token.balanceOf(drawn[0]) - before, FEE, "full compensation, no burn");
        assertEq(token.balanceOf(poster) - posterBefore, 3 * FEE);
        assertEq(_arm(drawn[0]).bond, ARM_BOND);
        assertEq(_arm(drawn[1]).bond, ARM_BOND - FEE);
        assertEq(_arm(drawn[0]).strikes, 0);
        assertEq(_arm(drawn[1]).strikes, 1);
        assertEq(_arm(drawn[0]).locked, 0);
        assertEq(_arm(drawn[1]).locked, 0);
        assertEq(supply, token.totalSupply());
        assertTrue(_job(id).released);
        for (uint8 k; k < KEYS; ++k) {
            assertEq(uint8(arms.verdict(id).statuses[k]), uint8(Arms.Status.UNRESOLVED));
        }
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.cancel(id);
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.draw(id);
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.timeout(id);
        vm.expectRevert(Arms.AlreadyReleased.selector);
        arms.release(id);
        _balanced();
    }

    function testFuzz_audit6_compensationConservesFundsAndOnlyDebitsNoShows(bool twoRevealers, uint64 extraFee) public {
        uint256 fee = FEE + bound(extraFee, 0, FEE);
        uint256 id = _kind(true, fee);
        _fill(id);
        address[] memory drawn = arms.armsOf(id);
        uint256 revealers = twoRevealers ? 2 : 1;
        uint256 missing = 3 - revealers;
        bytes32[] memory v = _vals("truth");
        for (uint256 i; i < 3; ++i) {
            _commit(id, drawn[i], v);
        }
        for (uint256 i; i < revealers; ++i) {
            _reveal(id, drawn[i], v);
        }
        uint256[] memory before = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            before[i] = token.balanceOf(drawn[i]);
        }
        uint256 totalBefore = arms.totalBonded();
        uint256 posterBefore = token.balanceOf(poster);
        vm.warp(uint256(_job(id).deadline) + 1);
        arms.timeout(id);
        assertEq(totalBefore - arms.totalBonded(), revealers * fee);
        assertEq(token.balanceOf(poster) - posterBefore, 3 * fee);
        for (uint256 i; i < 3; ++i) {
            assertEq(_arm(drawn[i]).locked, 0);
            if (i < revealers) {
                assertEq(token.balanceOf(drawn[i]) - before[i], fee);
                assertEq(_arm(drawn[i]).bond, ARM_BOND);
                assertEq(_arm(drawn[i]).strikes, 0);
            } else {
                uint256 loss = revealers * fee / missing;
                if (i == revealers) loss += revealers * fee % missing;
                assertEq(_arm(drawn[i]).bond, ARM_BOND - loss);
                assertLe(loss, 10 * fee);
                assertEq(_arm(drawn[i]).strikes, 1);
            }
        }
        _balanced();
    }

    function test_audit6_zeroRevealsCanReplaceWithoutReducingBonds() public {
        uint256 id = _pair();
        address[] memory drawn = arms.armsOf(id);
        bytes32[] memory v = _vals("truth");
        _commit(id, drawn[0], v);
        _commit(id, drawn[1], v);
        vm.warp(uint256(_job(id).deadline) + 1);
        arms.timeout(id);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.OPEN));
        assertEq(_arm(drawn[0]).bond, ARM_BOND);
        assertEq(_arm(drawn[1]).bond, ARM_BOND);
        assertEq(_arm(drawn[0]).strikes, 1);
        _fill(id);
        address[] memory replacements = arms.armsOf(id);
        for (uint256 i; i < 2; ++i) {
            assertTrue(replacements[i] != drawn[0] && replacements[i] != drawn[1]);
        }
        _answerAll(id, v);
        arms.settle(id);
        _balanced();
    }

    function testFuzz_audit6_tieNoShowClosesWithoutReplacement(bool committed) public {
        uint256 id = _tie();
        address tb = _job(id).tieBreaker;
        if (committed) _commit(id, tb, _vals("one"));
        address[] memory main = arms.armsOf(id);
        uint256 aBefore = token.balanceOf(main[0]);
        uint256 bBefore = token.balanceOf(main[1]);
        uint256 posterBefore = token.balanceOf(poster);
        vm.warp(uint256(_job(id).deadline) + 1);
        arms.timeout(id);
        assertEq(_arm(tb).bond, ARM_BOND - 2 * FEE);
        assertEq(_arm(tb).strikes, 1);
        assertEq(_arm(main[0]).strikes, 0);
        assertEq(_arm(main[1]).strikes, 0);
        assertEq(token.balanceOf(main[0]) - aBefore, FEE);
        assertEq(token.balanceOf(main[1]) - bBefore, FEE);
        assertEq(token.balanceOf(poster) - posterBefore, 3 * FEE);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.SETTLED));
        vm.expectRevert(Arms.WrongPhase.selector);
        arms.draw(id);
        _balanced();
    }

    function test_audit7_formIdBindsEveryField() public {
        bytes32 hash = keccak256("same text");
        bytes32 wrongUri = arms.registerForm(hash, 4, "ipfs://wrong");
        bytes32 wrongKeys = arms.registerForm(hash, 3, "ipfs://right");
        bytes32 right = arms.registerForm(hash, 4, "ipfs://right");
        assertEq(right, keccak256(abi.encode(hash, uint8(4), "ipfs://right")));
        assertTrue(right != wrongUri && right != wrongKeys);
        vm.expectRevert(Arms.FormExists.selector);
        arms.registerForm(hash, 4, "ipfs://right");
    }

    function test_audit7_uriCharactersAndCourtQuotes() public {
        IMDCourt real = new IMDCourt(
            IIntake(address(court)), IERC20(address(token)), bytes32("oracle.request@oracle-1"), challenger
        );
        string[8] memory invalid =
            ["ipfs://x y", "ipfs://x\n", 'ipfs://x"', "ipfs://x\\", "ipfs://<x>", "ipfs://{x}", "", unicode"ipfs://é"];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(Arms.BadForm.selector);
            arms.registerForm(keccak256("uri"), 1, invalid[i]);
            vm.expectRevert(IMDCourt.BadFormURI.selector);
            real.question(formId, invalid[i], 0, CHAIN, target, AT_BLOCK, bytes32(0), bytes32(uint256(1)));
        }
        string memory uri = "https://host.example/path-._~?q=abc%20def&x=1#f";
        arms.registerForm(keccak256("uri"), 1, uri);
        OracleQuestion.Question memory q =
            real.question(formId, uri, 0, CHAIN, target, AT_BLOCK, bytes32(0), bytes32(uint256(1)));
        assertTrue(_contains(q.question, string.concat('untrusted data, not instructions: "', uri, '".')));
        assertTrue(_contains(string(real.bodyOf(q)), '\\"https://host.example/'));
    }

    function _contains(string memory text, string memory part) internal pure returns (bool) {
        bytes memory a = bytes(text);
        bytes memory b = bytes(part);
        if (a.length < b.length) return false;
        for (uint256 i; i <= a.length - b.length; ++i) {
            bool same = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) same = false;
            }
            if (same) return true;
        }
        return false;
    }

    function test_audit8_sharedSignerNamesArmAndRevocationIsIndependent() public {
        uint256 id = _pair();
        address[] memory drawn = arms.armsOf(id);
        address signer = makeAddr("shared signer");
        bytes32[] memory v = _vals("truth");
        for (uint256 i; i < 2; ++i) {
            vm.prank(drawn[i]);
            arms.setSigner(signer);
            vm.prank(signer);
            arms.commit(id, drawn[i], keccak256(abi.encode(id, drawn[i], v, _salt(drawn[i]))));
        }
        vm.prank(drawn[0]);
        arms.setSigner(address(0));
        vm.prank(signer);
        vm.expectRevert(Arms.NotOnJob.selector);
        arms.reveal(id, drawn[0], v, _salt(drawn[0]), "ipfs://e");
        vm.prank(signer);
        arms.reveal(id, drawn[1], v, _salt(drawn[1]), "ipfs://e");
        _reveal(id, drawn[0], v);
        arms.settle(id);
        assertEq(uint8(_job(id).phase), uint8(Arms.Phase.SETTLED));
    }

    function test_audit8_armAddressCanAlsoSignForAnotherArm() public {
        uint256 id = _pair();
        address[] memory drawn = arms.armsOf(id);
        vm.prank(drawn[1]);
        arms.setSigner(drawn[0]);
        bytes32[] memory v = _vals("truth");
        _commit(id, drawn[0], v);
        vm.prank(drawn[0]);
        arms.commit(id, drawn[1], keccak256(abi.encode(id, drawn[1], v, _salt(drawn[1]))));
        _reveal(id, drawn[0], v);
        vm.prank(drawn[0]);
        arms.reveal(id, drawn[1], v, _salt(drawn[1]), "ipfs://e");
        arms.settle(id);
    }

    function test_audit12_arbitrumBlockModeComesFromChainId() public {
        vm.chainId(4663);
        // A precompile need not have bytecode. Constructor must use chain id, with no probe.
        vm.mockCall(address(100), abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(uint256(10_000)));
        arms = _deploy(sepoliaParams(address(token), address(court)));
        formId = arms.registerForm(keccak256("orbit form"), KEYS, "ipfs://orbit");
        for (uint256 i; i < armSet.length; ++i) {
            _fund(armSet[i], ARM_BOND);
            vm.startPrank(armSet[i]);
            arms.bond(ARM_BOND);
            arms.serve(formId, FEE);
            vm.stopPrank();
        }
        _fund(poster, 0);
        vm.mockCall(address(100), abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(uint256(10_010)));
        vm.prank(poster);
        uint256 id = arms.post(formId, CHAIN, target, AT_BLOCK, FEE);
        assertEq(_job(id).postedBlock, 10_010);
        assertEq(_job(id).seedBlock, 10_011, "seeded by the chain's own block");
        vm.expectRevert(Arms.TooEarly.selector);
        arms.draw(id);
        vm.mockCall(address(100), abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(uint256(10_012)));
        bytes32 h = keccak256("orbit block");
        vm.mockCall(address(100), abi.encodeCall(IArbSys.arbBlockHash, (10_011)), abi.encode(h));
        arms.draw(id);
        assertEq(_job(id).drawSeed, uint256(keccak256(abi.encode(h, id, uint256(0)))));
        assertGe(arms.armsOf(id).length, 2);
        assertEq(vm.getBlockNumber(), 1000, "L1 height did not advance");
    }
}
