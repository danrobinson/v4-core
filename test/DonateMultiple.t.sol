// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {Test} from "forge-std/Test.sol";

import {BalanceDelta} from "../src/types/BalanceDelta.sol";
import {BalanceDelta as BalanceDeltaLegacy} from "v4-core-single-donate/types/BalanceDelta.sol";
import {Constants} from "./utils/Constants.sol";
import {Deployers} from "./utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {Currency as CurrencyLegacy, CurrencyLibrary as CurrencyLibraryLegacy} from "v4-core-single-donate/types/Currency.sol";
import {FixedPoint96} from "../src/libraries/FixedPoint96.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {IHooks} from "../src/interfaces/IHooks.sol";
import {IHooks as IHooksLegacy} from "v4-core-single-donate/interfaces/IHooks.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {IPoolManager as IPoolManagerLegacy} from "v4-core-single-donate/interfaces/IPoolManager.sol";
import {LibSort} from "solady/src/utils/LibSort.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolDonateTest} from "../src/test/PoolDonateTest.sol";
import {PoolDonateTest as PoolDonateTestLegacy} from "v4-core-single-donate/test/PoolDonateTest.sol";
import {PoolIdLibrary as PoolIdLibraryLegacy} from "v4-core-single-donate/types/PoolId.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {PoolKey as PoolKeyLegacy} from "v4-core-single-donate/types/PoolKey.sol";
import {PoolManager} from "../src/PoolManager.sol";
import {PoolManager as PoolManagerLegacy} from "v4-core-single-donate/PoolManager.sol";
import {PoolModifyPositionTest} from "../src/test/PoolModifyPositionTest.sol";
import {PoolModifyPositionTest as PoolModifyPositionTestLegacy} from "v4-core-single-donate/test/PoolModifyPositionTest.sol";
import {PoolSwapTest as PoolSwapTestLegacy} from "v4-core-single-donate/test/PoolSwapTest.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {TokenFixture} from "./utils/TokenFixture.sol";

