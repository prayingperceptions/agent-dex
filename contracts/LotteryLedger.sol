// SPDX-License-Identifier: MIT
// LotteryLedger.sol — separate contract holding the Agent DEX lottery, so AgentDEX
// stays under the 24 KB EIP-3860 contract-size limit. Platform-blind: tracks distinct
// trader addresses, and once >= LOTTERY_THRESHOLD have traded, draw() awards the escrow
// to one candidate by on-chain blockhash (can't tell a human from an agent).
pragma solidity ^0.8.20;

import { IERC20 } from "./IERC20.sol";

contract LotteryLedger {
    uint256 public constant LOTTERY_THRESHOLD = 100;

    address public immutable protocolTo;
    address public immutable dex;                 // the AgentDEX that sets escrow at launch
    mapping(address => uint256) public escrow;      // token -> 0.5% escrowed
    mapping(address => bool) public hasTraded;      // distinct trader set
    mapping(address => bool) public isCandidate;
    address[] public candidates;
    address[] public traders;                       // distinct traders
    uint256 public distinctTraders;
    bool public drawDone;

    event LotteryDrawn(address indexed token, address indexed winner, uint256 amount);

    constructor(address protocolTo_, address dex_) {
        protocolTo = protocolTo_;
        dex = dex_;
    }

    // called by AgentDEX on every trade with a new address
    function markTrader(address t) external {
        if (!hasTraded[t]) { hasTraded[t] = true; traders.push(t); distinctTraders++; }
    }

    function setEscrow(address token, uint256 amount) external {
        require(msg.sender == protocolTo || msg.sender == dex, "LOT: only dex/protocol");
        escrow[token] += amount;
    }

    function candidateCount() external view returns (uint256) { return candidates.length; }

    function enterDraw(address who) external {
        require(!drawDone, "LOT: already drawn");
        require(!isCandidate[who], "LOT: already candidate");
        require(hasTraded[who], "LOT: trade first");
        isCandidate[who] = true;
        candidates.push(who);
    }

    function draw(address tokenAddr, IERC20 token) external returns (address winner_) {
        require(msg.sender == protocolTo || msg.sender == dex, "LOT: only dex/protocol");
        require(!drawDone, "LOT: already drawn");
        require(distinctTraders >= LOTTERY_THRESHOLD, "LOT: not enough traders");
        uint256 escrowed = escrow[tokenAddr];
        require(escrowed > 0, "LOT: no escrow");
        require(candidates.length > 0, "LOT: no candidates");

        uint256 r = uint256(blockhash(block.number - 1));
        winner_ = candidates[r % candidates.length];
        drawDone = true;

        escrow[tokenAddr] = 0;
        token.transfer(winner_, escrowed);
        emit LotteryDrawn(tokenAddr, winner_, escrowed);
    }
}