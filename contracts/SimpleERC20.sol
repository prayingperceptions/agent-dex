// SPDX-License-Identifier: MIT
// SimpleERC20.sol — minimal mintable ERC-20. Optionally mints a protocol fee to a
// recipient at construction (0.5% launch fee), mirroring the proven agent-launch Token.
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

    constructor(string memory name_, string memory symbol_, uint256 supply_, address minter_, address feeTo_, uint256 feeBps_) {
        name = name_; symbol = symbol_;
        totalSupply = supply_; minter = minter_;

        uint256 fee = (supply_ * feeBps_) / 10000; // e.g. 50 bps == 0.5%
        uint256 net = supply_ - fee;
        balanceOf[minter_] = net;
        if (feeTo_ != address(0) && fee > 0) {
            balanceOf[feeTo_] = fee;               // protocol fee minted at construction
            emit Transfer(address(0), feeTo_, fee);
        }
        emit Transfer(address(0), minter_, net);
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