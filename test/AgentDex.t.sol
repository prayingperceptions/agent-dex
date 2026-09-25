// SPDX-License-Identifier: MIT
// test/AgentDex.t.sol — M2 gate: the full launch→list→trade→fee loop.
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SimpleERC20} from "../contracts/SimpleERC20.sol";
import {DemoAMM} from "../contracts/DemoAMM.sol";
import {AgentDEX} from "../contracts/AgentDEX.sol";

contract AgentDexTest is Test {
    address internal constant PROTOCOL = address(0x2091);
    address internal deployer;
    address internal alice;   // buyer
    address internal bob;     // seller/liquidity seeder
    SimpleERC20 internal quote;
    AgentDEX internal dex;

    function setUp() public {
        deployer = address(0x1111);
        alice = address(0x2222);
        bob = address(0x3333);
        // instantiate a USDC-like quote (no protocol fee) as deployer, fund alice + bob
        vm.startPrank(deployer);
        quote = new SimpleERC20("USDC", "USDC", 10_000_000 ether, deployer, address(0), 0);
        quote.transfer(alice, 1_000_000 ether);
        quote.transfer(bob, 2_000_000 ether);
        vm.stopPrank();

        vm.startPrank(deployer);
        dex = new AgentDEX(quote, PROTOCOL, 50, 50, 5); // launch 0.5%, listing 0.5%, trade 0.05%
        vm.stopPrank();
    }

    // helpers
    function _approveAll(SimpleERC20 t, address who, address spender) internal {
        vm.startPrank(who);
        t.approve(spender, type(uint256).max);
        vm.stopPrank();
    }

    function test_launch_mints_0_5_percent_to_protocol() public {
        _approveAll(quote, deployer, address(dex));
        vm.startPrank(deployer);
        SimpleERC20 t = dex.launch("Agent Token", "AGT", 1_000_000 ether, deployer);
        vm.stopPrank();
        // deployer held full supply; launch skimmed 0.5% to protocol
        assertEq(t.balanceOf(PROTOCOL), 5_000 ether, "0.5% to protocol");
        assertEq(t.balanceOf(deployer), 995_000 ether, "deployer keeps 99.5%");
    }

    function test_launch_then_list_opens_liquid_pool() public {
        _approveAll(quote, deployer, address(dex));
        vm.startPrank(deployer);
        SimpleERC20 t = dex.launch("Agent Token", "AGT", 1_000_000 ether, deployer);
        vm.stopPrank();
        _approveAll(t, deployer, address(dex)); // dex pulls deployer's share into the pool

        // seeder (bob) approves dex to spend quote, then lists with 100k seed
        _approveAll(quote, bob, address(dex));
        vm.startPrank(bob);
        address amm = dex.list(address(t), 100_000 ether);
        vm.stopPrank();

        assertTrue(amm != address(0), "pool opened");
        DemoAMM pool = DemoAMM(amm);
        // quote side seeded: 100k seed minus 0.5% listing fee (500) -> 99,500 into pool
        assertEq(pool.reserveQuote(), 99_500 ether, "pool quote after 0.5% listing fee");
        // 0.5% listing fee landed at protocol
        assertEq(quote.balanceOf(PROTOCOL), 500 ether, "0.5% listing fee to protocol");
    }

    function test_buy_token_via_pool() public {
        _approveAll(quote, deployer, address(dex));
        vm.startPrank(deployer);
        SimpleERC20 t = dex.launch("Agent Token", "AGT", 1_000_000 ether, deployer);
        vm.stopPrank();
        _approveAll(t, deployer, address(dex));
        _approveAll(quote, bob, address(dex));
        vm.startPrank(bob);
        address amm = dex.list(address(t), 100_000 ether);
        vm.stopPrank();

        // alice buys with quote: approve dex -> dex routes to pool
        _approveAll(quote, alice, address(dex));
        uint256 before = quote.balanceOf(alice);
        vm.startPrank(alice);
        uint256 got = dex.buy(address(t), 10_000 ether, alice);
        vm.stopPrank();
        assertGt(got, 0, "alice received tokens");
        assertEq(quote.balanceOf(alice), before - 10_000 ether, "alice paid quote");
        assertGt(t.balanceOf(alice), 0, "alice holds tokens");
    }

    function test_sell_token_for_quote_round_trips() public {
        _approveAll(quote, deployer, address(dex));
        vm.startPrank(deployer);
        SimpleERC20 t = dex.launch("Agent Token", "AGT", 1_000_000 ether, deployer);
        vm.stopPrank();
        _approveAll(t, deployer, address(dex));
        _approveAll(quote, bob, address(dex));
        vm.startPrank(bob);
        address amm = dex.list(address(t), 100_000 ether);
        vm.stopPrank();

        // alice buys some, then sells it back for quote
        _approveAll(quote, alice, address(dex));
        vm.startPrank(alice);
        uint256 bought = dex.buy(address(t), 10_000 ether, alice);
        vm.stopPrank();

        _approveAll(t, alice, address(dex));
        uint256 qBefore = quote.balanceOf(alice);
        vm.startPrank(alice);
        uint256 quoteBack = dex.sell(address(t), bought, alice);
        vm.stopPrank();
        assertGt(quoteBack, 0, "alice got quote back");
        assertGt(quote.balanceOf(alice), qBefore, "quote balance increased on sell");
    }

    function test_trade_fees_land_at_protocol() public {
        _approveAll(quote, deployer, address(dex));
        vm.startPrank(deployer);
        SimpleERC20 t = dex.launch("Agent Token", "AGT", 1_000_000 ether, deployer);
        vm.stopPrank();
        _approveAll(t, deployer, address(dex));
        _approveAll(quote, bob, address(dex));
        vm.startPrank(bob);
        address amm = dex.list(address(t), 100_000 ether);
        vm.stopPrank();

        // buy fee is paid in TOKEN units to protocol; protocol already holds the 0.5%/5,000 launch fee
        uint256 protocolTokenBefore = t.balanceOf(PROTOCOL);
        _approveAll(quote, alice, address(dex));
        vm.startPrank(alice);
        dex.buy(address(t), 10_000 ether, alice);
        vm.stopPrank();
        assertGt(t.balanceOf(PROTOCOL), protocolTokenBefore, "trade fee (0.05%) in tokens to protocol");
    }

    function test_revert_if_not_permitted_when_gate_set() public {
        // plug a gate that always denies -> even a valid launch must fail closed
        DenyGate gate = new DenyGate();
        _approveAll(quote, deployer, address(dex));
        vm.startPrank(PROTOCOL); // only protocol may set gates
        dex.setGates(address(gate), address(gate), address(0)); // identity deny, authority deny
        vm.stopPrank();
        vm.expectRevert("DEX: not permitted");
        vm.startPrank(deployer);
        dex.launch("Agent Token", "AGT", 1_000_000 ether, deployer);
        vm.stopPrank();
    }
}

// a gate that rejects everything (fail-closed proof)
contract DenyGate {
    function verify(address) external pure returns (bool) { return false; }
    function evaluate(address, address, string memory) external pure returns (bool) { return false; }
    function pass(address) external pure returns (bool) { return false; }
}