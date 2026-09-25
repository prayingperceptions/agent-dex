// SPDX-License-Identifier: MIT
// DemoAMM.sol — constant-product pool (x*y=k) with LP shares for Agent DEX.
// Holds token+quote; every swap Skims a fee. Half the fee -> protocol recipient (the
// platform rail); half accrues to LP holders pro-rata by shares (so the protocol's
// auto-deposited 0.5% receipt EARNS as an LP position, not just sits). Designed to be
// replaced by a real Aerodrome / Uniswap-v3 wrapper later — same surface.
pragma solidity ^0.8.20;

import { IERC20 } from "./IERC20.sol";

contract DemoAMM {
    IERC20 public immutable token;
    IERC20 public immutable quote;        // USDC or ETH on Base (REAL token, via IERC20)
    address public immutable protocolFeeTo;
    uint256 public immutable feeBps;           // per swap (e.g. 5 bps == 0.05%)

    uint256 public reserveToken;
    uint256 public reserveQuote;

    // LP share ledger (1e18 = 100%): earners accrue from half the swap fee
    mapping(address => uint256) public lpShares;
    mapping(address => uint256) public earned;
    uint256 public totalShares;
    uint256 public accFee;                     // accrued fee pool waiting to be claimed

    event Swap(address indexed trader, uint256 tokenIn, uint256 quoteOut, uint256 feeToProtocol);
    event LiquidityAdded(address indexed lp, uint256 tokenAmount, uint256 quoteAmount, uint256 shares);

    constructor(IERC20 token_, IERC20 quote_, address protocolFeeTo_, uint256 feeBps_) {
        token = token_; quote = quote_; protocolFeeTo = protocolFeeTo_;
        require(feeBps_ <= 500, "AMM: feeBps range");
        feeBps = feeBps_;
    }

    function price() public view returns (uint256) {
        if (reserveQuote == 0 || reserveToken == 0) return 0;
        return (reserveQuote * 1e18) / reserveToken;
    }

    // Mint LP shares proportional to quote deposited (constant-product share = token value).
    function addLiquidity(uint256 quoteAmount_) external returns (uint256 shares) {
        require(quoteAmount_ > 0, "AMM: zero");
        // First deposit is quote-only: the token side is seeded separately via seedToken().
        uint256 tokenIn = (reserveQuote > 0) ? (reserveToken * quoteAmount_) / reserveQuote : 0;
        quote.transferFrom(msg.sender, address(this), quoteAmount_);
        if (reserveQuote > 0) {
            // share proportional to quote added vs total quote reserve
            shares = (quoteAmount_ * 1e18) / (reserveQuote + quoteAmount_);
        } else {
            shares = 1e18; // first LP gets 100% (token side seeded separately by DEX)
        }
        reserveQuote += quoteAmount_;
        if (tokenIn > 0) { token.transferFrom(msg.sender, address(this), tokenIn); reserveToken += tokenIn; }
        lpShares[msg.sender] += shares;
        totalShares += shares;
        emit LiquidityAdded(msg.sender, tokenIn, quoteAmount_, shares);
    }

    // Seed the token side (the 98% launch float) into a DECX-created pool; no LP share
    // (liquidity is owned by the pool holder / protocol governs it). Called once at list().
    function seedToken(uint256 tokenAmount_) external {
        token.transferFrom(msg.sender, address(this), tokenAmount_);
        reserveToken += tokenAmount_;
    }

    // buy token: fee split — half straight to protocol (rail), half accrues to LPs.
    function buy(uint256 quoteIn_) external returns (uint256 toBuyer) {
        require(reserveToken > 0 && reserveQuote > 0, "AMM: empty");
        uint256 k = reserveToken * reserveQuote;
        uint256 newQuote = reserveQuote + quoteIn_;
        uint256 tokenOut = reserveToken - k / newQuote;
        uint256 fee = (tokenOut * feeBps) / 10000;
        toBuyer = tokenOut - fee;
        quote.transferFrom(msg.sender, address(this), quoteIn_);
        token.transfer(msg.sender, toBuyer);
        _splitFee(fee); // fee = halves: protocol + LP pool (token units)
        reserveQuote = newQuote;
        reserveToken -= tokenOut;
        emit Swap(msg.sender, quoteIn_, toBuyer, fee / 2);
        return toBuyer;
    }

    // sell token: fee (quote units) split the same way.
    function sell(uint256 tokenIn_) external returns (uint256 toSeller) {
        require(reserveQuote > 0, "AMM: empty");
        uint256 k = reserveToken * reserveQuote;
        uint256 newToken = reserveToken + tokenIn_;
        uint256 quoteOut = reserveQuote - k / newToken;
        uint256 fee = (quoteOut * feeBps) / 10000;
        toSeller = quoteOut - fee;
        token.transferFrom(msg.sender, address(this), tokenIn_);
        quote.transfer(msg.sender, toSeller);
        _splitFeeQuote(fee); // quote units: half protocol, half LP pool
        reserveToken = newToken;
        reserveQuote -= quoteOut;
        emit Swap(msg.sender, tokenIn_, toSeller, fee / 2);
        return toSeller;
    }

    // buy sells skims in TOKEN units. Route half to protocol, accrue half to LP pool (quote? we hold token ->
    // simplest: accrue token fee to protocol directly, and record LP-owed share in quote terms at current price).
    function _splitFee(uint256 feeToken) internal {
        uint256 protocol = feeToken / 2;                 // half to protocol (token units)
        token.transfer(protocolFeeTo, protocol);
        // LP share of fee, denominated in quote at current price, accrued claimable
        if (totalShares > 0 && reserveQuote > 0) {
            uint256 feeQuote = (feeToken - protocol) * reserveQuote / reserveToken; // convert remaining token fee to quote
            accFee += feeQuote;
        }
        // (remaining reserved token side stays in reserve; LP claims are handled in claimLp below)
    }

    // sell fee accrues in QUOTE units directly.
    function _splitFeeQuote(uint256 feeQuote) internal {
        uint256 protocol = feeQuote / 2;
        quote.transfer(protocolFeeTo, protocol);
        if (totalShares > 0) accFee += feeQuote - protocol;
    }

    // Claim the LP-earned portion pro-rata by LP shares, paid in QUOTE units.
    function claimLp(address lp) external returns (uint256 payout) {
        require(lpShares[lp] > 0, "AMM: not an LP");
        // compute this LP's share of the accrued fee pool, capped by what's claimable
        payout = (accFee * lpShares[lp]) / totalShares;
        // guard: don't overdraw; recompute against actual quote balance net of reserves
        uint256 avail = quote.balanceOf(address(this)) - reserveQuote;
        if (payout > avail) payout = avail;
        if (payout > 0) {
            accFee -= (accFee * lpShares[lp]) / totalShares;
            earned[lp] += payout;
            quote.transfer(lp, payout);
        }
    }
}