contract DonateMultipleTest is Test, Deployers, TokenFixture {
    using CurrencyLibrary for Currency;
    using CurrencyLibraryLegacy for CurrencyLegacy;
    using PoolIdLibraryLegacy for PoolKeyLegacy;

    uint256 private constant TEST_BALANCE = type(uint256).max / 3 * 2;

    PoolManager private _manager = Deployers.createFreshManager();
    PoolModifyPositionTest private _modifyPositionRouter = new PoolModifyPositionTest(_manager);
    PoolDonateTest private _donateRouter = new PoolDonateTest(_manager);

    CurrencyLegacy private currency0Legacy;
    CurrencyLegacy private currency1Legacy;
    PoolManagerLegacy private _managerLegacy = new PoolManagerLegacy(500000);
    PoolModifyPositionTestLegacy private _modifyPositionRouterLegacy = new PoolModifyPositionTestLegacy(_managerLegacy);
    PoolSwapTestLegacy private _swapRouterLegacy = new PoolSwapTestLegacy(_managerLegacy);
    PoolDonateTestLegacy private _donateRouterLegacy = new PoolDonateTestLegacy(_managerLegacy);

    function setUp() external {
        // Deploy tokens.
        initializeTokens();
        currency0Legacy = CurrencyLegacy.wrap(Currency.unwrap(currency0));
        currency1Legacy = CurrencyLegacy.wrap(Currency.unwrap(currency1));

        // Mint & approve test balances.
        MockERC20(Currency.unwrap(currency0)).mint(address(this), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency0)).approve(address(_modifyPositionRouter), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency1)).approve(address(_modifyPositionRouter), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency0)).approve(address(_donateRouter), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency1)).approve(address(_donateRouter), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency0)).approve(address(_donateRouterLegacy), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency1)).approve(address(_donateRouterLegacy), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency0)).approve(address(_swapRouterLegacy), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency1)).approve(address(_swapRouterLegacy), TEST_BALANCE);
    }

    // TODO: Should we combine test files or refactor these helpers into base class?

    /*//////////////////////////////////////////////////////////////////////////
                                    DONATION HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _min(int24 a, int24 b) private pure returns (int24) {
        if (a < b) {
            return a;
        } else {
            return b;
        }
    }

    function _max(int24 a, int24 b) private pure returns (int24) {
        if (a > b) {
            return a;
        } else {
            return b;
        }
    }

    function _floorToTickSpacing(PoolKey memory key, int24 tick) private pure returns (int24) {
        return tick > 0 ? _truncateToTickSpacing(key, tick) : _truncateToTickSpacing(key, tick - key.tickSpacing + 1);
    }

    function _ceilToTickSpacing(PoolKey memory key, int24 tick) private pure returns (int24) {
        return tick > 0 ? _truncateToTickSpacing(key, tick + key.tickSpacing - 1) : _truncateToTickSpacing(key, tick);
    }

    function _truncateToTickSpacing(PoolKey memory key, int24 tick) private pure returns (int24) {
        return tick / key.tickSpacing * key.tickSpacing;
    }

    struct LpInfo {
        // address of the lp
        address lpAddress;
        // liquidity added
        int256 liquidity;
        // amount0 added by the LP
        uint256 amount0;
        // amount1 added by the LP
        uint256 amount1;
        // the lower tick the LP added to
        int24 tickLower;
        // the upper tick the LP added to
        int24 tickUpper;
    }

    function _createLpPositionsSymmetric(PoolKey memory key, uint256 nPositions)
        internal
        returns (LpInfo[] memory lpInfo)
    {
        lpInfo = new LpInfo[](nPositions);
        for (uint256 i = 0; i < nPositions; i++) {
            int24 tick = key.tickSpacing * int24(uint24(i + 1));

            lpInfo[i] = _createLpPositionSymmetric(key, tick);
        }
    }

    function _createLpPositionSymmetric(PoolKey memory key, int24 tick) private returns (LpInfo memory lpInfo) {
        uint256 amount = 1 ether;
        int256 liquidityAmount =
            int256(uint256(getLiquidityForAmount0(SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(tick), amount)));

        lpInfo = _createLpPosition(key, -tick, tick, liquidityAmount);
    }

    function _createLpPosition(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity)
        private
        returns (LpInfo memory lpInfo)
    {
        require(liquidity >= 0 && liquidity <= int256(uint256(type(uint128).max)));

        // Create a unique lp address.
        address lpAddr = address(bytes20(keccak256(abi.encode(tickLower, tickUpper))));

        // Compute & mint tokens required.
        // TODO: Assumes pool was initted at tick 0.
        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(0),
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            uint128(uint256(liquidity))
        );
        MockERC20(Currency.unwrap(currency0)).mint(lpAddr, amount0 + 1); // TODO: should we bake this in to the amount?
        MockERC20(Currency.unwrap(currency1)).mint(lpAddr, amount1 + 1); // TODO: should we bake this in to the amount?

        // Add the liquidity.
        vm.startPrank(lpAddr);
        MockERC20(Currency.unwrap(currency0)).approve(address(_modifyPositionRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(_modifyPositionRouter), type(uint256).max);
        BalanceDelta delta = _modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(tickLower, tickUpper, liquidity), bytes("")
        );
        vm.stopPrank();

        lpInfo = LpInfo({
            lpAddress: lpAddr,
            liquidity: int256(uint256(liquidity)),
            amount0: uint256(uint128(delta.amount0())),
            amount1: uint256(uint128(delta.amount1())),
            tickLower: tickLower,
            tickUpper: tickUpper
        });
    }

    function _createLpPositionLegacy(PoolKeyLegacy memory key, int24 tickLower, int24 tickUpper, int256 liquidity)
        private
        returns (LpInfo memory lpInfo)
    {
        require(liquidity >= 0 && liquidity <= int256(uint256(type(uint128).max)));

        // Create a unique lp address.
        address lpAddr = address(bytes20(keccak256(abi.encode(tickLower, tickUpper))));

        // Compute & mint tokens required.
        // TODO: Assumes pool was initted at tick 0.
        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(0),
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            uint128(uint256(liquidity))
        );
        MockERC20(Currency.unwrap(currency0)).mint(lpAddr, amount0 + 1); // TODO: should we bake this in to the amount?
        MockERC20(Currency.unwrap(currency1)).mint(lpAddr, amount1 + 1); // TODO: should we bake this in to the amount?

        // Add the liquidity.
        vm.startPrank(lpAddr);
        MockERC20(Currency.unwrap(currency0)).approve(address(_modifyPositionRouterLegacy), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(_modifyPositionRouterLegacy), type(uint256).max);
        BalanceDeltaLegacy delta = _modifyPositionRouterLegacy.modifyPosition(
            key, IPoolManagerLegacy.ModifyPositionParams(tickLower, tickUpper, liquidity), bytes("")
        );
        vm.stopPrank();

        lpInfo = LpInfo({
            lpAddress: lpAddr,
            liquidity: int256(uint256(liquidity)),
            amount0: uint256(uint128(delta.amount0())),
            amount1: uint256(uint128(delta.amount1())),
            tickLower: tickLower,
            tickUpper: tickUpper
        });
    }

    function getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, FixedPoint96.Q96);
        liquidity = uint128(FullMath.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return FullMath.mulDiv(
            uint256(liquidity) << FixedPoint96.RESOLUTION, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96
        ) / sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96);
    }

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }

    receive() external payable {}

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _donateLegacy(
        PoolKeyLegacy memory key,
        uint256[] memory amounts0,
        uint256[] memory amounts1,
        int24[] memory ticks
    ) private {
        // Used for all swaps.
        PoolSwapTestLegacy.TestSettings memory testSettings =
            PoolSwapTestLegacy.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        for (uint256 i = 0; i < ticks.length; ++i) {
            // Destructure next donate.
            uint256 amount0 = amounts0[i];
            uint256 amount1 = amounts1[i];
            int24 tick = ticks[i];

            // Load pool state.
            (, int24 startingTick,,) = _managerLegacy.getSlot0(key.toId());

            // Swap to target.
            if (tick == startingTick) {
                // No swap.
            } else if (tick > startingTick) {
                IPoolManagerLegacy.SwapParams memory params =
                    IPoolManagerLegacy.SwapParams({zeroForOne: false, amountSpecified: type(int256).max, sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tick)});
                _swapRouterLegacy.swap(key, params, testSettings, bytes(""));
            } else {
                IPoolManagerLegacy.SwapParams memory params =
                    IPoolManagerLegacy.SwapParams({zeroForOne: true, amountSpecified: type(int256).max, sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tick)});
                _swapRouterLegacy.swap(key, params, testSettings, bytes(""));
            }

            // Donate.
            _donateRouterLegacy.donate(key, amount0, amount1, bytes(""));

            // Swap back to starting tick.
            if (tick == startingTick) {
                // No swap.
            } else if (tick < startingTick) {
                IPoolManagerLegacy.SwapParams memory params =
                    IPoolManagerLegacy.SwapParams({zeroForOne: false, amountSpecified: type(int256).max, sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(startingTick)});
                _swapRouterLegacy.swap(key, params, testSettings, bytes(""));
            } else {
                IPoolManagerLegacy.SwapParams memory params =
                    IPoolManagerLegacy.SwapParams({zeroForOne: true, amountSpecified: type(int256).max, sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(startingTick)});
                _swapRouterLegacy.swap(key, params, testSettings, bytes(""));
            }
        }
    }

    function _donateMultiple(
        PoolKey memory key,
        uint256[] memory amounts0,
        uint256[] memory amounts1,
        int24[] memory ticks
    ) private {
        _donateRouter.donateRange(key, amounts0, amounts1, ticks);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    BASE CASES
    //////////////////////////////////////////////////////////////////////////*/

    function testDonateLegacy_Current() external {
        // Create pool.
        PoolKeyLegacy memory key =
            PoolKeyLegacy({currency0: currency0Legacy, currency1: currency1Legacy, fee: 0, hooks: IHooksLegacy(address(0)), tickSpacing: 10});
        _managerLegacy.initialize(key, SQRT_RATIO_1_1, bytes(""));

        // Create 1 LP position covering active tick.
        LpInfo memory lpInfo = _createLpPositionLegacy(key, -50, 50, 1e18);

        // Donate 1e18 amount0 & amount1 to in range LPs.
        uint256[] memory amounts0 = new uint256[](1);
        amounts0[0] = 1e18;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e18;
        int24[] memory ticks = new int24[](1);
        ticks[0] = 0;

        _donateLegacy(key, amounts0, amounts1, ticks);

        // Full redeem the LP.
        vm.prank(lpInfo.lpAddress);
        _modifyPositionRouterLegacy.modifyPosition(
            key, IPoolManagerLegacy.ModifyPositionParams(lpInfo.tickLower, lpInfo.tickUpper, -lpInfo.liquidity), bytes("")
        );

        // Ensure the LP received the donation.
        assertApproxEqAbs(key.currency0.balanceOf(lpInfo.lpAddress), lpInfo.amount0 + 1e18, 1);
        assertApproxEqAbs(key.currency1.balanceOf(lpInfo.lpAddress), lpInfo.amount1 + 1e18, 1);
    }

    function testDonateLegacy_Above() external {
        // Create pool.
        PoolKeyLegacy memory key =
            PoolKeyLegacy({currency0: currency0Legacy, currency1: currency1Legacy, fee: 0, hooks: IHooksLegacy(address(0)), tickSpacing: 10});
        _managerLegacy.initialize(key, SQRT_RATIO_1_1, bytes(""));

        // Create 1 LP position covering active tick.
        LpInfo memory lpInfo = _createLpPositionLegacy(key, -50, 50, 1e18);

        // Donate 1e18 amount0 & amount1 to in range LPs.
        uint256[] memory amounts0 = new uint256[](1);
        amounts0[0] = 1e18;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e18;
        int24[] memory ticks = new int24[](1);
        ticks[0] = 20;

        _donateLegacy(key, amounts0, amounts1, ticks);

        // Full redeem the LP.
        vm.prank(lpInfo.lpAddress);
        _modifyPositionRouterLegacy.modifyPosition(
            key, IPoolManagerLegacy.ModifyPositionParams(lpInfo.tickLower, lpInfo.tickUpper, -lpInfo.liquidity), bytes("")
        );

        // Ensure the LP received the donation.
        assertApproxEqAbs(key.currency0.balanceOf(lpInfo.lpAddress), lpInfo.amount0 + 1e18, 1);
        assertApproxEqAbs(key.currency1.balanceOf(lpInfo.lpAddress), lpInfo.amount1 + 1e18, 1);
    }

    function testDonateLegacy_Below() external {
        // Create pool.
        PoolKeyLegacy memory key =
            PoolKeyLegacy({currency0: currency0Legacy, currency1: currency1Legacy, fee: 0, hooks: IHooksLegacy(address(0)), tickSpacing: 10});
        _managerLegacy.initialize(key, SQRT_RATIO_1_1, bytes(""));

        // Create 1 LP position covering active tick.
        LpInfo memory lpInfo = _createLpPositionLegacy(key, -50, 50, 1e18);

        // Donate 1e18 amount0 & amount1 to in range LPs.
        uint256[] memory amounts0 = new uint256[](1);
        amounts0[0] = 1e18;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e18;
        int24[] memory ticks = new int24[](1);
        ticks[0] = -20;

        _donateLegacy(key, amounts0, amounts1, ticks);

        // Full redeem the LP.
        vm.prank(lpInfo.lpAddress);
        _modifyPositionRouterLegacy.modifyPosition(
            key, IPoolManagerLegacy.ModifyPositionParams(lpInfo.tickLower, lpInfo.tickUpper, -lpInfo.liquidity), bytes("")
        );

        // Ensure the LP received the donation.
        assertApproxEqAbs(key.currency0.balanceOf(lpInfo.lpAddress), lpInfo.amount0 + 1e18, 1);
        assertApproxEqAbs(key.currency1.balanceOf(lpInfo.lpAddress), lpInfo.amount1 + 1e18, 1);
    }

    function testDonateMultiple_Current() external {
        // Create pool.
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, hooks: IHooks(address(0)), tickSpacing: 10});
        _manager.initialize(key, SQRT_RATIO_1_1, bytes(""));

        // Create 1 LP position covering active tick.
        LpInfo memory lpInfo = _createLpPosition(key, -50, 50, 1e18);

        // Donate 1e18 amount0 & amount1 to in range LPs.
        uint256[] memory amounts0 = new uint256[](1);
        amounts0[0] = 1e18;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e18;
        int24[] memory ticks = new int24[](1);
        ticks[0] = 0;

        _donateMultiple(key, amounts0, amounts1, ticks);

        // Full redeem the LP.
        vm.prank(lpInfo.lpAddress);
        _modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo.tickLower, lpInfo.tickUpper, -lpInfo.liquidity), bytes("")
        );

        // Ensure the LP received the donation.
        assertApproxEqAbs(key.currency0.balanceOf(lpInfo.lpAddress), lpInfo.amount0 + 1e18, 1);
        assertApproxEqAbs(key.currency1.balanceOf(lpInfo.lpAddress), lpInfo.amount1 + 1e18, 1);
    }

    function testDonateMultiple_Above() external {
        // Create pool.
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, hooks: IHooks(address(0)), tickSpacing: 10});
        _manager.initialize(key, SQRT_RATIO_1_1, bytes(""));

        // Create 1 LP position covering active tick.
        LpInfo memory lpInfo = _createLpPosition(key, -50, 50, 1e18);

        // Donate 1e18 amount0 & amount1 to in range LPs.
        uint256[] memory amounts0 = new uint256[](1);
        amounts0[0] = 1e18;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e18;
        int24[] memory ticks = new int24[](1);
        ticks[0] = 20;

        _donateMultiple(key, amounts0, amounts1, ticks);

        // Full redeem the LP.
        vm.prank(lpInfo.lpAddress);
        _modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo.tickLower, lpInfo.tickUpper, -lpInfo.liquidity), bytes("")
        );

        // Ensure the LP received the donation.
        assertApproxEqAbs(key.currency0.balanceOf(lpInfo.lpAddress), lpInfo.amount0 + 1e18, 1);
        assertApproxEqAbs(key.currency1.balanceOf(lpInfo.lpAddress), lpInfo.amount1 + 1e18, 1);
    }

    function testDonateMultiple_Below() external {
        // Create pool.
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, hooks: IHooks(address(0)), tickSpacing: 10});
        _manager.initialize(key, SQRT_RATIO_1_1, bytes(""));

        // Create 1 LP position covering active tick.
        LpInfo memory lpInfo = _createLpPosition(key, -50, 50, 1e18);

        // Donate 1e18 amount0 & amount1 to in range LPs.
        uint256[] memory amounts0 = new uint256[](1);
        amounts0[0] = 1e18;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e18;
        int24[] memory ticks = new int24[](1);
        ticks[0] = -20;

        _donateMultiple(key, amounts0, amounts1, ticks);

        // Full redeem the LP.
        vm.prank(lpInfo.lpAddress);
        _modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo.tickLower, lpInfo.tickUpper, -lpInfo.liquidity), bytes("")
        );

        // Ensure the LP received the donation.
        assertApproxEqAbs(key.currency0.balanceOf(lpInfo.lpAddress), lpInfo.amount0 + 1e18, 1);
        assertApproxEqAbs(key.currency1.balanceOf(lpInfo.lpAddress), lpInfo.amount1 + 1e18, 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    FUZZ CASES
    //////////////////////////////////////////////////////////////////////////*/

    struct PositionCase {
        uint128 liquidity;
        int256 tick0;
        int256 tick1;
    }

    struct DonateCase {
        uint256 amount0;
        uint256 amount1;
        int256 tick;
    }

    function _multipleCase(PositionCase[] memory positions, DonateCase[] memory donations) private returns (BalanceDelta[] memory rDeltas) {
        // Bail if there are no donations.
        if (donations.length == 0 || donations.length > 2 || positions.length > 2) {
            return rDeltas;
        }

        // Setup target pool.
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, hooks: IHooks(address(0)), tickSpacing: 10});
        _manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Bound positions to valid tick range & avoid liquidity overflow.
        for (uint256 i = 0; i < positions.length; ++i) {
            positions[i].liquidity = uint128(bound(positions[i].liquidity, 1, 2 ** 100));
            positions[i].tick0 = bound(
                positions[i].tick0,
                int256(TickMath.MIN_TICK + key.tickSpacing),
                int256(TickMath.MAX_TICK - key.tickSpacing)
            );
            positions[i].tick1 = bound(
                positions[i].tick1,
                int256(TickMath.MIN_TICK + key.tickSpacing),
                int256(TickMath.MAX_TICK - key.tickSpacing)
            );
        }

        // Add some full range liquidity to avoid no liquidity at tick errors.
        int24 minTick = _ceilToTickSpacing(key, TickMath.MIN_TICK);
        int24 maxTick = _floorToTickSpacing(key, TickMath.MAX_TICK);
        _createLpPosition(key, minTick, maxTick, 1e18);

        // Bound donations to valid tick range.
        for (uint256 i = 0; i < donations.length; ++i) {
            donations[i].tick = bound(donations[i].tick, int256(minTick), int256(maxTick - 1));
        }

        // Create positions.
        LpInfo[] memory lpInfo = new LpInfo[](positions.length);
        for (uint256 i = 0; i < positions.length; ++i) {
            int24 tickLower = _min(int24(positions[i].tick0), int24(positions[i].tick1));
            int24 tickUpper = _max(int24(positions[i].tick0), int24(positions[i].tick1));

            // Bail if ticks are identical.
            if (tickLower == tickUpper) {
                return rDeltas;
            }

            lpInfo[i] = _createLpPosition(
                key,
                _floorToTickSpacing(key, tickLower),
                _ceilToTickSpacing(key, tickUpper),
                int256(uint256(positions[i].liquidity))
            );
        }

        // Convert donations cases to donation arguments.
        uint256[] memory amounts0 = new uint256[](donations.length);
        uint256[] memory amounts1 = new uint256[](donations.length);
        int256[] memory ticks = new int256[](donations.length);
        for (uint256 i = 0; i < donations.length; ++i) {
            uint256 amount0 = bound(donations[i].amount0, 0, 2 ** 127 / donations.length);
            uint256 amount1 = bound(donations[i].amount1, 0, 2 ** 127 / donations.length);

            amounts0[i] = amount0;
            amounts1[i] = amount1;
            ticks[i] = donations[i].tick;
        }

        // TODO: This dislocates the fuzzers arguments and effects, does this degrade the quality?
        LibSort.sort(ticks);
        int24[] memory ticksCast;
        assembly {
            ticksCast := ticks
        }

        // Bail if any ticks are duplicated.
        for (uint256 i = 1; i < ticks.length; ++i) {
            if (ticks[i] == ticks[i - 1]) {
                return rDeltas;
            }
        }

        // Donate.
        _donateMultiple(key, amounts0, amounts1, ticksCast);

        // Close all positions.
        rDeltas = new BalanceDelta[](positions.length * 2);
        for (uint256 i = 0; i < lpInfo.length; i++) {
            vm.startPrank(lpInfo[i].lpAddress);
            rDeltas[i] = _modifyPositionRouter.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams(lpInfo[i].tickLower, lpInfo[i].tickUpper, 0),
                bytes("")
            );
            rDeltas[i] = _modifyPositionRouter.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams(lpInfo[i].tickLower, lpInfo[i].tickUpper, -lpInfo[i].liquidity),
                bytes("")
            );
        }
    }

    function _legacyCase(PositionCase[] memory positions, DonateCase[] memory donations) private returns (BalanceDelta[] memory rDeltas) {
        // Bail if there are no donations.
        if (donations.length == 0 || donations.length > 2 || positions.length > 2) {
            return rDeltas;
        }

        // Setup target pool.
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, hooks: IHooks(address(0)), tickSpacing: 10});
        PoolKeyLegacy memory keyLegacy =
            PoolKeyLegacy({currency0: currency0Legacy, currency1: currency1Legacy, fee: 0, hooks: IHooksLegacy(address(0)), tickSpacing: 10});
        _managerLegacy.initialize(keyLegacy, SQRT_RATIO_1_1, ZERO_BYTES);

        // Bound positions to valid tick range & avoid liquidity overflow.
        for (uint256 i = 0; i < positions.length; ++i) {
            positions[i].liquidity = uint128(bound(positions[i].liquidity, 1, 2 ** 100));
            positions[i].tick0 = bound(
                positions[i].tick0,
                int256(TickMath.MIN_TICK + key.tickSpacing),
                int256(TickMath.MAX_TICK - key.tickSpacing)
            );
            positions[i].tick1 = bound(
                positions[i].tick1,
                int256(TickMath.MIN_TICK + key.tickSpacing),
                int256(TickMath.MAX_TICK - key.tickSpacing)
            );
        }

        // Add some full range liquidity to avoid no liquidity at tick errors.
        int24 minTick = _ceilToTickSpacing(key, TickMath.MIN_TICK);
        int24 maxTick = _floorToTickSpacing(key, TickMath.MAX_TICK);
        _createLpPositionLegacy(keyLegacy, minTick, maxTick, 1e18);

        // Bound donations to valid tick range.
        for (uint256 i = 0; i < donations.length; ++i) {
            donations[i].tick = bound(donations[i].tick, int256(minTick), int256(maxTick - 1));
        }

        // Create positions.
        LpInfo[] memory lpInfo = new LpInfo[](positions.length);
        for (uint256 i = 0; i < positions.length; ++i) {
            int24 tickLower = _min(int24(positions[i].tick0), int24(positions[i].tick1));
            int24 tickUpper = _max(int24(positions[i].tick0), int24(positions[i].tick1));

            // Bail if ticks are identical.
            if (tickLower == tickUpper) {
                return rDeltas;
            }

            lpInfo[i] = _createLpPositionLegacy(
                keyLegacy,
                _floorToTickSpacing(key, tickLower),
                _ceilToTickSpacing(key, tickUpper),
                int256(uint256(positions[i].liquidity))
            );
        }

        // Convert donations cases to donation arguments.
        uint256[] memory amounts0 = new uint256[](donations.length);
        uint256[] memory amounts1 = new uint256[](donations.length);
        int256[] memory ticks = new int256[](donations.length);
        for (uint256 i = 0; i < donations.length; ++i) {
            uint256 amount0 = bound(donations[i].amount0, 0, 2 ** 127 / donations.length);
            uint256 amount1 = bound(donations[i].amount1, 0, 2 ** 127 / donations.length);

            amounts0[i] = amount0;
            amounts1[i] = amount1;
            ticks[i] = donations[i].tick;
        }

        // TODO: This dislocates the fuzzers arguments and effects, does this degrade the quality?
        LibSort.sort(ticks);
        int24[] memory ticksCast;
        assembly {
            ticksCast := ticks
        }

        // Bail if any ticks are duplicated.
        for (uint256 i = 1; i < ticks.length; ++i) {
            if (ticks[i] == ticks[i - 1]) {
                return rDeltas;
            }
        }

        // Donate.
        _donateLegacy(keyLegacy, amounts0, amounts1, ticksCast);

        // Close all positions.
        rDeltas = new BalanceDelta[](positions.length * 2);
        for (uint256 i = 0; i < lpInfo.length; i++) {
            vm.startPrank(lpInfo[i].lpAddress);
            rDeltas[i] = BalanceDelta.wrap(BalanceDeltaLegacy.unwrap(_modifyPositionRouterLegacy.modifyPosition(
                keyLegacy,
                IPoolManagerLegacy.ModifyPositionParams(lpInfo[i].tickLower, lpInfo[i].tickUpper, 0),
                bytes("")
            )));
            rDeltas[i] = BalanceDelta.wrap(BalanceDeltaLegacy.unwrap(_modifyPositionRouterLegacy.modifyPosition(
                keyLegacy,
                IPoolManagerLegacy.ModifyPositionParams(lpInfo[i].tickLower, lpInfo[i].tickUpper, -lpInfo[i].liquidity),
                bytes("")
            )));
            vm.stopPrank();
        }
    }

    function testDonateMultiple_DifferentialFuzz(PositionCase[] memory positions, DonateCase[] memory donations) external {
        BalanceDelta[] memory lMultipleDeltas = _multipleCase(positions, donations);
        BalanceDelta[] memory lLegacyDeltas = _legacyCase(positions, donations);

        for (uint256 i = 0; i < lMultipleDeltas.length; ++i) {
            assertEq(lMultipleDeltas[i].amount0(), lLegacyDeltas[i].amount0());
            assertEq(lMultipleDeltas[i].amount1(), lLegacyDeltas[i].amount1());
        }

        assertEq(lMultipleDeltas.length, lLegacyDeltas.length);
    }

    function testDonateMultiple_Regression1() external {
        PositionCase[] memory positions = new PositionCase[](1);
        positions[0] = PositionCase({ liquidity: 48516254459877948749359, tick0: 291600019818459968737486486394041, tick1: 3548426078575713209398795605304951 });
        DonateCase[] memory donations = new DonateCase[](1);
        donations[0] = DonateCase({ amount0: 0, amount1: 0, tick: 2894861283519779277602677860900753464469604781525143072055282998725456 });

        _multipleCase(positions, donations);
        _legacyCase(positions, donations);
    }

    function testDonateMultiple_Regression2() external {
        PositionCase[] memory positions = new PositionCase[](0);
        DonateCase[] memory donations = new DonateCase[](1);
        donations[0] = DonateCase({ amount0: 0, amount1: 0, tick: 57896044618658097711785492504343953926634992332820282019728792003956564819966 });

        _multipleCase(positions, donations);
        _legacyCase(positions, donations);
    }

    function testDonateMultiple_Regression3() external {
        PositionCase[] memory positions = new PositionCase[](0);
        DonateCase[] memory donations = new DonateCase[](1);
        donations[0] = DonateCase({ amount0: 762778504, amount1: 75313, tick: 16093 });

        _multipleCase(positions, donations);
        _legacyCase(positions, donations);
    }

    function testDonateMultiple_Regression4() external {
        PositionCase[] memory positions = new PositionCase[](0);
        DonateCase[] memory donations = new DonateCase[](1);
        donations[0] = DonateCase({ amount0: 0, amount1: 0, tick: -57896044618658097711785492504343953926634992332820282019728792003956564819967 });

        _multipleCase(positions, donations);
        _legacyCase(positions, donations);
    }

    function testDonateMultiple_Regression5() external {
        PositionCase[] memory positions = new PositionCase[](0);
        DonateCase[] memory donations = new DonateCase[](1);
        donations[0] = DonateCase({ amount0: 115792089237316195423570985008687907853269984665640564039456584007913129639933, amount1: 0, tick: 0 });

        _multipleCase(positions, donations);
        _legacyCase(positions, donations);
    }

    function testDonateMultiple_Regression6() external {
        PositionCase[] memory positions = new PositionCase[](0);
        DonateCase[] memory donations = new DonateCase[](1);
        donations[0] = DonateCase({ amount0: 115792089237316195423570985008687907853269984665640564039456584007913129639934, amount1: 0, tick: 0 });

        _multipleCase(positions, donations);
        _legacyCase(positions, donations);
    }

    function testDonateMultiple_Regression7() external {
        PositionCase[] memory positions = new PositionCase[](0);
        DonateCase[] memory donations = new DonateCase[](1);
        donations[0] = DonateCase({ amount0: 0, amount1: 0, tick: 57896044618658097711785492504343953926634992332820282019728792003956564819967 });

        _multipleCase(positions, donations);
        _legacyCase(positions, donations);
    }

    function testDonateMultiple_Regression8() external {
        PositionCase[] memory positions = new PositionCase[](1);
        positions[0] = PositionCase({ liquidity: 207259442830515072725502345, tick0: -548701, tick1: 30345597041507935154397553308088449638329177618069673770598342441450371990941 });
        DonateCase[] memory donations = new DonateCase[](1);
        donations[0] = DonateCase({ amount0: 0, amount1: 0, tick: 82807197556170 });

        _multipleCase(positions, donations);
        _legacyCase(positions, donations);
    }
}
