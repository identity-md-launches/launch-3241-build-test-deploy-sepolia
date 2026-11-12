// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FormURI} from "./FormURI.sol";

/// @title Form identities and append-only server lists for one Arms instance
/// @notice Created and permanently bound by Arms' constructor. No owner, setter or setup transaction.
/// Arms checks the caller's bond and passes its chain-local block number for prospective stops.
contract ArmsForms {
    struct Form {
        uint8 keyCount;
        string uri;
        address[] servers;
    }

    error OnlyArms();
    error BadForm();
    error FormExists();
    error UnknownForm();
    error FeeTooLow();
    error BadParams();

    address public immutable core;
    uint256 public immutable minFee;
    mapping(bytes32 => Form) public forms;
    mapping(bytes32 => mapping(address => bool)) private listed;
    mapping(bytes32 => mapping(address => uint256)) public minFeeOf;
    mapping(bytes32 => mapping(address => uint256)) public stoppedAt;
    mapping(bytes32 => mapping(address => uint256)) public stoppedAfterJob;

    constructor(address core_, uint256 minFee_) {
        if (core_ == address(0) || minFee_ == 0) revert BadParams();
        core = core_;
        minFee = minFee_;
    }

    modifier onlyArms() {
        if (msg.sender != core) revert OnlyArms();
        _;
    }

    function register(bytes32 textHash, uint8 keyCount, string calldata uri) external onlyArms returns (bytes32 id) {
        if (textHash == bytes32(0) || keyCount == 0 || keyCount > 32 || !FormURI.valid(uri)) revert BadForm();
        id = keccak256(abi.encode(textHash, keyCount, uri));
        Form storage f = forms[id];
        if (f.keyCount != 0) revert FormExists();
        f.keyCount = keyCount;
        f.uri = uri;
    }

    function serve(bytes32 id, address arm, uint256 fee) external onlyArms {
        Form storage f = forms[id];
        if (f.keyCount == 0) revert UnknownForm();
        if (fee < minFee) revert FeeTooLow();
        if (!listed[id][arm]) {
            f.servers.push(arm);
            listed[id][arm] = true;
        }
        minFeeOf[id][arm] = fee;
        delete stoppedAt[id][arm];
    }

    function stop(bytes32 id, address arm, uint256 atBlock, uint256 lastJob) external onlyArms {
        if (!listed[id][arm] || stoppedAt[id][arm] != 0) revert UnknownForm();
        stoppedAt[id][arm] = atBlock;
        stoppedAfterJob[id][arm] = lastJob;
    }

    function info(bytes32 id) external view returns (uint8 keyCount, uint256 serverCount) {
        Form storage f = forms[id];
        return (f.keyCount, f.servers.length);
    }

    function serversOf(bytes32 id) external view returns (address[] memory) {
        return forms[id].servers;
    }

    /// @notice Index addresses never move. A stop affects only jobs posted after that stop.
    function candidate(bytes32 id, uint256 index, uint256 jobId, uint256 fee) external view returns (address) {
        address arm = forms[id].servers[index];
        uint256 stopped = stoppedAt[id][arm];
        if ((stopped != 0 && stoppedAfterJob[id][arm] < jobId) || minFeeOf[id][arm] > fee) return address(0);
        return arm;
    }
}
