// SPDX-License-Identifier: MIT
// AgentDEX.sol — agent-native venue: launch (1/0.5/0.5/98 split), dual-quote list
// (USDC or ETH via IERC20), buy/sell with identity+permission+safety gates, and
// every-rail fees to protocol. Lottery ledger lives in LotteryLedger so AgentDEX stays
// under the EIP-3860 24 KB contract-size limit.
pragma solidity ^0.8.20;

import { SimpleERC20 } from "./SimpleERC20.sol";
import { IERC20 } from "./IERC20.sol";
import { DemoAMM } from "./DemoAMM.sol";
import { LotteryLedger } from "./LotteryLedger.sol";

interface IGate {
    function verify(address _agent) external returns (bool);
    function evaluate(address _agent, address _token, string calldata _action) external returns (bool);
    function pass(address _token) external returns (bool);
}

contract AgentDEX {
    address public immutable protocolTo;
    uint256 public immutable launchBps;   // 50 == 0.5% of supply (×2 = deployer 1%)
    uint256 public immutable listingBps;  // 50 == 0.5%
    uint256 public immutable tradeBps;    // 5 == 0.05% per swap

    LotteryLedger public lottery;         // lottery + trader ledger (separate contract)

    mapping(address => bool) public acceptedQuotes;
    IERC20 public defaultQuote;
    address[] public quoteList;

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

    event Launched(address indexed token, address indexed deployer, uint256 supply,
        uint256 feeToProtocol, uint256 escrowLottery);
    event Listed(address indexed token, address amm, address quote, uint256 listingFee);
    event Trades(address indexed trader, address indexed token, bool isBuy, uint256 amount);

    constructor(IERC20 defaultQuote_, address protocolTo_,
                uint256 launchBps_, uint256 listingBps_, uint256 tradeBps_) {
        protocolTo = protocolTo_;
        launchBps = launchBps_; listingBps = listingBps_; tradeBps = tradeBps_;
        defaultQuote = defaultQuote_;
        _acceptQuote(address(defaultQuote_));
        lottery = new LotteryLedger(protocolTo_, address(this));
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
        token = new SimpleERC20(name_, symbol_, supply_, address(this));
        uint256 base = (supply_ * launchBps) / 10000; // 0.5%
        require(base > 0, "DEX: supply too small for 0.5% split");

        uint256 deployerShare = base * 2;             // 1%
        uint256 protocolShare = base;                 // 0.5%
        uint256 lotteryShare  = base;                 // 0.5% -> escrow in LotteryLedger
        uint256 floatShare    = supply_ - deployerShare - protocolShare - lotteryShare; // 98%

        token.transfer(msg.sender, deployerShare);
        token.transfer(protocolTo, protocolShare);
        // physically move the 0.5% escrow to the LotteryLedger, then record it
        token.transfer(address(lottery), lotteryShare);
        lottery.setEscrow(address(token), lotteryShare);

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

        quoteToken.transferFrom(msg.sender, address(this), seedQuote);
        uint256 listingFee = (seedQuote * listingBps) / 10000;
        uint256 netSeed = seedQuote - listingFee;
        quoteToken.transfer(protocolTo, listingFee);
        quoteToken.approve(address(amm), netSeed);

        // seed the 98% float; EXCLUDE lottery escrow (it stays with the ledger's holder balance)
        uint256 floatBal = l.token.balanceOf(address(this));
        l.token.approve(address(amm), floatBal);
        amm.seedToken(floatBal);

        amm.addLiquidity(netSeed);
        emit Listed(tokenAddr, address(amm), address(quoteToken), listingFee);
        return address(amm);
    }

    // ---- order: buy (identity+authority gated) ----
    function buy(address tokenAddr, uint256 quoteIn, address trader) external returns (uint256) {
        require(_permitted(trader, tokenAddr, "buy"), "DEX: not permitted");
        Listing storage l = listings[tokenAddr];
        require(l.active && address(l.amm) != address(0), "DEX: not listed");
        IERC20 qt = l.quote;
        qt.transferFrom(trader, address(this), quoteIn);
        qt.approve(address(l.amm), quoteIn);
        uint256 out = l.amm.buy(quoteIn);
        l.token.transfer(trader, out);
        lottery.markTrader(trader);
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
        lottery.markTrader(trader);
        emit Trades(trader, tokenAddr, false, tokenIn);
        return out;
    }

    // ---- deploy the escrow to the winner once the ledger is past threshold -------
    function enterDraw() external { lottery.enterDraw(msg.sender); }
    function draw(address tokenAddr) external returns (address) {
        require(msg.sender == protocolTo || _safe(tokenAddr), "DEX: draw auth");
        return lottery.draw(tokenAddr, IERC20(address(listings[tokenAddr].token)));
    }

    // ---- admin: gates (protocol-only) ----
    function setGates(address identity_, address authority_, address safety_) external {
        require(msg.sender == protocolTo, "DEX: only protocol");
        identityGate = identity_; authorityGate = authority_; safetyGate = safety_;
    }
}