// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "./interfaces/IERC20.sol";

interface IERC20decimals is IERC20 {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/**
 * @title TokenBridgeUtilities
 * @notice A set of internal utility functions
 */
library TokenBridgeUtilities {
    error TooManyDecimalPlaces();

    uint8 public constant MAX_DECIMALS = 8;

    function getAssetDecimals(address assetAddress) internal view returns (uint8) {
        // address(0) is interpreted as native ETH here
        return assetAddress == address(0) ? 18 : IERC20decimals(assetAddress).decimals();
    }

    /**
     * @dev This function checks if the asset amount is valid for the token bridge
     * @param assetAddress The address of the asset
     * @param assetAmount The amount of the asset
     */
    function requireAssetAmountValidForTokenBridge(address assetAddress, uint256 assetAmount) public view {
        uint8 decimals = getAssetDecimals(assetAddress);

        if (decimals > MAX_DECIMALS && trimDust(assetAmount, decimals) != assetAmount) {
            revert TooManyDecimalPlaces();
        }
    }

    function trimDust(uint256 amount, address assetAddress) public view returns (uint256) {
        return trimDust(amount, getAssetDecimals(assetAddress));
    }

    function trimDust(uint256 amount, uint8 decimals) public pure returns (uint256) {
        return denormalizeAmount(normalizeAmount(amount, decimals), decimals);
    }

    /**
     * @dev This function normalizes the amount based on the decimals
     * @param amount The amount to be normalized
     * @param decimals The number of decimals
     * @return The normalized amount
     */
    function normalizeAmount(uint256 amount, uint8 decimals) public pure returns (uint256) {
        if (decimals > MAX_DECIMALS) {
            amount /= uint256(10) ** (decimals - MAX_DECIMALS);
        }

        return amount;
    }

    function denormalizeAmount(uint256 amount, address assetAddress) public view returns (uint256) {
        return denormalizeAmount(amount, getAssetDecimals(assetAddress));
    }

    /**
     * @dev This function normalizes the amount based on the decimals
     * @param amount The amount to be normalized
     * @param decimals The number of decimals
     * @return The normalized amount
     */
    function denormalizeAmount(uint256 amount, uint8 decimals) public pure returns (uint256) {
        if (decimals > MAX_DECIMALS) {
            amount *= uint256(10) ** (decimals - MAX_DECIMALS);
        }

        return amount;
    }
}
