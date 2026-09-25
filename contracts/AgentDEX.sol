// SPDX-License-Identifier: MIT
// AgentDEX.sol — agent-native venue: launch a token, pool it, trade it, with agent gates.
// Composes onto Agent Stack. Launch fee (0.5%) + listing fee (0.5%) -> protocolTo.
// Liquidity: each launch auto-pools a DemoAMM so the 0.5% receipt is LIQUID from mint #1.
pragma solidity ^0.8.20;

import { SimpleERC20 } from "./SimpleERC20.sol";
import { DemoAMM } from "./DemoAMM.sol";

// ---- agent gate interface: returns real bools; fail-closed when a gate is set ----
interface IGate {
    function verify(address _agent) external returns (bool);
    function evaluate(address _agent, address _token, string calldata _action) external returns (bool);
    function pass(address _token) external returns (bool);
}

contract AgentDEX {
    address public immutable protocolTo;
    uint256 public immutable launchBps;   // 50 == 0.5%
    uint256 public immutable listingBps;  // 50 == 0.5%
    uint256 public immutable tradeBps;    // e.g. 5 == 0.05% per swap
    SimpleERC20 public immutable quote;

    // optional agent gates (address(0) = gate skipped in demo; fail-closed when set)
    address public authorityGate;
    address public safetyGate;
    address public identityGate;

    struct Listing {
        SimpleERC20 token;
        DemoAMM amm;
        address deployer;
        bool active;
    }
    mapping(address => Listing) public listings;

    event Launched(address indexed token, address indexed deployer, uint256 supply, uint256 feeToProtocol);
    event Listed(address indexed token, address amm, uint256 listingFee);
    event Trades(address indexed trader, address indexed token, bool isBuy, uint256 amount);

    constructor(SimpleERC20 quote_, address protocolTo_, uint256 launchBps_, uint256 listingBps_, uint256 tradeBps_) {
        quote = quote_; protocolTo = protocolTo_;
        launchBps = launchBps_; listingBps = listingBps_; tradeBps = tradeBps_;
    }

    // ---- gates: identity + authority via a tiny external call; fail-closed when set.
    // The gate returns a bool; we DECODE it (a successful call is not an allowance).
    function _permitted(address agent, address token_, string memory action) internal returns (bool) {
        if (agent == address(0)) return false;
        if (identityGate != address(0)) {
            if (!IGate(identityGate).verify(agent)) return false;
        }
        if (authorityGate != address(0)) {
            if (!IGate(authorityGate).evaluate(agent, token_, action)) return false;
        }
        return true;
    }
    function _safe(address token_) internal returns (bool) {
        if (safetyGate == address(0)) return true;
        return IGate(safetyGate).pass(token_);
    }

    // ---- launch: create the token; 0.5% minted to protocol AT CONSTRUCTION (no approval dance) ----
    function launch(string memory name_, string memory symbol_, uint256 supply_, address deployer_)
        external returns (SimpleERC20 token)
    {
        require(_permitted(deployer_, address(0), "launch"), "DEX: not permitted");
        token = new SimpleERC20(name_, symbol_, supply_, deployer_, protocolTo, launchBps);
        uint256 fee = (supply_ * launchBps) / 10000;
        listings[address(token)] = Listing({ token: token, amm: DemoAMM(address(0)), deployer: deployer_, active: true });
        emit Launched(address(token), deployer_, supply_, fee);
    }

    // ---- list: open a pooled, liquid market for the token; seed quote through the AMM's
    // addLiquidity (so reserves update) and place the 0.5% listing fee with protocol.
    // The token side is auto-seeded from the deployer's share so the pool can actually trade.
    function list(address tokenAddr, uint256 seedQuote) external returns (address ammAddr) {
        Listing storage l = listings[tokenAddr];
        require(l.active && address(l.amm) == address(0), "DEX: not launchable-to-list");
        require(_safe(tokenAddr), "DEX: safety gate failed");

        DemoAMM amm = new DemoAMM(l.token, quote, protocolTo, tradeBps);
        l.amm = amm;

        // 1) pull the seed quote from the seeder (who approved the DEX)
        quote.transferFrom(msg.sender, address(this), seedQuote);
        // 2) skim 0.5% listing fee -> protocol, seed the rest into the pool
        uint256 listingFee = (seedQuote * listingBps) / 10000;
        uint256 netSeed = seedQuote - listingFee;
        quote.transfer(protocolTo, listingFee);
        quote.approve(address(amm), netSeed);

        // 3) token side: pull the deployer's share into the DEX, approve + seed the pool.
        //    This makes the token tradable from listing (not a dead contract).
        uint256 deployerBal = l.token.balanceOf(l.deployer);
        l.token.transferFrom(l.deployer, address(this), deployerBal);
        l.token.approve(address(amm), deployerBal);
        amm.seedToken(deployerBal); // top up the token reserve so buy/sell work

        // 4) seed the quote side through addLiquidity (updates reserveQuote)
        amm.addLiquidity(netSeed);

        emit Listed(tokenAddr, address(amm), listingFee);
        return address(amm);
    }

    // ---- order: buy token with quote (identity+authority gated). Route through the DEX
    // so the AMM only ever pulls from the DEX (single allowance chain), then relay output.
    function buy(address tokenAddr, uint256 quoteIn, address trader) external returns (uint256) {
        require(_permitted(trader, tokenAddr, "buy"), "DEX: not permitted");
        Listing storage l = listings[tokenAddr];
        require(l.active && address(l.amm) != address(0), "DEX: not listed");
        quote.transferFrom(trader, address(this), quoteIn); // trader -> DEX
        quote.approve(address(l.amm), quoteIn);             // DEX -> pool allowance
        uint256 out = l.amm.buy(quoteIn);                   // pool pulls from DEX, mints token to DEX
        l.token.transfer(trader, out);                      // DEX -> trader
        emit Trades(trader, tokenAddr, true, quoteIn);
        return out;
    }

    // ---- order: sell token for quote (identity+authority gated). Relay through the DEX. ----
    function sell(address tokenAddr, uint256 tokenIn, address trader) external returns (uint256) {
        require(_permitted(trader, tokenAddr, "sell"), "DEX: not permitted");
        Listing storage l = listings[tokenAddr];
        require(l.active && address(l.amm) != address(0), "DEX: not listed");
        SimpleERC20 t = l.token;
        t.transferFrom(trader, address(this), tokenIn);     // trader -> DEX
        t.approve(address(l.amm), tokenIn);                 // DEX -> pool allowance
        uint256 out = l.amm.sell(tokenIn);                  // pool pulls from DEX, sends quote to DEX
        quote.transfer(trader, out);                        // DEX -> trader
        emit Trades(trader, tokenAddr, false, tokenIn);
        return out;
    }

    // ---- admin: plug in gate contracts (only protocolTo may set) ----
    function setGates(address identity_, address authority_, address safety_) external {
        require(msg.sender == protocolTo, "DEX: only protocol");
        identityGate = identity_; authorityGate = authority_; safetyGate = safety_;
    }
}