// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../../src/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

/// @dev A mock of the IMD `Intake` that keeps the live one's rules: a price per (action, asset), a
/// revert below it or on an empty body, the payer recorded as `msg.sender`, the amount pulled and
/// forwarded, and a `complete`/`fail` only the writer may call that reaches the target under 200 000 gas.
contract MockIntake is IIntake {
    struct Req {
        address payer;
        address target;
        bytes4 selector;
        bytes4 onFailure;
        address asset;
        uint256 amount;
        bool exists;
    }

    error ActionNotSold();
    error ShortPayment();
    error EmptyBody();
    error NotWriter();

    event Requested(bytes32 indexed requestId, address indexed payer, bytes32 action, bytes body);

    address public immutable writer;
    address public immutable treasury;
    mapping(bytes32 => mapping(address => uint256)) public prices;
    mapping(bytes32 => Req) public requests;
    bytes public lastBody;
    bytes32 public lastRequestId;
    uint256 internal nonce;

    constructor(address writer_, address treasury_) {
        writer = writer_;
        treasury = treasury_;
    }

    function setPrice(bytes32 action, address asset, uint256 price) external {
        prices[action][asset] = price;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256) {
        return prices[action][asset];
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId) {
        uint256 price = prices[action][asset];
        if (price == 0) revert ActionNotSold();
        if (amount < price) revert ShortPayment();
        if (body.length == 0) revert EmptyBody();
        require(IERC20(asset).transferFrom(msg.sender, treasury, amount), "pull failed");
        requestId = keccak256(abi.encode(++nonce, msg.sender, action));
        requests[requestId] = Req(msg.sender, callback.target, callback.selector, onFailure, asset, amount, true);
        lastBody = body;
        lastRequestId = requestId;
        emit Requested(requestId, msg.sender, action, body);
    }

    function complete(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool ok)
    {
        if (msg.sender != writer) revert NotWriter();
        Req memory r = requests[requestId];
        (ok,) = r.target.call{gas: 200_000}(abi.encodeWithSelector(r.selector, requestId, a, signature));
    }

    function fail(bytes32 requestId, uint8 status, bytes32 reason) external returns (bool ok) {
        if (msg.sender != writer) revert NotWriter();
        Req memory r = requests[requestId];
        (ok,) = r.target.call{gas: 200_000}(
            abi.encodeWithSelector(r.onFailure, requestId, status, reason, uint16(0), uint16(0), bytes(""))
        );
    }
}
