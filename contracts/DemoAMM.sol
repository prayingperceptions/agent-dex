// SPDX-License-Identifier: MIT
// DemoAMM.sol — minimal constant-product pool (x*y=k) for the Agent DEX demo loop.
// This is a SAFE, self-contained liquidity simulator. It is designed to be REPLACED by
// a real Aerodrome / Uniswap-v3 wrapper later — same interface (quoteIn, quoteOut,
// price, addLiquidity). Holds token+quote; fee is skimmed to a protocol recipient.
pragma solidity ^0.8.20;

import { SimpleERC20 } from "./SimpleERC20.sol";

contract DemoAMM {
    SimpleERC20 public immutable token;
    SimpleERC20 public immutable quote; // e.g. USDC-like
    address public immutable protocolFeeTo;
    uint256 public immutable feeBps; // fee on each swap (e.g. 5 bps = 0.05%)

    uint256 public reserveToken;
    uint256 public reserveQuote;

    event Swap(address indexed trader, uint256 tokenIn, uint256 quoteOut, uint256 feeToProtocol);
    event LiquidityAdded(uint256 tokenAmount, uint256 quoteAmount);

    constructor(SimpleERC20 token_, SimpleERC20 quote_, address protocolFeeTo_, uint256 feeBps_) {
        token = token_; quote = quote_; protocolFeeTo = protocolFeeTo_;
        require(feeBps_ <= 500, "AMM: feeBps range");
        feeBps = feeBps_;
    }

    // price of one token in quote units (constant product)
    function price() public view returns (uint256) {
        if (reserveQuote == 0 || reserveToken == 0) return 0;
        return (reserveQuote * 1e18) / reserveToken;
    }

    // deposit liquidity: trapper sends quote + token, receives LP share (token-denominated)
    function addLiquidity(uint256 quoteAmount_) external returns (uint256) {
        require(quoteAmount_ > 0, "AMM: zero");
        uint256 tokenAmount_ = (reserveToken * quoteAmount_) / (reserveQuote == 0 ? 1 : reserveQuote);
        if (reserveQuote == 0) tokenAmount_ = 0; // first deposit defines ratio as quote-only, caller provides token separately
        quote.transferFrom(msg.sender, address(this), quoteAmount_);
        if (tokenAmount_ > 0) token.transferFrom(msg.sender, address(this), tokenAmount_);
        reserveQuote += quoteAmount_;
        reserveToken += tokenAmount_;
        emit LiquidityAdded(tokenAmount_, quoteAmount_);
        return tokenAmount_;
    }

    // seed token side into a pool with matching quote (used at launch so token is liquid immediately)
    // Auth is enforced by the ERC20 allowance: transferFrom(msg.sender,...) reverts unless the
    // token holder approved this pool, so no extra caller require is needed.
    function seedToken(uint256 tokenAmount_) external {
        token.transferFrom(msg.sender, address(this), tokenAmount_);
        reserveToken += tokenAmount_;
    }

    // buy token with quote. The AMM already HOLDS token+quote reserves, so the 0.05%
    // fee is transferred out of its own balance to protocol — never minted (AMM isn't a minter).
    function buy(uint256 quoteIn_) external returns (uint256 toBuyer) {
        require(reserveToken > 0 && reserveQuote > 0, "AMM: empty");
        uint256 k = reserveToken * reserveQuote;
        uint256 newQuote = reserveQuote + quoteIn_;
        uint256 tokenOut = reserveToken - k / newQuote; // constant product: rT * quoteIn / (rQ + quoteIn)
        uint256 feeT = (tokenOut * feeBps) / 10000;
        toBuyer = tokenOut - feeT;
        quote.transferFrom(msg.sender, address(this), quoteIn_);
        token.transfer(msg.sender, toBuyer);
        token.transfer(protocolFeeTo, feeT);
        reserveQuote = newQuote;
        reserveToken -= tokenOut;
        emit Swap(msg.sender, quoteIn_, toBuyer, feeT);
        return toBuyer;
    }

    // sell token for quote. Fee (0.05%) taken from the quote side, transferred to protocol.
    function sell(uint256 tokenIn_) external returns (uint256 toSeller) {
        require(reserveQuote > 0, "AMM: empty");
        uint256 k = reserveToken * reserveQuote;
        uint256 newToken = reserveToken + tokenIn_;
        uint256 quoteOut = reserveQuote - k / newToken; // constant product: rQ * tokenIn / (rT + tokenIn)
        uint256 feeQ = (quoteOut * feeBps) / 10000;
        toSeller = quoteOut - feeQ;
        token.transferFrom(msg.sender, address(this), tokenIn_);
        quote.transfer(msg.sender, toSeller);
        quote.transfer(protocolFeeTo, feeQ);
        reserveToken = newToken;
        reserveQuote -= quoteOut;
        emit Swap(msg.sender, tokenIn_, toSeller, feeQ);
        return toSeller;
    }
}