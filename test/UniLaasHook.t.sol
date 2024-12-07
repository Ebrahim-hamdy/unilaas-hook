// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry libraries
import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {UniLaasHook} from "../src/UniLaasHook.sol";

contract UniLaasHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolId poolId;
    UniLaasHook hook;

    address keeper1 = vm.addr(1);
    address keeper2 = vm.addr(2);
    address trader = vm.addr(3);

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy our hook
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        deployCodeTo("UniLaasHook.sol", abi.encode(manager), hookAddress);
        hook = UniLaasHook(hookAddress);

        MockERC20(Currency.unwrap(currency0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(currency1)).approve(
            address(hook),
            type(uint256).max
        );

        (key, ) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);
        hook.addLiquidity(key, 100 ether);

        _seedBalance(keeper1);
        _seedBalance(keeper2);
        _seedBalance(trader);
    }

    function test_placeBid_and_set_keeper() public {
        vm.startPrank(keeper1);

        hook.depositCollateral(key, 100 ether);
        hook.placeBid(key, 0.000_0001 ether);

        vm.stopPrank();

        (, , , UniLaasHook.Bid memory activeBid) = hook.poolsInfo(key.toId());
        assertEq(activeBid.keeper, keeper1);

        vm.startPrank(keeper2);
        hook.depositCollateral(key, 100 ether);
        vm.expectRevert(UniLaasHook.BidTooLow.selector);
        hook.placeBid(key, 0.000_00001 ether);
        assertEq(activeBid.keeper, keeper1);

        vm.stopPrank();
    }

    function test_keeper_receive_fee_on_swap() public {
        vm.startPrank(keeper1);

        hook.depositCollateral(key, 100 ether);
        hook.placeBid(key, 0.000_0001 ether);

        vm.stopPrank();

        swap(key, true, 0.1 ether, "");

        assertEq(manager.balanceOf(keeper1, key.currency1.toId()), 0.0003e18);
    }

    function test_keeper_pay_rent() public {
        vm.startPrank(keeper1);

        hook.depositCollateral(key, 100 ether);
        hook.placeBid(key, 0.000_0001 ether);

        vm.stopPrank();

        vm.prank(trader);
        hook.addLiquidity(key, 100 ether);

        vm.warp(block.timestamp + 100);
        assertLt(_getUpdatedCollateral(keeper1), 100 ether);
    }

    function test_open_option_position_pay_funding_rate() public {
        vm.startPrank(keeper1);

        hook.depositCollateral(key, 100 ether);
        hook.placeBid(key, 0.000_0001 ether);
        hook.updateFundingRate(key, 0.003 ether);

        vm.stopPrank();

        vm.startPrank(trader);
        hook.depositCollateral(key, 100 ether);
        hook.openPosition(key, 1 ether, 2 ether, trader);
        vm.stopPrank();

        vm.warp(block.timestamp + 1001);
        assertLt(_getUpdatedCollateral(trader), 100 ether);
    }

    function test_liquidate_future() public {
        vm.startPrank(keeper1);
        hook.depositCollateral(key, 30 ether);
        hook.placeBid(key, 0.0001 ether);
        hook.updateFundingRate(key, 0.0002 ether);
        vm.stopPrank();

        vm.startPrank(trader);
        hook.depositCollateral(key, 1000 ether);
        hook.openPosition(key, 0.0003 ether, 0.0005 ether, trader);

        assertEq(_getUpdatedCollateral(trader), 1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);

        hook.liquidateFuture(key, trader);
        (, , , UniLaasHook.OptionPositions memory optionPositions) = hook
            .traders(key.toId(), trader);

        assertEq(optionPositions.p0, 0);
        assertEq(optionPositions.p1, 0);

        // liquidator get liquidation fee and remaining collateral transfer to the trader
        uint newCollateral = 1000 ether - (1000 ether * 500) / 10_000;

        assertEq(_getUpdatedCollateral(trader), newCollateral);
    }

    function _seedBalance(address _to) internal {
        MockERC20(Currency.unwrap(currency0)).mint(_to, 10_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(_to, 10_000_000 ether);

        vm.startPrank(_to);
        MockERC20(Currency.unwrap(currency0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(currency1)).approve(
            address(hook),
            type(uint256).max
        );
    }

    function _getUpdatedCollateral(
        address _trader
    ) internal view returns (uint256 updatedCollateral) {
        (, , uint256 collateral, ) = hook.traders(key.toId(), _trader);

        uint256 pendingFee = hook._calcPendingFundingFee(key, _trader);
        pendingFee += hook._calcPendingRentFee(key, _trader);

        if (pendingFee > collateral) pendingFee = collateral;
        updatedCollateral = collateral - pendingFee;
    }
}
