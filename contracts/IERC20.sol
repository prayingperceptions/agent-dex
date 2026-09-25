// SPDX-License-Identifier: MIT
// IERC20.sol — minimal ERC-20 interface so Agent DEX can hold/swap REAL USDC (and
// any standard token) on Base, not just our SimpleERC20. Our SimpleERC20 conforms.
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}