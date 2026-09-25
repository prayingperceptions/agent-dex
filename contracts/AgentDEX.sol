// SPDX-License-Identifier: MIT
// AgentDEX.sol — agent-native venue. Launch split: deployer 1% / protocol 0.5% /
// lottery escrow 0.5% / tradable float 98%. Dual USDC-or-ETH quote. Trade with gates.
// Lottery: once >= LOTTERY_THRESHOLD distinct wallets have traded, the 0.5% escrow is
// drawn to ONE winner by on-chain blockhash (platform cannot tell human vs agent).
// LP-earn: a lister seeds quote + the float against a chosen quote; protocol earns
// every rail (launch 0.5%, listing 0.5%, per-trade 0.05%) plus LP fees if it seeds.
pragma solidity ^0.8.20;

import { SimpleERC20 } from "./SimpleERC20.sol";
import { IERC20 } from "./IERC20.sol";
import { DemoAMM } from "./DemoAMM.sol";

interface IGate {
    function verify(address _agent) external returns (bool);
    function evaluate(address _agent, address _token, string calldata _action) external returns (bool);
    function pass(address _token) external returns (bool);
}

contract AgentDEX {
    address public immutable protocolTo;
    uint256 public immutable launchBps;   // 50 == deployer 1% & protocol 0.5% & lottery 0.5% (of base)
    uint256 public immutable listingBps;  // 50 == 0.5%
    uint256 public immutable tradeBps;    // 5 == 0.05% per swap

    uint256 public constant LOTTERY_THRESHOLD = 100; // distinct traders to unlock the draw

    // trusted quote assets (USDC or ETH on Base) — pick at list(), like Uniswap pair choice
    mapping(address => bool) public acceptedQuotes;
    IERC20 public defaultQuote;
    address[] public quoteList;

    // agent gates (address(0) = skipped in demo; fail-closed when set)
    address public authorityGate;
    address public safetyGate;
    address public identityGate;

    struct Listing {
        SimpleERC20 token;
        DemoAMM amm;
        address deployer;
        IERC20 quote;
        bool active;
    }
    mapping(address => Listing) public listings;

    // lottery state
    mapping(address => uint256) public escrow;      // token -> 0.5% escrowed
    mapping(address => bool) public hasTraded;      // distinct trader set (platform-blind)
    mapping(address => bool) public isCandidate;    // entered the draw pool
    address[] public candidates;
    address[] public traders;                       // distinct traders (for blind proof)
    uint256 public distinctTraders;
    bool public drawDone;

    event Launched(address indexed token, address indexed deployer, uint256 supply,
        uint256 feeToProtocol, uint256 escrowLottery);
    event Listed(address indexed token, address amm, address quote, uint256 listingFee);
    event Trades(address indexed trader, address indexed token, bool isBuy, uint256 amount);
    event LotteryDrawn(address indexed token, address indexed winner, uint256 amount);

    constructor(IERC20 defaultQuote_, address protocolTo_,
                uint256 launchBps_, uint256 listingBps_, uint256 tradeBps_) {
        protocolTo = protocolTo_;
        launchBps = launchBps_; listingBps = listingBps_; tradeBps = tradeBps_;
        defaultQuote = defaultQuote_;
        _acceptQuote(address(defaultQuote_));
    }

    // ---- gates (fail-closed when a gate is set) ----
    function _permitted(address agent, address token_, string memory action) internal returns (bool) {
        if (agent == address(0)) return false;
        if (identityGate != address(0)) { if (!IGate(identityGate).verify(agent)) return false; }
        if (authorityGate != address(0)) { if (!IGate(authorityGate).evaluate(agent, token_, action)) return false; }
        return true;
    }
    function _safe(address token_) internal returns (bool) {
        if (safetyGate == address(0)) return true;
        return IGate(safetyGate).pass(token_);
    }

    // ---- launch: mint full supply to the DEX, split 1% / 0.5% / 0.5% / 98% ----
    function launch(string memory name_, string memory symbol_, uint256 supply_) external
        returns (SimpleERC20 token)
    {
        require(_permitted(msg.sender, address(0), "launch"), "DEX: not permitted");
        token = new SimpleERC20(name_, symbol_, supply_, address(this)); // all to the DEX
        uint256 base = (supply_ * launchBps) / 10000; // == 0.5% of supply
        // de minimis guard so a tiny supply doesn't zero the split (fail-closed)
        require(base > 0, "DEX: supply too small for 0.5% split");

        uint256 deployerShare = base * 2;            // 1%  -> deployer (msg.sender)
        uint256 protocolShare = base;                // 0.5%-> protocol
        uint256 lotteryShare  = base;                // 0.5%-> escrow
        uint256 floatShare    = supply_ - deployerShare - protocolShare - lotteryShare; // 98%

        token.transfer(msg.sender, deployerShare);
        token.transfer(protocolTo, protocolShare);
        escrow[address(token)] = lotteryShare;       // held by the DEX (contract balance)
        // remaining floatShare stays on the DEX balance (tradable float)

        listings[address(token)] = Listing({ token: token, amm: DemoAMM(address(0)), deployer: msg.sender, quote: defaultQuote, active: true });
        emit Launched(address(token), msg.sender, supply_, protocolShare, lotteryShare);
    }

    // ---- accept a quote asset (USDC or ETH on Base); protocol-only ----
    function acceptQuote(IERC20 q_, bool on_) external {
        require(msg.sender == protocolTo, "DEX: only protocol");
        if (on_ && !acceptedQuotes[address(q_)]) { acceptedQuotes[address(q_)] = true; quoteList.push(address(q_)); }
        if (!on_) acceptedQuotes[address(q_)] = false;
    }
    function _acceptQuote(address q_) internal { acceptedQuotes[q_] = true; if (quoteList.length == 0 || quoteList[0] != q_) quoteList.push(q_); }

    function quoteCount() external view returns (uint256) { return quoteList.length; }
    function quoteAt(uint256 i) external view returns (address) { return quoteList[i]; }
    function candidateCount() external view returns (uint256) { return candidates.length; }

    // ---- list: open a pooled market against a chosen quote (USDC or ETH). ----
    function list(address tokenAddr, IERC20 quoteToken, uint256 seedQuote)
        external returns (address ammAddr)
    {
        Listing storage l = listings[tokenAddr];
        require(l.active && address(l.amm) == address(0), "DEX: not launchable-to-list");
        require(_safe(tokenAddr), "DEX: safety gate failed");
        require(acceptedQuotes[address(quoteToken)], "DEX: quote not accepted");
        l.quote = quoteToken;

        DemoAMM amm = new DemoAMM(IERC20(address(l.token)), quoteToken, protocolTo, tradeBps);
        l.amm = amm;

        // 1) seed quote from the seeder; 0.5% listing fee -> protocol, rest pooled
        quoteToken.transferFrom(msg.sender, address(this), seedQuote);
        uint256 listingFee = (seedQuote * listingBps) / 10000;
        uint256 netSeed = seedQuote - listingFee;
        quoteToken.transfer(protocolTo, listingFee);
        quoteToken.approve(address(amm), netSeed);

        // 2) token side = the 98% float the DEX holds -> seed the pool so it can trade.
        //    EXCLUDE the 0.5% lottery escrow: it must stay on the DEX balance for the draw.
        uint256 floatBal = l.token.balanceOf(address(this)) - escrow[tokenAddr];
        l.token.approve(address(amm), floatBal);
        amm.seedToken(floatBal);

        // 3) quote side through addLiquidity (updates reserves)
        amm.addLiquidity(netSeed);

        emit Listed(tokenAddr, address(amm), address(quoteToken), listingFee);
        return address(amm);
    }

    // ---- order: buy (identity+authority gated). Single allowance chain via the DEX. ----
    function buy(address tokenAddr, uint256 quoteIn, address trader) external returns (uint256) {
        require(_permitted(trader, tokenAddr, "buy"), "DEX: not permitted");
        Listing storage l = listings[tokenAddr];
        require(l.active && address(l.amm) != address(0), "DEX: not listed");
        IERC20 qt = l.quote;
        qt.transferFrom(trader, address(this), quoteIn);
        qt.approve(address(l.amm), quoteIn);
        uint256 out = l.amm.buy(quoteIn);
        l.token.transfer(trader, out);
        _markTrader(trader);
        emit Trades(trader, tokenAddr, true, quoteIn);
        return out;
    }

    // ---- order: sell (identity+authority gated) ----
    function sell(address tokenAddr, uint256 tokenIn, address trader) external returns (uint256) {
        require(_permitted(trader, tokenAddr, "sell"), "DEX: not permitted");
        Listing storage l = listings[tokenAddr];
        require(l.active && address(l.amm) != address(0), "DEX: not listed");
        IERC20 qt = l.quote;
        l.token.transferFrom(trader, address(this), tokenIn);
        l.token.approve(address(l.amm), tokenIn);
        uint256 out = l.amm.sell(tokenIn);
        qt.transfer(trader, out);
        _markTrader(trader);
        emit Trades(trader, tokenAddr, false, tokenIn);
        return out;
    }

    // ---- lottery: any trader/seller may enter the draw; winner set proves a human or agent can win ----
    function enterDraw() external {
        require(!drawDone, "DEX: already drawn");
        require(!isCandidate[msg.sender], "DEX: already candidate");
        require(hasTraded[msg.sender] || msg.sender == address(this), "DEX: trade first");
        isCandidate[msg.sender] = true;
        candidates.push(msg.sender);
    }

    function _markTrader(address t) internal {
        if (!hasTraded[t]) { hasTraded[t] = true; traders.push(t); distinctTraders++; }
    }

    // ---- draw the lottery: needs >= LOTTERY_THRESHOLD distinct traders; winner by blockhash ----
    function draw(address tokenAddr) external returns (address winner_) {
        require(msg.sender == protocolTo || _safe(tokenAddr), "DEX: draw auth");
        require(!drawDone, "DEX: already drawn");
        require(distinctTraders >= LOTTERY_THRESHOLD, "DEX: not enough traders");
        uint256 escrowed = escrow[tokenAddr];
        require(escrowed > 0, "DEX: no escrow");
        require(candidates.length > 0, "DEX: no candidates");

        // on-chain randomness (blockhash of the parent block); blind to human vs agent
        uint256 r = uint256(blockhash(block.number - 1));
        winner_ = candidates[r % candidates.length];
        drawDone = true;

        escrow[tokenAddr] = 0;
        listings[tokenAddr].token.transfer(winner_, escrowed);
        emit LotteryDrawn(tokenAddr, winner_, escrowed);
    }

    // ---- admin: gates (protocol-only) ----
    function setGates(address identity_, address authority_, address safety_) external {
        require(msg.sender == protocolTo, "DEX: only protocol");
        identityGate = identity_; authorityGate = authority_; safetyGate = safety_;
    }
}