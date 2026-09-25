// SPDX-License-Identifier: MIT
// test/AgentDex.t.sol — M2 gate for the Compute model: launch split 1/0.5/0.5/98,
// dual-quote listing, buy/sell with fees to protocol, and the >=100-trader lottery draw.
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SimpleERC20} from "../contracts/SimpleERC20.sol";
import {DemoAMM} from "../contracts/DemoAMM.sol";
import {AgentDEX} from "../contracts/AgentDEX.sol";

contract AgentDexTest is Test {
    address internal constant PROTOCOL = address(0x2091);
    AgentDEX internal dex;
    SimpleERC20 internal usdc;   // quote A
    SimpleERC20 internal weth;   // quote B (ETH-like)

    address internal deployer;
    address[] internal traders;   // dealer + buyers/sellers
    uint256 internal constant SUPPLY = 1_000_000 ether;

    function setUp() public {
        deployer = address(0x1111);
        vm.startPrank(deployer);
        usdc = new SimpleERC20("USDC","USDC", 50_000_000 ether, deployer);
        weth = new SimpleERC20("WETH","WETH", 1_000_000 ether, deployer);
        dex  = new AgentDEX(usdc, PROTOCOL, 50, 50, 5);
        vm.stopPrank();
        // accept another quote (WETH/ETH-like) as PROTOCOL — acceptQuote is protocol-only
        vm.startPrank(PROTOCOL);
        dex.acceptQuote(weth, true);
        vm.stopPrank();

        // fund a handful of extra addresses for trading + the lottery threshold
        for (uint256 i=0;i<12;i++){
            address a = address(uint160(0x4000 + i));
            vm.prank(deployer);
            usdc.transfer(a, 100_000 ether);
        }
    }

    function _launch() internal returns (SimpleERC20) {
        vm.startPrank(deployer);
        SimpleERC20 t = dex.launch("Compute","CPT",SUPPLY);
        vm.stopPrank();
        return t;
    }

    function _list(SimpleERC20 t) internal {
        vm.startPrank(deployer);
        usdc.approve(address(dex), type(uint256).max);
        dex.list(address(t), usdc, 100_000 ether);
        vm.stopPrank();
    }

    // ---- the launch SPLIT: 1% deployer / 0.5% protocol / 0.5% escrow / 98% float ----
    function test_launch_split_1_05_05_98() public {
        SimpleERC20 t = _launch();
        uint256 base = SUPPLY / 200;                      // 0.5%
        assertEq(t.balanceOf(deployer), base * 2, "deployer 1%");
        assertEq(t.balanceOf(PROTOCOL), base, "protocol 0.5%");
        assertEq(dex.escrow(address(t)), base, "lottery escrow 0.5% (held on DEX balance)");
        // DEX balance = float (98%) + escrow (0.5%) = 98.5%; escrow is recorded separately
        assertEq(t.balanceOf(address(dex)), SUPPLY - base * 3, "DEX holds float+escrow (98.5%)");
        // ledger conservation (deployer + protocol + DEX-held = full supply)
        assertEq(t.balanceOf(deployer) + t.balanceOf(PROTOCOL) + t.balanceOf(address(dex)), SUPPLY);
    }

    // ---- dual quote: USDC default, WETH accepted ----
    function test_dual_quote_accepted() public view {
        assertTrue(dex.acceptedQuotes(address(usdc)));
        assertTrue(dex.acceptedQuotes(address(weth)));
        assertEq(dex.quoteCount(), 2);
    }

    function test_launch_then_list_uses_chosen_quote() public {
        SimpleERC20 t = _launch();
        vm.startPrank(deployer);
        weth.approve(address(dex), type(uint256).max);
        address amm = dex.list(address(t), weth, 10_000 ether); // list against ETH
        vm.stopPrank();
        assertTrue(amm != address(0));
        DemoAMM pool = DemoAMM(amm);
        // 0.5% listing fee -> protocol in WETH; pool gets the rest
        assertEq(weth.balanceOf(PROTOCOL), 50 ether, "0.5% WETH listing fee to protocol");
        assertEq(pool.reserveQuote(), 9_950 ether, "pool WETH after fee");
        assertGt(pool.reserveToken(), 0, "float seeded -> tradeable");
    }

    // ---- trade: buy + sell round trip, fees to protocol ----
    function test_buy_sell_roundtrip_with_protocol_fees() public {
        SimpleERC20 t = _launch();
        _list(t);
        address alice = traders.length>0 ? traders[0] : address(0x2222);

        // fund alice (use a fresh address we control as deployer-backed)
        address buyer = address(0x2222);
        vm.prank(deployer); usdc.transfer(buyer, 50_000 ether);

        uint256 protoTokenBefore = t.balanceOf(PROTOCOL); // has launch 0.5% already
        vm.startPrank(buyer);
        usdc.approve(address(dex), type(uint256).max);
        uint256 got = dex.buy(address(t), 5_000 ether, buyer);
        vm.stopPrank();
        assertGt(got, 0, "buyer got tokens");
        // a BUY pays its 0.05% fee in TOKEN units to protocol
        assertGt(t.balanceOf(PROTOCOL), protoTokenBefore, "buy fee (token) -> protocol");

        // sell back: a SELL pays its 0.05% fee in QUOTE units to protocol
        uint256 protoQuoteBefore = usdc.balanceOf(PROTOCOL);
        vm.startPrank(buyer);
        t.approve(address(dex), type(uint256).max);
        uint256 q = dex.sell(address(t), got, buyer);
        vm.stopPrank();
        assertGt(q, 0, "quote back on sell");
        assertGt(usdc.balanceOf(PROTOCOL), protoQuoteBefore, "sell fee (quote) -> protocol");
        assertEq(dex.hasTraded(buyer), true, "buyer marked as trader");
        assertEq(dex.distinctTraders(), 1, "one distinct trader so far");
    }

    // ---- fail-closed gate: a denying gate blocks even launch ----
    function test_revert_if_not_permitted_when_gate_set() public {
        DenyGate gate = new DenyGate();
        vm.startPrank(PROTOCOL);
        dex.setGates(address(gate), address(gate), address(0));
        vm.stopPrank();
        vm.expectRevert("DEX: not permitted");
        vm.startPrank(deployer);
        dex.launch("X","X",SUPPLY);
        vm.stopPrank();
    }

    // ---- lottery: needs >=100 distinct traders, then one winner gets the escrow ----
    function test_lottery_requires_threshold_then_draws_winner() public {
        SimpleERC20 t = _launch();
        _list(t);

        // set up 100 distinct trader addresses, each funding + buying a tiny amount
        for (uint256 i=0;i<100;i++){
            address a = address(uint160(0x5000 + i));
            vm.prank(deployer); usdc.transfer(a, 100 ether);
            vm.startPrank(a);
            usdc.approve(address(dex), type(uint256).max);
            dex.buy(address(t), 10, a);
            dex.enterDraw();
            vm.stopPrank();
        }
        assertEq(dex.distinctTraders(), 100, "threshold reached");
        assertEq(dex.candidateCount(), 100, "candidates registered");

        vm.startPrank(PROTOCOL);
        address winner2 = dex.draw(address(t));
        vm.stopPrank();
        // winner is one of the traders
        assertTrue(dex.hasTraded(winner2), "winner is a trader");
        assertEq(dex.escrow(address(t)), 0, "escrow released");
        // the draw took the whole 0.5% escrow out of the DEX and gave it to the winner;
        // winner already held their own bought tokens, so their balance now holds >= escrow
        assertGt(t.balanceOf(winner2), SUPPLY / 200 - 1, "winner received the 0.5% escrow on top of own tokens");
        // and the DEX no longer holds any escrow (confirmed released above)
        assertEq(dex.drawDone(), true);
    }

    function test_lottery_reverts_below_threshold() public {
        SimpleERC20 t = _launch();
        _list(t);
        address a = address(0x6000);
        vm.prank(deployer); usdc.transfer(a, 100 ether);
        vm.startPrank(a); usdc.approve(address(dex), type(uint256).max);
        dex.buy(address(t), 10, a);
        vm.stopPrank();
        vm.expectRevert("DEX: not enough traders");
        vm.startPrank(PROTOCOL);
        dex.draw(address(t));
        vm.stopPrank();
    }
}

contract DenyGate {
    function verify(address) external pure returns (bool) { return false; }
    function evaluate(address, address, string memory) external pure returns (bool) { return false; }
    function pass(address) external pure returns (bool) { return false; }
}