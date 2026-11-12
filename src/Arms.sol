// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICourt} from "./ICourt.sol";
import {Blocks} from "./Blocks.sol";

interface IBurnableToken is IERC20 {
    function burn(uint256 amount) external;
}

/// @title Arms v1: bonded agents answer a fixed form about a target contract
/// @notice No owner, admin, upgrade or pause. Every number is an immutable constructor argument. The
/// token is used through `transfer`, `transferFrom`, `balanceOf` and `burn(uint256)` only. Anyone can
/// advance any timeout.
///
/// Lifecycle of a job: `post` escrows 3 x feePerArm -> `draw` (two arms, a third one in
/// `spotCheckOneIn` cases) -> `commit` -> `reveal` -> `settle`. Keys where the arms differ go to a
/// tie break arm (`draw` again, `commit`, `reveal`, `settle`). After `settle` a `challengeWindow`
/// opens; `challenge` asks the court, `resolve` applies its ruling; `release` unlocks the arms'
/// tranches once the window has closed with nothing open.
contract Arms {
    // ---- types ----

    enum Status {
        NONE,
        AGREED,
        MAJORITY,
        UNRESOLVED,
        CORRECTED,
        OVERTURNED
    }

    enum Phase {
        NONE,
        OPEN,
        COMMIT,
        REVEAL,
        TIE_OPEN,
        TIE_COMMIT,
        TIE_REVEAL,
        SETTLED,
        CANCELLED
    }

    /// @dev One struct so the launch manifest writes it field by field; all static words.
    struct Params {
        address token;
        address court;
        uint256 trancheMultiple;
        uint256 stakeMultiple;
        uint256 minBond;
        uint256 minFeePerArm;
        uint256 maxBondPerArm;
        uint256 maxTotalBonded;
        uint256 burnBps;
        uint256 challengerRewardBps;
        uint256 spotCheckOneIn;
        uint256 commitWindow;
        uint256 revealWindow;
        uint256 fillDeadline;
        uint256 challengeWindow;
        uint256 courtDeadline;
        uint256 exitDelay;
        uint256 strikesToDeactivate;
        uint256 strikeCooldown;
        uint256 chainA;
        uint256 chainB;
        uint256 chainC;
        uint256 chainD;
        bool arbitrumBlocks;
    }

    struct ArmInfo {
        uint256 bond;
        uint256 locked;
        address signer;
        bool exiting;
        uint64 exitAt;
        bool inactive;
        uint64 deactivatedAt;
        uint32 strikes;
    }

    struct Form {
        uint8 keyCount;
        string uri;
        address[] servers;
    }

    struct Job {
        bytes32 formId;
        uint256 targetChainId;
        address target;
        uint256 atBlock;
        uint256 feePerArm;
        address poster;
        uint8 keyCount;
        uint8 needed;
        Phase phase;
        uint64 openSince;
        uint64 deadline;
        uint64 challengeEnd;
        uint256 seedBlock;
        uint256 drawNonce;
        uint256 escrow;
        uint256 spent;
        bool overturned;
        bool slashedOnce;
        bool rewardPaid;
        bool released;
        uint256 reward;
        uint256 openChallenges;
        uint256 challengesOpened;
        address tieBreaker;
        uint32 disputedMask;
        uint8 disputedCount;
    }

    struct Entry {
        bytes32 commitHash;
        bool committed;
        bool revealed;
        string evidence;
    }

    struct KeyResult {
        bytes32 value;
        Status status;
    }

    struct Challenge {
        uint256 jobId;
        uint8 key;
        bytes32 claimedValue;
        address challenger;
        uint256 stake;
        uint64 openedAt;
        bool exists;
        bool resolved;
        ICourt.Ruling ruling;
    }

    struct Verdict {
        bytes32[] values;
        Status[] statuses;
        uint256 feePerArm;
        bool overturned;
        uint64 challengeEnd;
        uint256 atBlock;
        address[] arms;
        string[] evidence;
        address tieBreaker;
        string tieEvidence;
        Phase phase;
    }

    // ---- errors ----

    error BadParams();
    error ZeroAmount();
    error BondCap();
    error NotExiting();
    error AlreadyExiting();
    error ExitDelay();
    error NotInactive();
    error Cooldown();
    error SignerTaken();
    error FormExists();
    error BadForm();
    error UnknownForm();
    error FeeTooLow();
    error ChainNotAllowed();
    error BadTarget();
    error WrongPhase();
    error TooEarly();
    error TooLate();
    error NoCandidates();
    error NotOnJob();
    error AlreadyCommitted();
    error NotCommitted();
    error AlreadyRevealed();
    error BadReveal();
    error BadLength();
    error NotPending();
    error NotChallengeable();
    error SameValue();
    error ChallengeExists();
    error UnknownChallenge();
    error AlreadyResolved();
    error CourtPending();
    error CourtFee();
    error StillLocked();
    error AlreadyReleased();
    error TokenCallFailed();

    // ---- events ----

    event Bonded(address indexed arm, uint256 amount, uint256 bond);
    event ExitRequested(address indexed arm, uint64 exitAt);
    event Withdrawn(address indexed arm, uint256 amount);
    event SignerSet(address indexed arm, address indexed signer);
    event Struck(address indexed arm, uint32 strikes, bool deactivated);
    event Reactivated(address indexed arm);
    event FormRegistered(bytes32 indexed formId, uint8 keyCount, string uri);
    event Serving(bytes32 indexed formId, address indexed arm, uint256 minFee);
    event StoppedServing(bytes32 indexed formId, address indexed arm);
    event Posted(uint256 indexed jobId, bytes32 indexed formId, address indexed poster, uint256 feePerArm);
    event Drawn(uint256 indexed jobId, address indexed arm, bool tieBreaker);
    event Replaced(uint256 indexed jobId, address indexed arm);
    event Cancelled(uint256 indexed jobId);
    event Committed(uint256 indexed jobId, address indexed arm);
    event Revealed(uint256 indexed jobId, address indexed arm);
    event TieBreakOpened(uint256 indexed jobId, uint32 disputedMask);
    event Paid(uint256 indexed jobId, address indexed arm, uint256 amount, uint256 burned);
    event Settled(uint256 indexed jobId, uint256 spent, uint256 returned);
    event Challenged(
        uint256 indexed jobId, uint8 key, bytes32 claimedValue, address indexed challenger, bytes32 caseId
    );
    event Resolved(uint256 indexed jobId, uint8 key, bytes32 claimedValue, ICourt.Ruling ruling);
    event Slashed(uint256 indexed jobId, address indexed arm, uint256 amount);
    event RewardPaid(uint256 indexed jobId, address indexed challenger, uint256 amount);
    event Released(uint256 indexed jobId);
    /// @dev Emitted once at deploy, so every immutable parameter is readable from the logs.
    event Deployed(Params params);

    // ---- constants and immutables ----

    bytes32 public constant UNKNOWN = keccak256("ARMS_UNKNOWN");
    bytes32 public constant NOT_APPLICABLE = keccak256("ARMS_NOT_APPLICABLE");
    uint256 internal constant MAX_KEYS = 32;
    uint256 internal constant MAX_URI_BYTES = 200;
    uint256 internal constant BPS = 10_000;
    /// @dev `Number.MAX_SAFE_INTEGER`: the largest block number the court's question can carry.
    uint256 internal constant MAX_BLOCK = 9_007_199_254_740_991;

    IBurnableToken public immutable token;
    ICourt public immutable court;
    uint256 internal immutable trancheMultiple;
    uint256 internal immutable stakeMultiple;
    uint256 internal immutable minBond;
    uint256 internal immutable minFeePerArm;
    uint256 internal immutable maxBondPerArm;
    uint256 internal immutable maxTotalBonded;
    uint256 internal immutable burnBps;
    uint256 internal immutable challengerRewardBps;
    uint256 internal immutable spotCheckOneIn;
    uint256 internal immutable commitWindow;
    uint256 internal immutable revealWindow;
    uint256 internal immutable fillDeadline;
    uint256 internal immutable challengeWindow;
    uint256 internal immutable courtDeadline;
    uint256 internal immutable exitDelay;
    uint256 internal immutable strikesToDeactivate;
    uint256 internal immutable strikeCooldown;
    uint256 internal immutable chainA;
    uint256 internal immutable chainB;
    uint256 internal immutable chainC;
    uint256 internal immutable chainD;
    bool internal immutable arbitrumBlocks;

    // ---- storage ----

    mapping(address => ArmInfo) public arms;
    mapping(address => address) public armOfSigner;
    uint256 public totalBonded;
    uint256 public totalEscrow;
    uint256 public totalStakes;
    uint256 public totalRewards;

    mapping(bytes32 => Form) public forms;
    mapping(bytes32 => mapping(address => uint256)) internal serveIndex; // 1-based
    mapping(bytes32 => mapping(address => uint256)) public minFeeOf;

    uint256 public jobCount;
    mapping(uint256 => Job) public jobs;
    mapping(uint256 => address[]) internal jobArms;
    mapping(uint256 => mapping(address => Entry)) public entries;
    mapping(uint256 => mapping(address => mapping(uint8 => bytes32))) public answerOf;
    mapping(uint256 => mapping(address => bool)) public wasDrawn;
    mapping(uint256 => mapping(address => bool)) public slashedIn;
    mapping(uint256 => mapping(uint8 => KeyResult)) public results;
    mapping(bytes32 => Challenge) public challenges;
    mapping(uint256 => mapping(address => mapping(bytes32 => uint256))) public latestJob;

    constructor(Params memory p) {
        if (
            p.token == address(0) || p.court == address(0) || p.trancheMultiple < 3 || p.stakeMultiple == 0
                || p.minFeePerArm == 0 || p.minBond == 0 || p.maxBondPerArm < p.minBond
                || p.maxTotalBonded < p.maxBondPerArm || p.burnBps > BPS || p.challengerRewardBps > BPS
                || p.spotCheckOneIn == 0 || p.commitWindow == 0 || p.revealWindow == 0 || p.fillDeadline == 0
                || p.challengeWindow == 0 || p.courtDeadline == 0 || p.strikesToDeactivate == 0 || p.chainA == 0
        ) revert BadParams();
        token = IBurnableToken(p.token);
        court = ICourt(p.court);
        trancheMultiple = p.trancheMultiple;
        stakeMultiple = p.stakeMultiple;
        minBond = p.minBond;
        minFeePerArm = p.minFeePerArm;
        maxBondPerArm = p.maxBondPerArm;
        maxTotalBonded = p.maxTotalBonded;
        burnBps = p.burnBps;
        challengerRewardBps = p.challengerRewardBps;
        spotCheckOneIn = p.spotCheckOneIn;
        commitWindow = p.commitWindow;
        revealWindow = p.revealWindow;
        fillDeadline = p.fillDeadline;
        challengeWindow = p.challengeWindow;
        courtDeadline = p.courtDeadline;
        exitDelay = p.exitDelay;
        strikesToDeactivate = p.strikesToDeactivate;
        strikeCooldown = p.strikeCooldown;
        chainA = p.chainA;
        chainB = p.chainB;
        chainC = p.chainC;
        chainD = p.chainD;
        arbitrumBlocks = p.arbitrumBlocks;
        emit Deployed(p);
    }

    // =====================================================================
    // Arms and bonds
    // =====================================================================

    function bond(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        ArmInfo storage a = arms[msg.sender];
        if (a.bond + amount > maxBondPerArm || totalBonded + amount > maxTotalBonded) revert BondCap();
        a.bond += amount;
        totalBonded += amount;
        if (a.exiting) {
            a.exiting = false;
            a.exitAt = 0;
        }
        _pull(msg.sender, amount);
        emit Bonded(msg.sender, amount, a.bond);
    }

    /// @notice Stops new draws at once; `withdraw` opens after `exitDelay`. Bonding again cancels it.
    function requestExit() external {
        ArmInfo storage a = arms[msg.sender];
        if (a.exiting) revert AlreadyExiting();
        a.exiting = true;
        a.exitAt = uint64(block.timestamp + exitDelay);
        emit ExitRequested(msg.sender, a.exitAt);
    }

    /// @notice Pays out the unlocked bond to the arm address after `exitDelay`.
    function withdraw() external {
        ArmInfo storage a = arms[msg.sender];
        if (!a.exiting) revert NotExiting();
        if (block.timestamp < a.exitAt) revert ExitDelay();
        uint256 amount = a.bond - a.locked;
        if (amount == 0) revert ZeroAmount();
        a.bond -= amount;
        totalBonded -= amount;
        _send(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Names a signer that may only `commit` and `reveal` for this arm. Zero clears it.
    function setSigner(address signer) external {
        ArmInfo storage a = arms[msg.sender];
        if (a.signer != address(0)) delete armOfSigner[a.signer];
        if (signer != address(0)) {
            if (armOfSigner[signer] != address(0)) revert SignerTaken();
            armOfSigner[signer] = msg.sender;
        }
        a.signer = signer;
        emit SignerSet(msg.sender, signer);
    }

    function reactivate() external {
        ArmInfo storage a = arms[msg.sender];
        if (!a.inactive) revert NotInactive();
        if (block.timestamp < uint256(a.deactivatedAt) + strikeCooldown) revert Cooldown();
        a.inactive = false;
        a.strikes = 0;
        emit Reactivated(msg.sender);
    }

    function unlockedBond(address arm) public view returns (uint256) {
        ArmInfo storage a = arms[arm];
        return a.bond - a.locked;
    }

    function isActive(address arm) public view returns (bool) {
        ArmInfo storage a = arms[arm];
        return a.bond >= minBond && !a.exiting && !a.inactive;
    }

    // =====================================================================
    // Forms
    // =====================================================================

    function registerForm(bytes32 formId, uint8 keyCount, string calldata uri) external {
        if (formId == bytes32(0) || keyCount == 0 || keyCount > MAX_KEYS) revert BadForm();
        bytes memory u = bytes(uri);
        if (u.length > MAX_URI_BYTES) revert BadForm();
        for (uint256 i; i < u.length; ++i) {
            uint8 c = uint8(u[i]);
            if (c < 0x20 || c > 0x7e || c == 0x22 || c == 0x5c) revert BadForm();
        }
        Form storage f = forms[formId];
        if (f.keyCount != 0) revert FormExists();
        f.keyCount = keyCount;
        f.uri = uri;
        emit FormRegistered(formId, keyCount, uri);
    }

    function serve(bytes32 formId, uint256 minFee) external {
        Form storage f = forms[formId];
        if (f.keyCount == 0) revert UnknownForm();
        if (minFee < minFeePerArm) revert FeeTooLow();
        if (serveIndex[formId][msg.sender] == 0) {
            f.servers.push(msg.sender);
            serveIndex[formId][msg.sender] = f.servers.length;
        }
        minFeeOf[formId][msg.sender] = minFee;
        emit Serving(formId, msg.sender, minFee);
    }

    function stopServing(bytes32 formId) external {
        uint256 idx = serveIndex[formId][msg.sender];
        if (idx == 0) revert UnknownForm();
        Form storage f = forms[formId];
        address last = f.servers[f.servers.length - 1];
        f.servers[idx - 1] = last;
        serveIndex[formId][last] = idx;
        f.servers.pop();
        delete serveIndex[formId][msg.sender];
        delete minFeeOf[formId][msg.sender];
        emit StoppedServing(formId, msg.sender);
    }

    // =====================================================================
    // Jobs
    // =====================================================================

    function post(bytes32 formId, uint256 targetChainId, address target, uint256 atBlock, uint256 feePerArm)
        external
        returns (uint256 jobId)
    {
        Form storage f = forms[formId];
        if (f.keyCount == 0) revert UnknownForm();
        if (feePerArm < minFeePerArm) revert FeeTooLow();
        if (!chainAllowed(targetChainId)) revert ChainNotAllowed();
        if (target == address(0) || atBlock == 0 || atBlock > MAX_BLOCK) revert BadTarget();
        jobId = ++jobCount;
        Job storage j = jobs[jobId];
        j.formId = formId;
        j.targetChainId = targetChainId;
        j.target = target;
        j.atBlock = atBlock;
        j.feePerArm = feePerArm;
        j.poster = msg.sender;
        j.keyCount = f.keyCount;
        j.escrow = 3 * feePerArm;
        _reopen(j, Phase.OPEN);
        totalEscrow += j.escrow;
        _pull(msg.sender, j.escrow);
        emit Posted(jobId, formId, msg.sender, feePerArm);
    }

    /// @notice Draws arms for an open job (or the tie break arm), seeded by a later block hash and the
    /// job id. Reverts `NoCandidates` when nobody is eligible; call again later.
    function draw(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (j.phase != Phase.OPEN && j.phase != Phase.TIE_OPEN) revert WrongPhase();
        uint256 n = Blocks.number(arbitrumBlocks);
        if (n <= j.seedBlock) revert TooEarly();
        bytes32 h = Blocks.hash(j.seedBlock, arbitrumBlocks);
        if (h == bytes32(0)) {
            // The hash is gone: the seed block moves forward to the newest one still available.
            j.seedBlock = n - 1;
            h = Blocks.hash(n - 1, arbitrumBlocks);
        }
        uint256 seed = uint256(keccak256(abi.encode(h, jobId, j.drawNonce)));
        address[] memory cands = _candidates(jobId, j);
        if (cands.length == 0) revert NoCandidates();
        if (j.phase == Phase.OPEN) {
            if (j.needed == 0) j.needed = seed % spotCheckOneIn == 0 ? 3 : 2;
            uint256 missing = j.needed - jobArms[jobId].length;
            uint256 left = cands.length;
            for (uint256 i; i < missing && left > 0; ++i) {
                uint256 idx = uint256(keccak256(abi.encode(seed, i))) % left;
                address a = cands[idx];
                cands[idx] = cands[left - 1];
                --left;
                _assign(jobId, j, a, false);
                jobArms[jobId].push(a);
            }
            if (jobArms[jobId].length == j.needed) {
                j.phase = Phase.COMMIT;
                j.deadline = uint64(block.timestamp + commitWindow);
            }
        } else {
            address a = cands[seed % cands.length];
            _assign(jobId, j, a, true);
            j.tieBreaker = a;
            j.phase = Phase.TIE_COMMIT;
            j.deadline = uint64(block.timestamp + commitWindow);
        }
        ++j.drawNonce;
    }

    /// @notice Refunds a job that was not filled (or whose tie break arm was not found) by `fillDeadline`.
    function cancel(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (j.phase != Phase.OPEN) revert WrongPhase();
        if (block.timestamp <= uint256(j.openSince) + fillDeadline) revert TooEarly();
        uint256 tranche = trancheMultiple * j.feePerArm;
        for (uint256 i; i < jobArms[jobId].length; ++i) {
            arms[jobArms[jobId][i]].locked -= tranche;
        }
        delete jobArms[jobId];
        j.phase = Phase.CANCELLED;
        uint256 refund = j.escrow;
        j.escrow = 0;
        totalEscrow -= refund;
        _send(j.poster, refund);
        emit Cancelled(jobId);
    }

    /// @notice `hash = keccak256(abi.encode(jobId, arm, values, salt))`, by the arm or its signer.
    function commit(uint256 jobId, bytes32 hash) external {
        Job storage j = jobs[jobId];
        address arm = _actor(jobId, j);
        bool tie = arm == j.tieBreaker;
        if (tie ? j.phase != Phase.TIE_COMMIT : j.phase != Phase.COMMIT) revert WrongPhase();
        if (block.timestamp > j.deadline) revert TooLate();
        Entry storage e = entries[jobId][arm];
        if (e.committed) revert AlreadyCommitted();
        e.committed = true;
        e.commitHash = hash;
        emit Committed(jobId, arm);
        if (tie) {
            j.phase = Phase.TIE_REVEAL;
            j.deadline = uint64(block.timestamp + revealWindow);
        } else if (_allCommitted(jobId, j)) {
            j.phase = Phase.REVEAL;
            j.deadline = uint64(block.timestamp + revealWindow);
        }
    }

    /// @notice One value per key (a tie break arm: one per disputed key, in key order).
    function reveal(uint256 jobId, bytes32[] calldata values, bytes32 salt, string calldata evidenceURI) external {
        Job storage j = jobs[jobId];
        address arm = _actor(jobId, j);
        bool tie = arm == j.tieBreaker;
        if (tie ? j.phase != Phase.TIE_REVEAL : j.phase != Phase.REVEAL) revert WrongPhase();
        if (block.timestamp > j.deadline) revert TooLate();
        Entry storage e = entries[jobId][arm];
        if (!e.committed) revert NotCommitted();
        if (e.revealed) revert AlreadyRevealed();
        if (keccak256(abi.encode(jobId, arm, values, salt)) != e.commitHash) revert BadReveal();
        if (bytes(evidenceURI).length > MAX_URI_BYTES) revert BadLength();
        if (tie) {
            if (values.length != j.disputedCount) revert BadLength();
            uint256 v;
            for (uint8 k; k < j.keyCount; ++k) {
                if (j.disputedMask & (uint32(1) << k) != 0) answerOf[jobId][arm][k] = values[v++];
            }
        } else {
            if (values.length != j.keyCount) revert BadLength();
            for (uint8 k; k < j.keyCount; ++k) {
                answerOf[jobId][arm][k] = values[k];
            }
        }
        e.revealed = true;
        e.evidence = evidenceURI;
        emit Revealed(jobId, arm);
    }

    /// @notice Strikes and replaces arms that missed the commit or reveal deadline. Anyone may call.
    function timeout(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (block.timestamp <= j.deadline) revert TooEarly();
        uint256 tranche = trancheMultiple * j.feePerArm;
        if (j.phase == Phase.COMMIT || j.phase == Phase.REVEAL) {
            bool needReveal = j.phase == Phase.REVEAL;
            uint256 removed;
            uint256 i;
            while (i < jobArms[jobId].length) {
                address a = jobArms[jobId][i];
                Entry storage e = entries[jobId][a];
                if (needReveal ? e.revealed : e.committed) {
                    ++i;
                    continue;
                }
                arms[a].locked -= tranche;
                _strike(a);
                jobArms[jobId][i] = jobArms[jobId][jobArms[jobId].length - 1];
                jobArms[jobId].pop();
                ++removed;
                emit Replaced(jobId, a);
            }
            // Everyone revealed in time and nobody settled yet: that is `settle`'s job, not a timeout.
            if (removed == 0) revert NotPending();
            _reopen(j, Phase.OPEN);
        } else if (j.phase == Phase.TIE_COMMIT || j.phase == Phase.TIE_REVEAL) {
            address a = j.tieBreaker;
            arms[a].locked -= tranche;
            _strike(a);
            delete entries[jobId][a];
            j.tieBreaker = address(0);
            emit Replaced(jobId, a);
            _reopen(j, Phase.TIE_OPEN);
        } else {
            revert WrongPhase();
        }
    }

    /// @notice Settles a job whose arms have all revealed: pays, burns, returns the rest of the escrow,
    /// or opens a tie break where two arms differ. A tie break nobody could be drawn for by
    /// `fillDeadline` settles with its disputed keys UNRESOLVED.
    function settle(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (j.phase == Phase.REVEAL) {
            if (!_allRevealed(jobId, j)) revert NotPending();
            uint32 mask;
            uint8 count;
            for (uint8 k; k < j.keyCount; ++k) {
                (,, bool disputed) = _evaluate(jobId, j, k, false);
                if (disputed) {
                    mask |= uint32(1) << k;
                    ++count;
                }
            }
            if (mask != 0) {
                j.disputedMask = mask;
                j.disputedCount = count;
                _reopen(j, Phase.TIE_OPEN);
                emit TieBreakOpened(jobId, mask);
                return;
            }
            _finalize(jobId, j, false);
        } else if (j.phase == Phase.TIE_REVEAL) {
            if (!entries[jobId][j.tieBreaker].revealed) revert NotPending();
            _finalize(jobId, j, true);
        } else if (j.phase == Phase.TIE_OPEN) {
            if (block.timestamp <= uint256(j.openSince) + fillDeadline) revert TooEarly();
            _finalize(jobId, j, false);
        } else {
            revert WrongPhase();
        }
    }

    /// @notice Unlocks the tranches of a settled job once its challenge window has closed with no
    /// challenge open, and burns a reward nobody earned.
    function release(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (j.phase != Phase.SETTLED) revert WrongPhase();
        if (j.released) revert AlreadyReleased();
        if (block.timestamp <= j.challengeEnd || j.openChallenges != 0) revert StillLocked();
        j.released = true;
        uint256 tranche = trancheMultiple * j.feePerArm;
        for (uint256 i; i < jobArms[jobId].length; ++i) {
            if (!slashedIn[jobId][jobArms[jobId][i]]) arms[jobArms[jobId][i]].locked -= tranche;
        }
        if (j.tieBreaker != address(0) && !slashedIn[jobId][j.tieBreaker]) arms[j.tieBreaker].locked -= tranche;
        if (!j.rewardPaid && j.reward > 0) {
            uint256 r = j.reward;
            j.reward = 0;
            totalRewards -= r;
            token.burn(r);
        }
        emit Released(jobId);
    }

    // =====================================================================
    // Challenges
    // =====================================================================

    function caseIdOf(uint256 jobId, uint8 key, bytes32 claimedValue) public pure returns (bytes32) {
        return keccak256(abi.encode(jobId, key, claimedValue));
    }

    /// @notice Disputes an AGREED or MAJORITY key inside the challenge window. Pulls the stake (in the
    /// bond token) and the court's fee (in the court's asset) from the caller and opens a court case.
    function challenge(uint256 jobId, uint8 key, bytes32 claimedValue, uint256 maxCourtFee)
        external
        returns (bytes32 caseId)
    {
        Job storage j = jobs[jobId];
        if (j.phase != Phase.SETTLED) revert WrongPhase();
        if (block.timestamp > j.challengeEnd) revert TooLate();
        if (key >= j.keyCount) revert BadLength();
        KeyResult storage r = results[jobId][key];
        if (r.status != Status.AGREED && r.status != Status.MAJORITY) revert NotChallengeable();
        if (claimedValue == r.value || claimedValue == UNKNOWN) revert SameValue();
        caseId = caseIdOf(jobId, key, claimedValue);
        if (challenges[caseId].exists) revert ChallengeExists();

        uint256 stake = stakeMultiple * j.feePerArm;
        challenges[caseId] = Challenge({
            jobId: jobId,
            key: key,
            claimedValue: claimedValue,
            challenger: msg.sender,
            stake: stake,
            openedAt: uint64(block.timestamp),
            exists: true,
            resolved: false,
            ruling: ICourt.Ruling.NONE
        });
        ++j.openChallenges;
        ++j.challengesOpened;
        totalStakes += stake;
        _pull(msg.sender, stake);

        uint256 courtFee = court.fee();
        if (courtFee > maxCourtFee) revert CourtFee();
        if (courtFee > 0) {
            IERC20 asset = IERC20(court.feeAsset());
            if (!asset.transferFrom(msg.sender, address(this), courtFee)) revert TokenCallFailed();
            if (!asset.approve(address(court), courtFee)) revert TokenCallFailed();
        }
        court.ask(
            caseId,
            j.formId,
            forms[j.formId].uri,
            key,
            j.targetChainId,
            j.target,
            j.atBlock,
            r.value,
            claimedValue,
            msg.sender,
            maxCourtFee
        );
        emit Challenged(jobId, key, claimedValue, msg.sender, caseId);
    }

    /// @notice Applies the court's ruling, or closes the case with no ruling after `courtDeadline`.
    function resolve(uint256 jobId, uint8 key, bytes32 claimedValue) external {
        bytes32 caseId = caseIdOf(jobId, key, claimedValue);
        Challenge storage c = challenges[caseId];
        if (!c.exists) revert UnknownChallenge();
        if (c.resolved) revert AlreadyResolved();
        Job storage j = jobs[jobId];
        ICourt.Ruling r = court.ruling(caseId);
        if (r == ICourt.Ruling.NONE && block.timestamp <= uint256(c.openedAt) + courtDeadline) revert CourtPending();
        c.resolved = true;
        c.ruling = r;
        --j.openChallenges;

        KeyResult storage kr = results[jobId][key];
        bool stakeBack = true;
        if (r == ICourt.Ruling.CLAIMED || r == ICourt.Ruling.NEITHER) {
            if (kr.status == Status.AGREED || kr.status == Status.MAJORITY) {
                bytes32 stored = kr.value;
                if (r == ICourt.Ruling.CLAIMED) {
                    kr.status = Status.CORRECTED;
                    kr.value = claimedValue;
                } else {
                    kr.status = Status.OVERTURNED;
                }
                j.overturned = true;
                _slash(jobId, j, key, stored);
            }
            if (r == ICourt.Ruling.CLAIMED && !j.rewardPaid && j.reward > 0) {
                uint256 reward = j.reward;
                j.rewardPaid = true;
                j.reward = 0;
                totalRewards -= reward;
                _send(c.challenger, reward);
                emit RewardPaid(jobId, c.challenger, reward);
            }
        } else if (r == ICourt.Ruling.STORED && !j.overturned) {
            stakeBack = false;
            _splitStake(jobId, j, key, kr.value, c.stake);
        }
        totalStakes -= c.stake;
        if (stakeBack) _send(c.challenger, c.stake);
        if (j.openChallenges == 0 && block.timestamp > j.challengeEnd && !j.rewardPaid && j.reward > 0) {
            uint256 burn = j.reward;
            j.reward = 0;
            totalRewards -= burn;
            token.burn(burn);
        }
        emit Resolved(jobId, key, claimedValue, r);
    }

    // =====================================================================
    // Reads
    // =====================================================================

    function verdict(uint256 jobId) public view returns (Verdict memory v) {
        Job storage j = jobs[jobId];
        v.values = new bytes32[](j.keyCount);
        v.statuses = new Status[](j.keyCount);
        for (uint8 k; k < j.keyCount; ++k) {
            KeyResult storage r = results[jobId][k];
            v.values[k] = r.value;
            v.statuses[k] = r.status;
        }
        v.feePerArm = j.feePerArm;
        v.overturned = j.overturned;
        v.challengeEnd = j.challengeEnd;
        v.atBlock = j.atBlock;
        v.arms = jobArms[jobId];
        v.evidence = new string[](jobArms[jobId].length);
        for (uint256 i; i < jobArms[jobId].length; ++i) {
            v.evidence[i] = entries[jobId][jobArms[jobId][i]].evidence;
        }
        v.tieBreaker = j.tieBreaker;
        v.tieEvidence = entries[jobId][j.tieBreaker].evidence;
        v.phase = j.phase;
    }

    /// @notice The newest settled job for a target under a form. `jobId` zero means none.
    function latest(uint256 targetChainId, address target, bytes32 formId)
        external
        view
        returns (uint256 jobId, Verdict memory v)
    {
        jobId = latestJob[targetChainId][target][formId];
        if (jobId != 0) v = verdict(jobId);
    }

    function serversOf(bytes32 formId) external view returns (address[] memory) {
        return forms[formId].servers;
    }

    function armsOf(uint256 jobId) external view returns (address[] memory) {
        return jobArms[jobId];
    }

    function chainAllowed(uint256 chainId) public view returns (bool) {
        return chainId != 0 && (chainId == chainA || chainId == chainB || chainId == chainC || chainId == chainD);
    }

    // =====================================================================
    // Internals
    // =====================================================================

    function _pull(address from, uint256 amount) internal {
        if (!token.transferFrom(from, address(this), amount)) revert TokenCallFailed();
    }

    function _send(address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert TokenCallFailed();
    }

    function _reopen(Job storage j, Phase phase) internal {
        j.phase = phase;
        j.openSince = uint64(block.timestamp);
        j.seedBlock = Blocks.number(arbitrumBlocks) + 1;
        j.deadline = 0;
    }

    function _assign(uint256 jobId, Job storage j, address a, bool tie) internal {
        wasDrawn[jobId][a] = true;
        arms[a].locked += trancheMultiple * j.feePerArm;
        emit Drawn(jobId, a, tie);
    }

    function _candidates(uint256 jobId, Job storage j) internal view returns (address[] memory out) {
        address[] storage servers = forms[j.formId].servers;
        uint256 tranche = trancheMultiple * j.feePerArm;
        out = new address[](servers.length);
        uint256 n;
        for (uint256 i; i < servers.length; ++i) {
            address a = servers[i];
            if (a == j.poster || wasDrawn[jobId][a]) continue;
            if (minFeeOf[j.formId][a] > j.feePerArm) continue;
            if (!isActive(a)) continue;
            if (arms[a].bond - arms[a].locked < tranche) continue;
            out[n++] = a;
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _actor(uint256 jobId, Job storage j) internal view returns (address arm) {
        if (_onJob(jobId, j, msg.sender)) return msg.sender;
        arm = armOfSigner[msg.sender];
        if (arm == address(0) || !_onJob(jobId, j, arm)) revert NotOnJob();
    }

    function _onJob(uint256 jobId, Job storage j, address a) internal view returns (bool) {
        if (a == address(0) || !wasDrawn[jobId][a]) return false;
        if (a == j.tieBreaker) return true;
        for (uint256 i; i < jobArms[jobId].length; ++i) {
            if (jobArms[jobId][i] == a) return true;
        }
        return false;
    }

    function _allCommitted(uint256 jobId, Job storage) internal view returns (bool) {
        for (uint256 i; i < jobArms[jobId].length; ++i) {
            if (!entries[jobId][jobArms[jobId][i]].committed) return false;
        }
        return true;
    }

    function _allRevealed(uint256 jobId, Job storage) internal view returns (bool) {
        for (uint256 i; i < jobArms[jobId].length; ++i) {
            if (!entries[jobId][jobArms[jobId][i]].revealed) return false;
        }
        return true;
    }

    function _strike(address a) internal {
        ArmInfo storage s = arms[a];
        ++s.strikes;
        bool deactivated = !s.inactive && s.strikes >= strikesToDeactivate;
        if (deactivated) {
            s.inactive = true;
            s.deactivatedAt = uint64(block.timestamp);
        }
        emit Struck(a, s.strikes, deactivated);
    }

    /// @dev Tallies the main arms' answers for `key` (and the tie break arm's when `withTie`).
    function _evaluate(uint256 jobId, Job storage j, uint8 key, bool withTie)
        internal
        view
        returns (bytes32 value, Status status, bool disputed)
    {
        bytes32[4] memory vals;
        uint256[4] memory cnt;
        uint256 m;
        uint256 n = jobArms[jobId].length;
        uint256 answered;
        uint256 voters = n + (withTie ? 1 : 0);
        for (uint256 i; i < voters; ++i) {
            address a = i < n ? jobArms[jobId][i] : j.tieBreaker;
            bytes32 v = answerOf[jobId][a][key];
            if (v == UNKNOWN) continue;
            ++answered;
            bool found;
            for (uint256 x; x < m; ++x) {
                if (vals[x] == v) {
                    ++cnt[x];
                    found = true;
                    break;
                }
            }
            if (!found) {
                vals[m] = v;
                cnt[m] = 1;
                ++m;
            }
        }
        if (m == 1 && answered == n && !withTie) return (vals[0], Status.AGREED, false);
        uint256 best;
        bool unique = true;
        for (uint256 x = 1; x < m; ++x) {
            if (cnt[x] > cnt[best]) {
                best = x;
                unique = true;
            } else if (cnt[x] == cnt[best]) {
                unique = false;
            }
        }
        if (m > 0 && cnt[best] >= 2 && unique) return (vals[best], Status.MAJORITY, false);
        if (m >= 2 && !withTie) return (bytes32(0), Status.NONE, true);
        return (bytes32(0), Status.UNRESOLVED, false);
    }

    function _finalize(uint256 jobId, Job storage j, bool withTie) internal {
        uint256 n = jobArms[jobId].length;
        uint256[] memory correct = new uint256[](n);
        uint256 tieCorrect;
        for (uint8 k; k < j.keyCount; ++k) {
            bool disputed = j.disputedMask & (uint32(1) << k) != 0;
            (bytes32 value, Status status,) = _evaluate(jobId, j, k, withTie && disputed);
            if (disputed && !withTie) status = Status.UNRESOLVED;
            results[jobId][k] = KeyResult(value, status);
            if (status != Status.AGREED && status != Status.MAJORITY) continue;
            for (uint256 i; i < n; ++i) {
                if (answerOf[jobId][jobArms[jobId][i]][k] == value) ++correct[i];
            }
            if (withTie && disputed && answerOf[jobId][j.tieBreaker][k] == value) ++tieCorrect;
        }
        for (uint256 i; i < n; ++i) {
            _pay(jobId, j, jobArms[jobId][i], j.feePerArm * correct[i] / j.keyCount);
        }
        if (withTie && j.disputedCount > 0) {
            uint256 due = j.feePerArm * tieCorrect / j.disputedCount;
            _pay(jobId, j, j.tieBreaker, due > j.escrow ? j.escrow : due);
        }
        uint256 back = j.escrow;
        j.escrow = 0;
        totalEscrow -= back;
        j.phase = Phase.SETTLED;
        j.challengeEnd = uint64(block.timestamp + challengeWindow);
        latestJob[j.targetChainId][j.target][j.formId] = jobId;
        if (back > 0) _send(j.poster, back);
        emit Settled(jobId, j.spent, back);
    }

    function _pay(uint256 jobId, Job storage j, address arm, uint256 amount) internal {
        if (amount == 0) return;
        uint256 burned = amount * burnBps / BPS;
        j.escrow -= amount;
        j.spent += amount;
        totalEscrow -= amount;
        if (burned > 0) token.burn(burned);
        if (amount > burned) _send(arm, amount - burned);
        emit Paid(jobId, arm, amount, burned);
    }

    function _gave(uint256 jobId, Job storage j, address a, uint8 key, bytes32 value) internal view returns (bool) {
        if (a == j.tieBreaker && j.disputedMask & (uint32(1) << key) == 0) return false;
        return answerOf[jobId][a][key] == value;
    }

    function _slash(uint256 jobId, Job storage j, uint8 key, bytes32 stored) internal {
        uint256 tranche = trancheMultiple * j.feePerArm;
        uint256 total;
        uint256 voters = jobArms[jobId].length + (j.tieBreaker != address(0) ? 1 : 0);
        for (uint256 i; i < voters; ++i) {
            address a = i < jobArms[jobId].length ? jobArms[jobId][i] : j.tieBreaker;
            if (slashedIn[jobId][a] || !_gave(jobId, j, a, key, stored)) continue;
            slashedIn[jobId][a] = true;
            arms[a].bond -= tranche;
            arms[a].locked -= tranche;
            total += tranche;
            emit Slashed(jobId, a, tranche);
        }
        if (total == 0) return;
        totalBonded -= total;
        if (!j.slashedOnce) {
            j.slashedOnce = true;
            uint256 refund = total < j.spent ? total : j.spent;
            uint256 rest = total - refund;
            uint256 reward = rest * challengerRewardBps / BPS;
            j.reward += reward;
            totalRewards += reward;
            if (rest - reward > 0) token.burn(rest - reward);
            if (refund > 0) _send(j.poster, refund);
        } else {
            token.burn(total);
        }
    }

    function _splitStake(uint256 jobId, Job storage j, uint8 key, bytes32 stored, uint256 stake) internal {
        uint256 voters = jobArms[jobId].length + (j.tieBreaker != address(0) ? 1 : 0);
        address[] memory givers = new address[](voters);
        uint256 g;
        for (uint256 i; i < voters; ++i) {
            address a = i < jobArms[jobId].length ? jobArms[jobId][i] : j.tieBreaker;
            if (_gave(jobId, j, a, key, stored)) givers[g++] = a;
        }
        if (g == 0) {
            token.burn(stake);
            return;
        }
        uint256 share = stake / g;
        uint256 dust = stake - share * g;
        for (uint256 i; i < g; ++i) {
            _send(givers[i], share + (i == 0 ? dust : 0));
        }
    }
}
