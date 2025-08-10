// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Slot0} from "v4-core/types/Slot0.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BrevisApp, IBrevisProof} from "src/abstracts/BrevisApp.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Interface for Service Manager
/// @dev External contract providing tick range suggestions for reinvestment.
interface IServiceManager {
    function getSuggestedTickRange(PoolId poolId, int24 currentTick) external returns (int24, int24);
}

/// @title Dynamic Tick Hook Contract
/// @notice Dynamically adjusts liquidity based on tick range and integrates with a service manager for suggestions.
contract DynamicTick is BaseHook, BrevisApp {
    using PoolIdLibrary for PoolKey;

    /// @notice Information about an LP's liquidity in the pool
    struct LiquidityInfo {
        uint256 totalLiquidity; // Total liquidity provided by the LP
        uint256 dynamicPercentage; // Percentage of dynamic liquidity
        int24 tickLower; // Lower tick boundary
        int24 tickUpper; // Upper tick boundary
    }

    /// Errors
    error InvalidDynamicPercentage();
    error InsufficientLiquidity();
    error InvalidAmount();

    /// Events
    event LiquidityAdded(address indexed lp, uint256 totalLiquidity, int24 tickLower, int24 tickUpper);
    event LiquidityWithdrawn(address indexed lp, uint256 withdrawnAmount, int24 tickLower, int24 tickUpper);
    event LiquidityReinvested(
        address indexed lp,
        uint256 adjustedLiquidity,
        int24 newTickLower,
        int24 newTickUpper
    );

    /// Mappings
    mapping(address => LiquidityInfo) public userLiquidity;
    address[] public allLPs;

    /// External service manager for tick range suggestions
    IServiceManager public serviceManager;

    /// @notice Contract Constructor
    /// @param _manager Address of the Uniswap Pool Manager
    /// @param _brevisProof Address of the Brevis Proof contract
    /// @param _serviceManager Address of the service manager for tick range suggestions
    constructor(
        IPoolManager _manager,
        IBrevisProof _brevisProof,
        IServiceManager _serviceManager
    ) BaseHook(_manager) BrevisApp(_brevisProof) {
        serviceManager = _serviceManager;
    }

    /// @notice Approves tokens for the hook contract
    /// @param token0 Address of token0
    /// @param token1 Address of token1
    /// @param amount Amount to approve
    function approveHook(address token0, address token1, uint256 amount) external {
        if (amount <= 0) revert InvalidAmount();

        IERC20(token0).approve(address(poolManager), amount);
        IERC20(token1).approve(address(poolManager), amount);
    }

    /// @notice Returns permissions for the hook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Handles liquidity additions
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata data
    ) external override onlyPoolManager returns (bytes4) {
        uint256 dynamicPercentage = abi.decode(data, (uint256));
      if (dynamicPrcentage > 100) revert InvalidDynamicPercentage();
        userLiquidity[sender] = LiquidityInfo({
            totalLiquidity: uint256(int256(params.liquidityDelta)),
            dynamicPercentage: dynamicPercentage,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper
        });

        if (userLiquidity[sender].totalLiquidity == 0) {
            allLPs.push(sender);
        }

        emit LiquidityAdded(sender, userLiquidity[sender].totalLiquidity, params.tickLower, params.tickUpper);
        return this.beforeAddLiquidity.selector;
    }

    /// @notice Handles swap logic
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        int24 currentTick = _getCurrentTick(key);

        // Submit to Brevis for proof verification
        _submitToBrevis(key, currentTick);
        return (this.afterSwap.selector, 0);
    }

    /// @notice Submits data to Brevis for proof verification
    function _submitToBrevis(PoolKey calldata key, int24 currentTick) internal {
        uint256 lpCount = allLPs.length;

        address[] memory addresses = new address[](lpCount);
        LiquidityInfo[] memory liquidityInfos = new LiquidityInfo[](lpCount);

        for (uint256 i = 0; i < lpCount; i++) {
            address lp = allLPs[i];
            addresses[i] = lp;
            liquidityInfos[i] = userLiquidity[lp];
        }

        bytes memory proofData = abi.encode(key, addresses, liquidityInfos, currentTick);
        brevisProof.submitProof(uint64(block.chainid), proofData, true);
    }

    /// @notice Handles proofs from Brevis
    function handleProofResult(bytes32 requestId, bytes32 vkHash, bytes calldata appCircuitOutput) internal override {
        (PoolKey memory key, address[] memory outOfRangeLps) = abi.decode(appCircuitOutput, (PoolKey, address[]));

        _processOutOfRangeLps(key, outOfRangeLps);
    }

    /// @notice Processes LPs with out-of-range ticks and reinvests liquidity
    function _processOutOfRangeLps(PoolKey memory key, address[] memory lps) internal {
        uint256 lpCount = lps.length;
        for (uint256 i = 0; i < lpCount; i++) {
            address lp = lps[i];
            LiquidityInfo memory info = userLiquidity[lp];

             uint256 dynamicLiquidity = (info.totalLiquidity * info.dynamicPercentage) / 100;

            (BalanceDelta withdrawnLiquidity, BalanceDelta feeAccrued) = withdrawLiquidity(lp, key, dynamicLiquidity);

            int256 adjustedToken0 = withdrawnLiquidity.amount0() - (withdrawnLiquidity.amount0() / 1000); // 0.1% fee
            int256 adjustedToken1 = withdrawnLiquidity.amount1() - (withdrawnLiquidity.amount1() / 1000); // 0.1% fee
            uint256 adjustedLiquidity = uint256(adjustedToken0 + adjustedToken1);

            // Get suggested tick range
            (int256 newTickLower, int256 newTickUpper) =
                getSuggestedTickRange(PoolIdLibrary.toId(key), _getCurrentTick(key));

            reinvestLiquidity(lp, key, adjustedLiquidity, int24(newTickLower), int24(newTickUpper));

            userLiquidity[lp].tickLower = int24(newTickLower);
            userLiquidity[lp].tickUpper = int24(newTickUpper);

            emit LiquidityReinvested(lp, adjustedLiquidity, int24(newTickLower), int24(newTickUpper));
        }
    }

    /// @notice Fetches suggested tick range from the service manager
    function getSuggestedTickRange(PoolId poolId, int24 currentTick)
        internal
        returns (int24 suggestedTickLower, int24 suggestedTickUpper)
    {
        return serviceManager.getSuggestedTickRange(poolId, currentTick);
    }

    /// @notice Withdraws liquidity from the pool
    function withdrawLiquidity(address lp, PoolKey memory key, uint256 amount)
        internal
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        LiquidityInfo memory info = userLiquidity[lp];

        if (amount > info.totalLiquidity) revert InsufficientLiquidity();

        userLiquidity[lp].totalLiquidity -= amount;

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: info.tickLower,
            tickUpper: info.tickUpper,
            liquidityDelta: -int256(amount),
            salt: bytes32(0)
        });

        (callerDelta, feesAccrued) = poolManager.modifyLiquidity(key, params, "");

        emit LiquidityWithdrawn(lp, amount, info.tickLower, info.tickUpper);
    }

    /// @notice Reinvests adjusted liquidity into the pool
    function reinvestLiquidity(address lp, PoolKey memory key, uint256 amount, int24 tickLower, int24 tickUpper)
        internal
    {
        if (amount <= 0) revert InsufficientLiquidity();

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(amount),
            salt: bytes32(0)
        });

        poolManager.modifyLiquidity(key, params, "");

        userLiquidity[lp].totalLiquidity += amount;
        userLiquidity[lp].tickLower = tickLower;
        userLiquidity[lp].tickUpper = tickUpper;
    }

    /// @notice Retrieves the current tick of the pool
    function _getCurrentTick(PoolKey memory key) internal view returns (int24) {
        PoolId Id = PoolIdLibrary.toId(key);

        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, Id);

        return tick;
    }

    /// @notice Retrieves the tick spacing of the pool
    function _getTickSpacing(PoolKey memory key) internal view returns (int24) {
        return key.tickSpacing;
    }
}

