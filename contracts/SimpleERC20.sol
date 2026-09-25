// SPDX-License-Identifier: MIT
// SimpleERC20.sol — minimal mintable ERC-20. Mints the FULL supply to the minter
// (the Agent DEX), which then controls the exact launch split (1% deployer /
// 0.5% protocol / 0.5% lottery / 98% float).
pragma solidity ^0.8.20;

contract SimpleERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals = 18;
    uint256 public immutable totalSupply;
    address public immutable minter;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(string memory name_, string memory symbol_, uint256 supply_, address minter_) {
        name = name_; symbol = symbol_;
        totalSupply = supply_; minter = minter_;
        balanceOf[minter_] = supply_;
        emit Transfer(address(0), minter_, supply_);
    }

    function mint(address to, uint256 value) external {
        require(msg.sender == minter, "SRC: only minter");
        require(balanceOf[minter] >= value, "SRC: minter lacks backing");
        balanceOf[minter] -= value;
        balanceOf[to] += value;
        emit Transfer(minter, to, value);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(to != address(0), "SRC: zero dest");
        require(balanceOf[msg.sender] >= value, "SRC: insufficient");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(allowance[from][msg.sender] >= value, "SRC: allowance");
        require(balanceOf[from] >= value, "SRC: insufficient");
        allowance[from][msg.sender] -= value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}