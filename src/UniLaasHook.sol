// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UniLaasHook is BaseHook {
    using SafeCast for int256;
    using SafeCast for uint256;
    using LPFeeLibrary for uint24;

    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    /// -----------------------------------------------------------------------
    /// Custom types
    /// -----------------------------------------------------------------------
    struct Bid {
        uint256 rent;
        address keeper;
    }

    struct PoolInfo {
        int24 minTick;
        int24 maxTick;
        uint256 fundingRate;
        Bid activeBid;
    }

    /**
     * @dev struct for the position openings
     */
    struct OptionPositions {
        uint256 p0;
        uint256 p1;
    }

    struct Trader {
        uint256 pendingFundingPayment;
        uint256 lastTimeFundUpdated;
        uint256 collateral;
        OptionPositions optionPositions; //this changes only when the position is realized (decreased), increased, or closed.
    }

    struct CallbackData {
        PoolKey key;
        address sender;
        int256 liquidityDelta;
        int256 amountDelta0;
        int256 amountDelta1;
        uint256 rent;
    }

    /// @notice Mapping of pool IDs to their respective PoolInfo
    mapping(PoolId => PoolInfo) public poolsInfo;
    mapping(PoolId => mapping(address => Trader)) public traders;
    mapping(PoolId => mapping(address => uint256)) public liquidatorsBalance;

    uint256 public constant HEALTHY_PERIOD_BEFORE_LIQUIDATED = 300;
    /// @notice The commission fee, in basis points, collected at option mint.
    /// @dev commissions are only paid when a new position is minted.
    uint256 public constant LIQUIDATOR_FEE = 500;
    uint256 public constant MULTIPLIER = 1e18;
    uint24 public DEFAULT_SWAP_FEE = 3000;
    bool public constant PAY_IN_TOKEN0 = true; //need to make it dynamic
    uint256 internal constant FEE_PRECISION = 10_000;
    bytes internal constant ZERO_BYTES = "";

    /// -----------------------------------------------------------------------
    /// Custom errors
    /// -----------------------------------------------------------------------
    error InsufficientCollateral();
    error AddLiquidityThroughHook();
    error BidTooLow();
    error InsufficientLiquidity();
    error OnlyKeeper();
    error PositionNotLiquidatable();
    error PositionNotFound();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------
    event LiquidityAdded(address indexed provider, uint256 amount);
    event LiquidityRemoved(address indexed provider, uint256 amount);

    event PositionLiquidated(
        address indexed liquidator,
        address indexed trader
    );

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Constructor for the RugGuard contract
     * @param _poolManager The address of the Uniswap V4 pool manager
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the hook's permissions
     * @return Hooks.Permissions The hook's permissions
     */
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /**
     * @notice Hook called after a pool is initialized
     * @param key The pool key
     * @return The function selector
     */
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) external override returns (bytes4) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);

        poolsInfo[key.toId()] = PoolInfo(
            tickLower,
            tickLower + key.tickSpacing,
            0,
            Bid(0, address(0))
        );

        return BaseHook.afterInitialize.selector;
    }

    /// @notice  Disable adding liquidity through the PM
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    /// @notice  Transfer Swap's fee to pool keeper
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (poolsInfo[key.toId()].activeBid.keeper == address(0))
            return (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        int256 keeperSwapFee = _settleSwapFee(key, params);

        //   return the amount that's taken by the hook to keeper
        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(keeperSwapFee.toInt128(), 0),
            0
        );
    }

    /// @notice  Place bid to become pool keeper
    /// keeper pay rent, get funding rate and swap fee
    function placeBid(PoolKey calldata key, uint256 rent) external {
        _claimPendingFees(key, msg.sender);

        if (
            traders[key.toId()][msg.sender].collateral <
            rent * HEALTHY_PERIOD_BEFORE_LIQUIDATED
        ) revert InsufficientCollateral();

        if (poolsInfo[key.toId()].activeBid.rent > rent) revert BidTooLow();
        else {
            if (poolsInfo[key.toId()].activeBid.keeper != msg.sender) {
                _claimPendingFees(key, poolsInfo[key.toId()].activeBid.keeper);

                poolsInfo[key.toId()].activeBid.keeper = msg.sender;
            }

            poolsInfo[key.toId()].activeBid.rent = rent;
        }
    }

    /**
     * @notice deposit collateral to open positions
     * @param key: pool key
     * @param amount: amount in token 0
     */
    function depositCollateral(PoolKey calldata key, uint256 amount) external {
        traders[key.toId()][msg.sender].collateral += amount;

        IERC20(Currency.unwrap(key.currency0)).transferFrom(
            msg.sender,
            address(this),
            amount
        );
    }

    /**
     * @notice withdraw assets from the position
     * @param key: pool key
     * @param amount: amount in token 0
     */
    function withdrawCollateral(PoolKey calldata key, uint256 amount) external {
        _claimPendingFees(key, msg.sender);

        if (amount > traders[key.toId()][msg.sender].collateral)
            revert InsufficientCollateral();

        traders[key.toId()][msg.sender].collateral -= amount;

        // always for token0 for simplicity
        IERC20(Currency.unwrap(key.currency0)).transfer(msg.sender, amount);
    }

    ///@notice Adds liquidity to pay gains.
    ///@dev the liquidity amount in token0
    function addLiquidity(
        PoolKey calldata key,
        uint256 amount
    ) external payable returns (BalanceDelta delta) {
        delta = _handleLiquidity(key, amount.toInt256());

        emit LiquidityAdded(msg.sender, amount);
    }

    ///@notice Removes liquidity.
    ///@dev the liquidity amount in token0
    function removeLiquidity(
        PoolKey calldata key,
        uint256 amount
    ) external payable returns (BalanceDelta delta) {
        if (amount > liquidatorsBalance[key.toId()][msg.sender])
            revert InsufficientLiquidity();
        delta = _handleLiquidity(key, -amount.toInt256());

        emit LiquidityRemoved(msg.sender, amount);
    }

    ///@notice Handles add/remove liquidity.
    function _handleLiquidity(
        PoolKey calldata key,
        int256 liquidityDelta
    ) internal returns (BalanceDelta delta) {
        _claimPendingFees(key, poolsInfo[key.toId()].activeBid.keeper);

        if (poolsInfo[key.toId()].activeBid.keeper != msg.sender) {
            _claimPendingFees(key, msg.sender);
        }

        delta = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(key, msg.sender, liquidityDelta, 0, 0, 0)
                )
            ),
            (BalanceDelta)
        );

        liquidatorsBalance[key.toId()][msg.sender] = uint256(
            liquidatorsBalance[key.toId()][msg.sender].toInt256() +
                liquidityDelta
        );
    }

    /**
     * @notice Called by the keeper of a pool to update the options funding rate
     * @param key: pool key
     * @param rate: new options funding rate
     */
    function updateFundingRate(PoolKey calldata key, uint256 rate) external {
        if (msg.sender != poolsInfo[key.toId()].activeBid.keeper)
            revert OnlyKeeper();

        poolsInfo[key.toId()].fundingRate = rate;
    }

    /// @notice maintain healthy collateral ratios in the market, safeguarding the system against under-collateralized positions
    /// Liquidators are incentivized to maintain market health by receiving a portion of the liquidated trader's collateral.
    /// A liquidatorFee is taken from the position’s remaining collateral
    /// keeper should set funding rate neither too low (which forgoes potential earnings) nor too high
    /// (which could deter participation) to ensure that the price of the perpetual contract aligns
    /// closely with the price of the underlying asset. If the perpetual contract's price is higher
    /// than that of the underlying asset, long positions pay short positions, and vice versa.
    function liquidateFuture(PoolKey calldata key, address _trader) external {
        PoolId poolId = key.toId();
        PoolInfo storage pool = poolsInfo[poolId];

        uint256 collateral = traders[poolId][_trader].collateral;

        if (collateral == 0) revert PositionNotFound();

        _claimPendingFees(key, _trader);

        uint256 rent = pool.activeBid.keeper == _trader
            ? pool.activeBid.rent
            : 0;
        uint256 openPositions = rent +
            (traders[poolId][_trader].optionPositions.p0 +
                traders[poolId][_trader].optionPositions.p1) *
            pool.fundingRate;

        if (collateral >= openPositions * HEALTHY_PERIOD_BEFORE_LIQUIDATED)
            revert PositionNotLiquidatable();

        _closePosition(
            key,
            traders[poolId][_trader].optionPositions.p0,
            traders[poolId][_trader].optionPositions.p1,
            _trader
        );

        uint256 liquidatorFee = (collateral * LIQUIDATOR_FEE) / FEE_PRECISION;

        traders[poolId][_trader].collateral = collateral - liquidatorFee;
        traders[poolId][msg.sender].collateral += liquidatorFee;

        emit PositionLiquidated(msg.sender, _trader);
    }

    /// @notice open a perpetual position
    function openPosition(
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        address _trader
    ) external returns (BalanceDelta delta) {
        delta = _executeOption(
            key,
            (amount0).toInt256(),
            (amount1).toInt256(),
            _trader
        );
        Trader storage traderInfo = traders[key.toId()][_trader];

        traderInfo.optionPositions.p0 += amount0;
        traderInfo.optionPositions.p1 += amount1;
    }

    /// @notice close the position
    function closePosition(
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        address _trader
    ) external returns (BalanceDelta delta) {
        delta = _closePosition(key, amount0, amount1, _trader);
    }

    function _closePosition(
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        address _trader
    ) internal returns (BalanceDelta delta) {
        if (_trader == poolsInfo[key.toId()].activeBid.keeper)
            poolsInfo[key.toId()].activeBid.keeper = address(0);

        delta = _executeOption(
            key,
            -(amount0).toInt256(),
            -(amount1).toInt256(),
            _trader
        );
        Trader storage traderInfo = traders[key.toId()][_trader];

        traderInfo.optionPositions.p0 -= amount0;
        traderInfo.optionPositions.p1 -= amount1;
    }

    /// @notice internal function to handle opening/closing positions
    function _executeOption(
        PoolKey calldata key,
        int256 amount0,
        int256 amount1,
        address _trader
    ) internal returns (BalanceDelta delta) {
        _claimPendingFees(key, poolsInfo[key.toId()].activeBid.keeper);
        _claimPendingFees(key, _trader);

        delta = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData(
                        key,
                        _trader,
                        -(amount0 + amount1),
                        -(amount0 / _getTokenAmount(key, true).toInt256()),
                        -(amount1 / _getTokenAmount(key, false).toInt256()),
                        0
                    )
                )
            ),
            (BalanceDelta)
        );
    }

    /// @notice internal function to distribute swapping fee to active keeper
    function _settleSwapFee(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal returns (int256 keeperSwapFee) {
        address keeper = poolsInfo[key.toId()].activeBid.keeper;

        _claimPendingFees(key, keeper);

        keeperSwapFee =
            (params.amountSpecified * uint256(DEFAULT_SWAP_FEE).toInt256()) /
            1e6;
        keeperSwapFee = keeperSwapFee > 0 ? keeperSwapFee : -keeperSwapFee;

        Currency feeCurrency = params.amountSpecified > 0 != params.zeroForOne
            ? key.currency0
            : key.currency1;

        feeCurrency.take(poolManager, keeper, keeperSwapFee.toUint256(), true);
    }

    /// @notice get Lower Usable Tick - use to init the pool
    function _getTickLower(
        int24 tick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }

    /// @notice Callback function invoked during the unlock of liquidity, executing any required state changes.
    function _unlockCallback(
        bytes calldata rawData
    ) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        int256 amountDelta0 = data.amountDelta0;
        int256 amountDelta1 = data.amountDelta1;

        if (data.liquidityDelta > 0) {
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(
                data.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: poolsInfo[data.key.toId()].minTick,
                    tickUpper: poolsInfo[data.key.toId()].maxTick,
                    liquidityDelta: data.liquidityDelta,
                    salt: bytes32(ZERO_BYTES)
                }),
                ZERO_BYTES
            );

            amountDelta0 += delta.amount0();
            amountDelta1 += delta.amount1();
        }

        _settleDeltas(data.key, data.sender, amountDelta0, amountDelta1, false);
        _settleDeltas(
            data.key,
            address(this),
            -data.amountDelta0,
            -data.amountDelta0,
            true
        );

        if (data.rent > 0) {
            poolManager.donate(data.key, data.rent, 0, ZERO_BYTES);

            _settleDeltas(
                data.key,
                address(this),
                -data.rent.toInt256(),
                0,
                false
            );
        }

        return
            abi.encode(
                toBalanceDelta(int128(amountDelta0), int128(amountDelta1))
            );
    }

    /// @notice Settles any owed balances after liquidity modification.
    function _settleDeltas(
        PoolKey memory key,
        address sender,
        int256 delta0,
        int256 delta1,
        bool takeClaims
    ) internal {
        if (delta0 < 0)
            key.currency0.settle(
                poolManager,
                sender,
                uint256(-delta0),
                takeClaims
            );

        if (delta0 > 0)
            key.currency0.take(
                poolManager,
                sender,
                uint256(delta0),
                takeClaims
            );

        if (delta1 < 0)
            key.currency1.settle(
                poolManager,
                sender,
                uint256(-delta1),
                takeClaims
            );

        if (delta1 > 0)
            key.currency1.take(
                poolManager,
                sender,
                uint256(delta1),
                takeClaims
            );
    }

    /// @notice claim pending rent and funding rate fees
    function _claimPendingFees(PoolKey calldata key, address _trader) internal {
        PoolId poolId = key.toId();

        uint256 pendingFundPayment = _calcPendingFundingFee(key, _trader);
        uint256 pendingRentPayment = _calcPendingRentFee(key, _trader);

        if (_trader == poolsInfo[poolId].activeBid.keeper) {
            traders[key.toId()][poolsInfo[poolId].activeBid.keeper]
                .collateral += pendingFundPayment;

            if (pendingRentPayment > 0) {
                traders[poolId][_trader].collateral -= pendingRentPayment;
                poolManager.unlock(
                    abi.encode(
                        CallbackData(key, _trader, 0, 0, 0, pendingRentPayment)
                    )
                );
            }

            if (traders[poolId][_trader].collateral == 0) {
                poolsInfo[poolId].activeBid.keeper = address(0);
                poolsInfo[poolId].activeBid.rent = 0;
            }
        }

        traders[poolId][_trader].collateral -= pendingFundPayment;
        traders[poolId][_trader].lastTimeFundUpdated = block.timestamp;
    }

    /// @notice claim pending funding rate fee
    function _calcPendingFundingFee(
        PoolKey calldata key,
        address _trader
    ) public view returns (uint256 pendingFundFee) {
        PoolId poolId = key.toId();

        uint256 traderOpenPositions = traders[poolId][_trader]
            .optionPositions
            .p0 + traders[poolId][_trader].optionPositions.p1;

        if (traderOpenPositions > 0) {
            pendingFundFee =
                (poolsInfo[key.toId()].fundingRate *
                    (block.timestamp -
                        traders[key.toId()][_trader].lastTimeFundUpdated) *
                    traderOpenPositions) /
                1e18;
        }
    }

    /// @notice claim pending rent fee
    function _calcPendingRentFee(
        PoolKey calldata key,
        address _trader
    ) public view returns (uint256 pendingRentFee) {
        if (poolsInfo[key.toId()].activeBid.keeper == _trader)
            pendingRentFee =
                poolsInfo[key.toId()].activeBid.rent *
                (block.timestamp -
                    traders[key.toId()][_trader].lastTimeFundUpdated);
    }

    /// @notice Get the amount of tokens for the given amount of 1e18 liquidity and ticks
    function _getTokenAmount(
        PoolKey calldata key,
        bool isToken0
    ) internal view returns (uint256 tokenAmount) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(
            poolsInfo[key.toId()].minTick
        );
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(
            poolsInfo[key.toId()].maxTick
        );

        if (isToken0) {
            tokenAmount = LiquidityAmounts.getLiquidityForAmount0(
                sqrtRatioAX96,
                sqrtRatioBX96,
                1e18
            );
        } else {
            tokenAmount = LiquidityAmounts.getLiquidityForAmount1(
                sqrtRatioAX96,
                sqrtRatioBX96,
                1e18
            );
        }
    }
}
