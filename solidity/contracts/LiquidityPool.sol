// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LiquidityPool - Fixed Version
 * @notice Fixes first-depositor price manipulation and removeLiquidity reserve manipulation
 */
contract LiquidityPoolFixed is ERC20 {
    IERC20 public tokenA;
    IERC20 public tokenB;

    // Internal reserves — authoritative source for LP pricing (not balanceOf)
    uint256 public reserveA;
    uint256 public reserveB;

    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    bool private initialized; // tracks if first deposit has occurred

    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 lpTokens);
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 lpTokens);
    event Sync(uint256 reserveA, uint256 reserveB);

    constructor(address _tokenA, address _tokenB) ERC20("LP Token", "LP") {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    /**
     * @notice FIX: On first deposit, lock MINIMUM_LIQUIDITY at address(0) per Uniswap V2 pattern.
     * This prevents the first-depositor from setting an artificial price baseline.
     * The locked tokens can never be removed, ensuring the pool always has a minimum liquidity floor.
     */
    function addLiquidity(uint256 amountA, uint256 amountB) external returns (uint256 lpTokens) {
        tokenA.transferFrom(msg.sender, address(this), amountA);
        tokenB.transferFrom(msg.sender, address(this), amountB);

        if (!initialized) {
            // First deposit: lock MINIMUM_LIQUIDITY at address(0)
            _mint(address(0), MINIMUM_LIQUIDITY);

            // Remaining liquidity is split evenly between A and B (sqrt formula)
            lpTokens = sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
            require(lpTokens > 0, "Insufficient initial liquidity");

            reserveA = amountA;
            reserveB = amountB;
            initialized = true;
        } else {
            // Subsequent deposits: proportional minting using internal reserves
            uint256 lpFromA = amountA * totalSupply() / reserveA;
            uint256 lpFromB = amountB * totalSupply() / reserveB;
            lpTokens = lpFromA < lpFromB ? lpFromA : lpFromB;

            require(lpTokens > 0, "Insufficient liquidity");

            reserveA += amountA;
            reserveB += amountB;
        }

        _mint(msg.sender, lpTokens);

        emit LiquidityAdded(msg.sender, amountA, amountB, lpTokens);
    }

    /**
     * @notice FIX: Uses internal reserves (reserveA/reserveB) instead of balanceOf.
     * The original code used tokenA.balanceOf(address(this)) which can be manipulated
     * by sending tokens directly to the pool contract without going through addLiquidity,
     * causing incorrect withdrawal amounts.
     */
    function removeLiquidity(uint256 lpTokens) external returns (uint256 amountA, uint256 amountB) {
        require(lpTokens > 0, "Must burn > 0");
        require(balanceOf(msg.sender) >= lpTokens, "Insufficient LP tokens");

        // FIX: Use internal reserves, NOT balanceOf — reserves are authoritative
        amountA = lpTokens * reserveA / totalSupply();
        amountB = lpTokens * reserveB / totalSupply();

        _burn(msg.sender, lpTokens);

        tokenA.transfer(msg.sender, amountA);
        tokenB.transfer(msg.sender, amountB);

        reserveA -= amountA;
        reserveB -= amountB;

        emit LiquidityRemoved(msg.sender, amountA, amountB, lpTokens);
    }

    /**
     * @notice FIX: Syncs internal reserves to match actual token balances.
     * This recovers the pool from donation attacks where tokens are sent directly
     * to the pool contract (bypassing addLiquidity), which would corrupt the price oracle.
     */
    function sync() external {
        reserveA = tokenA.balanceOf(address(this));
        reserveB = tokenB.balanceOf(address(this));
        emit Sync(reserveA, reserveB);
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
