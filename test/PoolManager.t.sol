// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "../src/interfaces/IHooks.sol";
import {Hooks} from "../src/libraries/Hooks.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {IFees} from "../src/interfaces/IFees.sol";
import {IProtocolFeeController} from "../src/interfaces/IProtocolFeeController.sol";
import {PoolManager} from "../src/PoolManager.sol";
import {PoolDonateTest} from "../src/test/PoolDonateTest.sol";
import {ProtocolFeeControllerTest} from "../src/test/ProtocolFeeControllerTest.sol";
import {PoolTakeTest} from "../src/test/PoolTakeTest.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {Pool} from "../src/libraries/Pool.sol";
import {Deployers} from "./utils/Deployers.sol";
import {TokenFixture} from "./utils/TokenFixture.sol";
import {PoolModifyPositionTest} from "../src/test/PoolModifyPositionTest.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockHooks} from "../src/test/MockHooks.sol";
import {MockContract} from "../src/test/MockContract.sol";
import {EmptyTestHooks} from "../src/test/EmptyTestHooks.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {BalanceDelta} from "../src/types/BalanceDelta.sol";
import {PoolSwapTest} from "../src/test/PoolSwapTest.sol";
import {TestInvalidERC20} from "../src/test/TestInvalidERC20.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PoolLockTest} from "../src/test/PoolLockTest.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {FeeLibrary} from "../src/libraries/FeeLibrary.sol";
import {Position} from "../src/libraries/Position.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {FixedPoint96} from "../src/libraries/FixedPoint96.sol";
import {LibSort} from "solady/src/utils/LibSort.sol";

contract PoolManagerTest is Test, Deployers, TokenFixture, GasSnapshot {
    using Hooks for IHooks;
    using Pool for Pool.State;
    using PoolIdLibrary for PoolKey;
    using FeeLibrary for uint24;
    using CurrencyLibrary for Currency;

    event LockAcquired();
    event ProtocolFeeControllerUpdated(address protocolFeeController);
    event Initialize(
        PoolId indexed poolId,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks
    );
    event ModifyPosition(
        PoolId indexed poolId, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta
    );
    event Swap(
        PoolId indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );
    event Mint(address indexed to, Currency indexed currency, uint256 amount);
    event Burn(address indexed from, Currency indexed currency, uint256 amount);
    event ProtocolFeeUpdated(PoolId indexed id, uint24 protocolFees);

    Pool.State state;
    PoolManager manager;
    PoolDonateTest donateRouter;
    PoolTakeTest takeRouter;
    ProtocolFeeControllerTest feeController;
    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;
    PoolLockTest lockTest;
    ProtocolFeeControllerTest protocolFeeController;

    address ADDRESS_ZERO = address(0);
    address EMPTY_HOOKS = address(0xf000000000000000000000000000000000000000);
    address ALL_HOOKS = address(0xff00000000000000000000000000000000000001);
    address MOCK_HOOKS = address(0xfF00000000000000000000000000000000000000);

    uint256 TEST_BALANCE = type(uint256).max / 3 * 2;

    function setUp() public {
        initializeTokens();
        manager = Deployers.createFreshManager();
        donateRouter = new PoolDonateTest(manager);
        takeRouter = new PoolTakeTest(manager);
        modifyPositionRouter = new PoolModifyPositionTest(manager);
        feeController = new ProtocolFeeControllerTest();

        lockTest = new PoolLockTest(manager);
        swapRouter = new PoolSwapTest(manager);
        protocolFeeController = new ProtocolFeeControllerTest();

        MockERC20(Currency.unwrap(currency0)).mint(address(this), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), TEST_BALANCE);

        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), TEST_BALANCE);

        MockERC20(Currency.unwrap(currency0)).approve(address(modifyPositionRouter), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyPositionRouter), TEST_BALANCE);

        MockERC20(Currency.unwrap(currency0)).approve(address(donateRouter), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency1)).approve(address(donateRouter), TEST_BALANCE);

        MockERC20(Currency.unwrap(currency0)).approve(address(takeRouter), TEST_BALANCE);
        MockERC20(Currency.unwrap(currency1)).approve(address(takeRouter), TEST_BALANCE);
    }

    function test_bytecodeSize() public {
        snapSize("poolManager bytecode size", address(manager));
    }

    function test_initialize(PoolKey memory key, uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        // tested in Hooks.t.sol
        key.hooks = IHooks(address(0));

        if (key.fee & FeeLibrary.STATIC_FEE_MASK >= 1000000) {
            vm.expectRevert(abi.encodeWithSelector(IFees.FeeTooLarge.selector));
            manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        } else if (key.tickSpacing > manager.MAX_TICK_SPACING()) {
            vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooLarge.selector));
            manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        } else if (key.tickSpacing < manager.MIN_TICK_SPACING()) {
            vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooSmall.selector));
            manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        } else if (key.currency0 > key.currency1) {
            vm.expectRevert(abi.encodeWithSelector(IPoolManager.CurrenciesInitializedOutOfOrder.selector));
            manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        } else if (!key.hooks.isValidHookAddress(key.fee)) {
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, address(key.hooks)));
            manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        } else {
            vm.expectEmit(true, true, true, true);
            emit Initialize(key.toId(), key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
            manager.initialize(key, sqrtPriceX96, ZERO_BYTES);

            (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
            assertEq(slot0.sqrtPriceX96, sqrtPriceX96);
            assertEq(slot0.protocolFees, 0);
        }
    }

    function test_initialize_forNativeTokens(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: 60
        });

        vm.expectEmit(true, true, true, true);
        emit Initialize(key.toId(), key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);

        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.sqrtPriceX96, sqrtPriceX96);
        assertEq(slot0.protocolFees >> 12, 0);
        assertEq(slot0.tick, TickMath.getTickAtSqrtRatio(sqrtPriceX96));
    }

    function test_initialize_succeedsWithHooks(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        address payable mockAddr = payable(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG)));
        address payable hookAddr = payable(MOCK_HOOKS);

        vm.etch(hookAddr, vm.getDeployedCode("EmptyTestHooks.sol:EmptyTestHooks"));
        MockContract mockContract = new MockContract();
        vm.etch(mockAddr, address(mockContract).code);

        MockContract(mockAddr).setImplementation(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(mockAddr), tickSpacing: 60});

        int24 tick = manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.sqrtPriceX96, sqrtPriceX96);

        bytes32 beforeSelector = MockHooks.beforeInitialize.selector;
        bytes memory beforeParams = abi.encode(address(this), key, sqrtPriceX96, ZERO_BYTES);

        bytes32 afterSelector = MockHooks.afterInitialize.selector;
        bytes memory afterParams = abi.encode(address(this), key, sqrtPriceX96, tick, ZERO_BYTES);

        assertEq(MockContract(mockAddr).timesCalledSelector(beforeSelector), 1);
        assertTrue(MockContract(mockAddr).calledWithSelector(beforeSelector, beforeParams));
        assertEq(MockContract(mockAddr).timesCalledSelector(afterSelector), 1);
        assertTrue(MockContract(mockAddr).calledWithSelector(afterSelector, afterParams));
    }

    function test_initialize_succeedsWithMaxTickSpacing(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: manager.MAX_TICK_SPACING()
        });

        vm.expectEmit(true, true, true, true);
        emit Initialize(key.toId(), key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);

        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
    }

    function test_initialize_succeedsWithEmptyHooks(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        address hookEmptyAddr = EMPTY_HOOKS;

        MockHooks impl = new MockHooks();
        vm.etch(hookEmptyAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookEmptyAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: mockHooks, tickSpacing: 60});

        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.sqrtPriceX96, sqrtPriceX96);
    }

    function test_initialize_revertsWithIdenticalTokens(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        // Both currencies are currency0
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency0, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        vm.expectRevert(IPoolManager.CurrenciesInitializedOutOfOrder.selector);
        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
    }

    function test_initialize_revertsWithSameTokenCombo(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        PoolKey memory keyInvertedCurrency =
            PoolKey({currency0: currency1, currency1: currency0, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        vm.expectRevert(IPoolManager.CurrenciesInitializedOutOfOrder.selector);
        manager.initialize(keyInvertedCurrency, sqrtPriceX96, ZERO_BYTES);
    }

    function test_initialize_revertsWhenPoolAlreadyInitialized(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
    }

    function test_initialize_failsWithIncorrectSelectors() public {
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG));

        MockHooks impl = new MockHooks();
        vm.etch(hookAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: mockHooks, tickSpacing: 10});

        mockHooks.setReturnValue(mockHooks.beforeInitialize.selector, bytes4(0xdeadbeef));
        mockHooks.setReturnValue(mockHooks.afterInitialize.selector, bytes4(0xdeadbeef));

        // Fails at beforeInitialize hook.
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Fail at afterInitialize hook.
        mockHooks.setReturnValue(mockHooks.beforeInitialize.selector, mockHooks.beforeInitialize.selector);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
    }

    function test_initialize_succeedsWithCorrectSelectors() public {
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG));

        MockHooks impl = new MockHooks();
        vm.etch(hookAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: mockHooks, tickSpacing: 10});

        mockHooks.setReturnValue(mockHooks.beforeInitialize.selector, mockHooks.beforeInitialize.selector);
        mockHooks.setReturnValue(mockHooks.afterInitialize.selector, mockHooks.afterInitialize.selector);

        vm.expectEmit(true, true, true, true);
        emit Initialize(key.toId(), key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
    }

    function test_initialize_failsIfTickSpaceTooLarge(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: manager.MAX_TICK_SPACING() + 1
        });

        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooLarge.selector));
        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
    }

    function test_initialize_failsIfTickSpaceZero(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 0});

        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooSmall.selector));
        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
    }

    function test_initialize_failsIfTickSpaceNeg(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: -1});

        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooSmall.selector));
        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
    }

    function test_initialize_gas() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        snapStart("initialize");
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        snapEnd();
    }

    function test_feeControllerSet() public {
        assertEq(address(manager.protocolFeeController()), address(0));
        vm.expectEmit(false, false, false, true, address(manager));
        emit ProtocolFeeControllerUpdated(address(protocolFeeController));
        manager.setProtocolFeeController(protocolFeeController);
        assertEq(address(manager.protocolFeeController()), address(protocolFeeController));
    }

    function test_fetchFeeWhenController(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        manager.setProtocolFeeController(protocolFeeController);

        uint16 poolProtocolFee = 4;
        protocolFeeController.setSwapFeeForPool(key.toId(), poolProtocolFee);

        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);

        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.sqrtPriceX96, sqrtPriceX96);
        assertEq(slot0.protocolFees >> 12, poolProtocolFee);
    }

    function test_mint_failsIfNotInitialized() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});
        vm.expectRevert();
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100}), ZERO_BYTES
        );
    }

    function test_mint_succeedsIfInitialized(uint160 sqrtPriceX96) public {
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);

        vm.expectEmit(true, true, true, true);
        emit ModifyPosition(key.toId(), address(modifyPositionRouter), 0, 60, 100);

        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100}), ZERO_BYTES
        );
    }

    function test_mint_succeedsForNativeTokensIfInitialized(uint160 sqrtPriceX96) public {
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: 60
        });

        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        vm.expectEmit(true, true, true, true);
        emit ModifyPosition(key.toId(), address(modifyPositionRouter), 0, 60, 100);

        modifyPositionRouter.modifyPosition{value: 100}(
            key, IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100}), ZERO_BYTES
        );
    }

    function test_mint_succeedsWithHooksIfInitialized(uint160 sqrtPriceX96) public {
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        address payable mockAddr =
            payable(address(uint160(Hooks.BEFORE_MODIFY_POSITION_FLAG | Hooks.AFTER_MODIFY_POSITION_FLAG)));
        address payable hookAddr = payable(MOCK_HOOKS);

        vm.etch(hookAddr, vm.getDeployedCode("EmptyTestHooks.sol:EmptyTestHooks"));
        MockContract mockContract = new MockContract();
        vm.etch(mockAddr, address(mockContract).code);

        MockContract(mockAddr).setImplementation(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(mockAddr), tickSpacing: 60});

        IPoolManager.ModifyPositionParams memory params =
            IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100});

        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);

        BalanceDelta balanceDelta = modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);

        bytes32 beforeSelector = MockHooks.beforeModifyPosition.selector;
        bytes memory beforeParams = abi.encode(address(modifyPositionRouter), key, params, ZERO_BYTES);
        bytes32 afterSelector = MockHooks.afterModifyPosition.selector;
        bytes memory afterParams = abi.encode(address(modifyPositionRouter), key, params, balanceDelta, ZERO_BYTES);

        assertEq(MockContract(mockAddr).timesCalledSelector(beforeSelector), 1);
        assertTrue(MockContract(mockAddr).calledWithSelector(beforeSelector, beforeParams));
        assertEq(MockContract(mockAddr).timesCalledSelector(afterSelector), 1);
        assertTrue(MockContract(mockAddr).calledWithSelector(afterSelector, afterParams));
    }

    function test_mint_failsWithIncorrectSelectors() public {
        address hookAddr = address(uint160(Hooks.BEFORE_MODIFY_POSITION_FLAG | Hooks.AFTER_MODIFY_POSITION_FLAG));

        MockHooks impl = new MockHooks();
        vm.etch(hookAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: mockHooks, tickSpacing: 10});

        IPoolManager.ModifyPositionParams memory params =
            IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        mockHooks.setReturnValue(mockHooks.beforeModifyPosition.selector, bytes4(0xdeadbeef));
        mockHooks.setReturnValue(mockHooks.afterModifyPosition.selector, bytes4(0xdeadbeef));

        // Fails at beforeModifyPosition hook.
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);

        // Fail at afterModifyPosition hook.
        mockHooks.setReturnValue(mockHooks.beforeModifyPosition.selector, mockHooks.beforeModifyPosition.selector);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);
    }

    function test_mint_succeedsWithCorrectSelectors() public {
        address hookAddr = address(uint160(Hooks.BEFORE_MODIFY_POSITION_FLAG | Hooks.AFTER_MODIFY_POSITION_FLAG));

        MockHooks impl = new MockHooks();
        vm.etch(hookAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: mockHooks, tickSpacing: 10});

        IPoolManager.ModifyPositionParams memory params =
            IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        mockHooks.setReturnValue(mockHooks.beforeModifyPosition.selector, mockHooks.beforeModifyPosition.selector);
        mockHooks.setReturnValue(mockHooks.afterModifyPosition.selector, mockHooks.afterModifyPosition.selector);

        vm.expectEmit(true, true, true, true);
        emit ModifyPosition(key.toId(), address(modifyPositionRouter), 0, 60, 100);

        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);
    }

    function test_mint_gas() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        snapStart("mint");
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100}), ZERO_BYTES
        );
        snapEnd();
    }

    function test_mint_withNative_gas() public {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: 60
        });

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        snapStart("mint with native token");
        modifyPositionRouter.modifyPosition{value: 100}(
            key, IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100}), ZERO_BYTES
        );
        snapEnd();
    }

    function test_mint_withHooks_gas() public {
        address hookEmptyAddr = EMPTY_HOOKS;
        MockHooks impl = new MockHooks();
        vm.etch(hookEmptyAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookEmptyAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: mockHooks, tickSpacing: 60});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        snapStart("mint with empty hook");
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100}), ZERO_BYTES
        );
        snapEnd();
    }

    function test_swap_failsIfNotInitialized(uint160 sqrtPriceX96) public {
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: sqrtPriceX96});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        vm.expectRevert();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
    }

    function test_swap_succeedsIfInitialized() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        IPoolManager.ModifyPositionParams memory liqParams =
            IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18});

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: false, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition(key, liqParams, ZERO_BYTES);

        vm.expectEmit(true, true, true, true);
        emit Swap(
            key.toId(), address(swapRouter), int128(100), int128(-98), 79228162514264329749955861424, 1e18, -1, 3000
        );

        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);
    }

    function test_swap_succeedsWithNativeTokensIfInitialized() public {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: 60
        });

        IPoolManager.ModifyPositionParams memory liqParams =
            IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18});

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: false, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition{value: 1 ether}(key, liqParams, ZERO_BYTES);

        vm.expectEmit(true, true, true, true);
        emit Swap(
            key.toId(), address(swapRouter), int128(100), int128(-98), 79228162514264329749955861424, 1e18, -1, 3000
        );

        swapRouter.swap{value: 100}(key, swapParams, testSettings, ZERO_BYTES);
    }

    function test_swap_succeedsWithHooksIfInitialized() public {
        address payable mockAddr = payable(address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)));
        address payable hookAddr = payable(MOCK_HOOKS);

        vm.etch(hookAddr, vm.getDeployedCode("EmptyTestHooks.sol:EmptyTestHooks"));
        MockContract mockContract = new MockContract();
        vm.etch(mockAddr, address(mockContract).code);

        MockContract(mockAddr).setImplementation(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(mockAddr), tickSpacing: 60});

        IPoolManager.ModifyPositionParams memory liqParams =
            IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18});

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: false, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition(key, liqParams, ZERO_BYTES);

        BalanceDelta balanceDelta = swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);

        bytes32 beforeSelector = MockHooks.beforeSwap.selector;
        bytes memory beforeParams = abi.encode(address(swapRouter), key, swapParams, ZERO_BYTES);

        bytes32 afterSelector = MockHooks.afterSwap.selector;
        bytes memory afterParams = abi.encode(address(swapRouter), key, swapParams, balanceDelta, ZERO_BYTES);

        assertEq(MockContract(mockAddr).timesCalledSelector(beforeSelector), 1);
        assertTrue(MockContract(mockAddr).calledWithSelector(beforeSelector, beforeParams));
        assertEq(MockContract(mockAddr).timesCalledSelector(afterSelector), 1);
        assertTrue(MockContract(mockAddr).calledWithSelector(afterSelector, afterParams));
    }

    function test_swap_failsWithIncorrectSelectors() public {
        address hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));

        MockHooks impl = new MockHooks();
        vm.etch(hookAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: mockHooks, tickSpacing: 10});

        IPoolManager.ModifyPositionParams memory params =
            IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100});

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: false, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);

        mockHooks.setReturnValue(mockHooks.beforeSwap.selector, bytes4(0xdeadbeef));
        mockHooks.setReturnValue(mockHooks.afterSwap.selector, bytes4(0xdeadbeef));

        // Fails at beforeModifyPosition hook.
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);

        // Fail at afterModifyPosition hook.
        mockHooks.setReturnValue(mockHooks.beforeSwap.selector, mockHooks.beforeSwap.selector);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);
    }

    function test_swap_succeedsWithCorrectSelectors() public {
        address hookAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));

        MockHooks impl = new MockHooks();
        vm.etch(hookAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: mockHooks, tickSpacing: 10});

        IPoolManager.ModifyPositionParams memory liqParams =
            IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18});

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: false, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition(key, liqParams, ZERO_BYTES);

        mockHooks.setReturnValue(mockHooks.beforeSwap.selector, mockHooks.beforeSwap.selector);
        mockHooks.setReturnValue(mockHooks.afterSwap.selector, mockHooks.afterSwap.selector);

        vm.expectEmit(true, true, true, true);
        emit Swap(key.toId(), address(swapRouter), 10, -8, 79228162514264336880490487708, 1e18, -1, 100);

        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);
    }

    function test_swap_gas() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        IPoolManager.ModifyPositionParams memory liqParams =
            IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18});

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition(key, liqParams, ZERO_BYTES);

        snapStart("simple swap");
        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);
        snapEnd();
    }

    function test_swap_withNative_gas() public {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: 60
        });

        IPoolManager.ModifyPositionParams memory liqParams =
            IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18});

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition{value: 1 ether}(key, liqParams, ZERO_BYTES);

        snapStart("simple swap");
        swapRouter.swap{value: 100}(key, swapParams, testSettings, ZERO_BYTES);
        snapEnd();
    }

    function test_swap_withHooks_gas() public {
        address hookEmptyAddr = EMPTY_HOOKS;

        MockHooks impl = new MockHooks();
        vm.etch(hookEmptyAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookEmptyAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: mockHooks, tickSpacing: 60});

        IPoolManager.ModifyPositionParams memory liqParams =
            IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18});

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition(key, liqParams, ZERO_BYTES);
        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);

        swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_4});
        testSettings = PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        snapStart("swap with hooks");
        swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);
        snapEnd();
    }

    function test_swap_GasMintClaimIfOutputNotTaken() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: false, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18}), ZERO_BYTES
        );

        vm.expectEmit(true, true, true, false);
        emit Mint(address(swapRouter), currency1, 98);
        snapStart("swap mint output as claim");
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        snapEnd();

        uint256 claimsBalance = manager.balanceOf(address(swapRouter), currency1);
        assertEq(claimsBalance, 98);
    }

    function test_swap_GasUseClaimAsInput() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: false, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18}), ZERO_BYTES
        );
        vm.expectEmit(true, true, true, false);
        emit Mint(address(swapRouter), currency1, 98);
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 claimsBalance = manager.balanceOf(address(swapRouter), currency1);
        assertEq(claimsBalance, 98);

        // swap from currency1 to currency0 again, using Claims as input tokens
        params = IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -25, sqrtPriceLimitX96: SQRT_RATIO_4_1});

        testSettings = PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: false});

        vm.expectEmit(true, true, true, false);
        emit Burn(address(swapRouter), currency1, 27);
        snapStart("swap burn claim for input");
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        snapEnd();

        claimsBalance = manager.balanceOf(address(swapRouter), currency1);
        assertEq(claimsBalance, 71);
    }

    function test_swap_againstLiq_gas() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18}), ZERO_BYTES
        );

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        params = IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_4});

        snapStart("swap against liquidity");
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        snapEnd();
    }

    function test_swap_againstLiqWithNative_gas() public {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: 60
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        modifyPositionRouter.modifyPosition{value: 1 ether}(
            key,
            IPoolManager.ModifyPositionParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether}),
            ZERO_BYTES
        );

        swapRouter.swap{value: 1 ether}(key, params, testSettings, ZERO_BYTES);

        params = IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_4});

        snapStart("swap against liquidity with native token");
        swapRouter.swap{value: 1 ether}(key, params, testSettings, ZERO_BYTES);
        snapEnd();
    }

    function test_donate_failsIfNotInitialized() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        vm.expectRevert(abi.encodeWithSelector(Pool.NoLiquidityToReceiveFees.selector));
        donateRouter.donate(key, 100, 100, ZERO_BYTES);
    }

    function test_donate_failsIfNoLiquidity(uint160 sqrtPriceX96) public {
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_RATIO);
        vm.assume(sqrtPriceX96 < TickMath.MAX_SQRT_RATIO);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, sqrtPriceX96, ZERO_BYTES);
        vm.expectRevert(abi.encodeWithSelector(Pool.NoLiquidityToReceiveFees.selector));
        donateRouter.donate(key, 100, 100, ZERO_BYTES);
    }

    // test successful donation if pool has liquidity
    function test_donate_succeedsWhenPoolHasLiquidity() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-60, 60, 100);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);
        snapStart("donate gas with 2 tokens");
        donateRouter.donate(key, 100, 200, ZERO_BYTES);
        snapEnd();

        (, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128,) = manager.pools(key.toId());
        assertEq(feeGrowthGlobal0X128, 340282366920938463463374607431768211456);
        assertEq(feeGrowthGlobal1X128, 680564733841876926926749214863536422912);
    }

    function test_donate_succeedsForNativeTokensWhenPoolHasLiquidity() public {
        vm.deal(address(this), 1 ether);

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            fee: 100,
            hooks: IHooks(address(0)),
            tickSpacing: 10
        });
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-60, 60, 100);
        modifyPositionRouter.modifyPosition{value: 1}(key, params, ZERO_BYTES);
        donateRouter.donate{value: 100}(key, 100, 200, ZERO_BYTES);

        (, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128,) = manager.pools(key.toId());
        assertEq(feeGrowthGlobal0X128, 340282366920938463463374607431768211456);
        assertEq(feeGrowthGlobal1X128, 680564733841876926926749214863536422912);
    }

    function test_donate_failsWithIncorrectSelectors() public {
        address hookAddr = address(uint160(Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG));

        MockHooks impl = new MockHooks();
        vm.etch(hookAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: mockHooks, tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-60, 60, 100);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);
        mockHooks.setReturnValue(mockHooks.beforeDonate.selector, bytes4(0xdeadbeef));
        mockHooks.setReturnValue(mockHooks.afterDonate.selector, bytes4(0xdeadbeef));

        // Fails at beforeDonate hook.
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        donateRouter.donate(key, 100, 200, ZERO_BYTES);

        // Fail at afterDonate hook.
        mockHooks.setReturnValue(mockHooks.beforeDonate.selector, mockHooks.beforeDonate.selector);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        donateRouter.donate(key, 100, 200, ZERO_BYTES);
    }

    function test_donate_succeedsWithCorrectSelectors() public {
        address hookAddr = address(uint160(Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG));

        MockHooks impl = new MockHooks();
        vm.etch(hookAddr, address(impl).code);
        MockHooks mockHooks = MockHooks(hookAddr);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: mockHooks, tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-60, 60, 100);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);

        mockHooks.setReturnValue(mockHooks.beforeDonate.selector, mockHooks.beforeDonate.selector);
        mockHooks.setReturnValue(mockHooks.afterDonate.selector, mockHooks.afterDonate.selector);

        donateRouter.donate(key, 100, 200, ZERO_BYTES);
    }

    function test_donate_OneToken_gas() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-60, 60, 100);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);

        snapStart("donate gas with 1 token");
        donateRouter.donate(key, 100, 0, ZERO_BYTES);
        snapEnd();
    }

    function testDonateTick_BelowActiveDirectBoundary() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create 2 LP positions, active tick and one tick above active.
        LpInfo memory lpInfo0 = _createLpPosition(key, -10, 0, 1e18);
        LpInfo memory lpInfo1 = _createLpPosition(key, -20, -10, 1e18);

        // Donate 2 eth of each asset to the position in range at tick 10 (tickLower = 10).
        uint256 lDonateAmount = 2 ether;
        uint256[] memory amounts0 = new uint[](1);
        amounts0[0] = lDonateAmount;
        uint256[] memory amounts1 = new uint[](1);
        amounts1[0] = lDonateAmount;
        int24[] memory ticks = new int24[](1);
        ticks[0] = lpInfo1.tickLower;

        // Donate & check that balances were pulled to the pool.
        uint256 lBefore0 = key.currency0.balanceOf(address(manager));
        uint256 lBefore1 = key.currency1.balanceOf(address(manager));
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), lBefore0 + lDonateAmount, "amount0 donation failed");
        assertEq(key.currency1.balanceOf(address(manager)), lBefore1 + lDonateAmount, "amount1 donation failed");

        // Close position that received the donate.
        vm.prank(lpInfo1.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo1.tickLower, lpInfo1.tickUpper, -lpInfo1.liquidity), ZERO_BYTES
        );

        // Ensure users received their intended donations.
        assertApproxEqAbs(
            key.currency0.balanceOf(lpInfo1.lpAddress), lpInfo1.amount0 + lDonateAmount, 1, "amount0 withdraw mismatch"
        );
        assertApproxEqAbs(
            key.currency1.balanceOf(lpInfo1.lpAddress), lpInfo1.amount1 + lDonateAmount, 1, "amount1 withdraw mismatch"
        );

        // Redeem the other position and ensure pool is empty (math precision leaves some wei).
        vm.prank(lpInfo0.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo0.tickLower, lpInfo0.tickUpper, -lpInfo0.liquidity), ZERO_BYTES
        );
        assertLt(key.currency0.balanceOf(address(manager)), 10, "Too much amount0 dust");
        assertLt(key.currency1.balanceOf(address(manager)), 10, "Too much amount1 dust");
        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity left over");
    }

    function testDonateTick_BelowActiveDirectMiddle() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create 2 LP positions, active tick and one tick above active.
        LpInfo memory lpInfo0 = _createLpPosition(key, -10, 0, 1e18);
        LpInfo memory lpInfo1 = _createLpPosition(key, -20, -10, 1e18);

        // Donate 2 eth of each asset to the position in range at tick 10 (tickLower = 10).
        uint256 lDonateAmount = 2 ether;
        uint256[] memory amounts0 = new uint[](1);
        amounts0[0] = lDonateAmount;
        uint256[] memory amounts1 = new uint[](1);
        amounts1[0] = lDonateAmount;
        int24[] memory ticks = new int24[](1);
        ticks[0] = -15;

        // Donate & check that balances were pulled to the pool.
        uint256 lBefore0 = key.currency0.balanceOf(address(manager));
        uint256 lBefore1 = key.currency1.balanceOf(address(manager));
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), lBefore0 + lDonateAmount, "amount0 donation failed");
        assertEq(key.currency1.balanceOf(address(manager)), lBefore1 + lDonateAmount, "amount1 donation failed");

        // Close position that received the donate.
        vm.prank(lpInfo1.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo1.tickLower, lpInfo1.tickUpper, -lpInfo1.liquidity), ZERO_BYTES
        );

        // Ensure users received their intended donations.
        assertApproxEqAbs(
            key.currency0.balanceOf(lpInfo1.lpAddress), lpInfo1.amount0 + lDonateAmount, 1, "amount0 withdraw mismatch"
        );
        assertApproxEqAbs(
            key.currency1.balanceOf(lpInfo1.lpAddress), lpInfo1.amount1 + lDonateAmount, 1, "amount1 withdraw mismatch"
        );

        // Redeem the other position and ensure pool is empty (math precision leaves some wei).
        vm.prank(lpInfo0.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo0.tickLower, lpInfo0.tickUpper, -lpInfo0.liquidity), ZERO_BYTES
        );
        assertLt(key.currency0.balanceOf(address(manager)), 10, "Too much amount0 dust");
        assertLt(key.currency1.balanceOf(address(manager)), 10, "Too much amount1 dust");
        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity left over");
    }

    function testDonateTick_BelowActiveSkipOneMiddle() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create 2 LP positions, active tick and one tick above active.
        LpInfo memory lpInfo0 = _createLpPosition(key, -10, 0, 1e18);
        LpInfo memory lpInfo1 = _createLpPosition(key, -20, -10, 1e18);
        LpInfo memory lpInfo2 = _createLpPosition(key, -30, -20, 1e18);

        // Donate 2 eth of each asset to the position in range at tick 10 (tickLower = 10).
        uint256 lDonateAmount = 2 ether;
        uint256[] memory amounts0 = new uint[](1);
        amounts0[0] = lDonateAmount;
        uint256[] memory amounts1 = new uint[](1);
        amounts1[0] = lDonateAmount;
        int24[] memory ticks = new int24[](1);
        ticks[0] = -25;

        uint256 lBefore0 = key.currency0.balanceOf(address(manager));
        uint256 lBefore1 = key.currency1.balanceOf(address(manager));

        // Donate & check that balances were pulled to the pool.
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), lBefore0 + lDonateAmount, "amount0 donation failed");
        assertEq(key.currency1.balanceOf(address(manager)), lBefore1 + lDonateAmount, "amount1 donation failed");

        // Close position that received the donate.
        vm.prank(lpInfo2.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo2.tickLower, lpInfo2.tickUpper, -lpInfo2.liquidity), ZERO_BYTES
        );

        // Ensure users received their intended donations.
        assertApproxEqAbs(
            key.currency0.balanceOf(lpInfo2.lpAddress), lpInfo2.amount0 + lDonateAmount, 1, "amount0 withdraw mismatch"
        );
        assertApproxEqAbs(
            key.currency1.balanceOf(lpInfo2.lpAddress), lpInfo2.amount1 + lDonateAmount, 1, "amount1 withdraw mismatch"
        );

        // Redeem the other position and ensure pool is empty (math precision leaves some wei).
        vm.prank(lpInfo0.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo0.tickLower, lpInfo0.tickUpper, -lpInfo0.liquidity), ZERO_BYTES
        );
        vm.prank(lpInfo1.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo1.tickLower, lpInfo1.tickUpper, -lpInfo1.liquidity), ZERO_BYTES
        );
        assertLt(key.currency0.balanceOf(address(manager)), 10, "Too much amount0 dust");
        assertLt(key.currency1.balanceOf(address(manager)), 10, "Too much amount1 dust");
        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity left over");
    }

    function testDonateTick_BelowActiveSkipOneBoundary() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create 2 LP positions, active tick and one tick above active.
        LpInfo memory lpInfo0 = _createLpPosition(key, -10, 0, 1e18);
        LpInfo memory lpInfo1 = _createLpPosition(key, -20, -10, 1e18);
        LpInfo memory lpInfo2 = _createLpPosition(key, -30, -20, 1e18);

        // Donate 2 eth of each asset to the position in range at tick 10 (tickLower = 10).
        uint256 lDonateAmount = 2 ether;
        uint256[] memory amounts0 = new uint[](1);
        amounts0[0] = lDonateAmount;
        uint256[] memory amounts1 = new uint[](1);
        amounts1[0] = lDonateAmount;
        int24[] memory ticks = new int24[](1);
        ticks[0] = lpInfo2.tickLower;

        uint256 lBefore0 = key.currency0.balanceOf(address(manager));
        uint256 lBefore1 = key.currency1.balanceOf(address(manager));

        // Donate & check that balances were pulled to the pool.
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), lBefore0 + lDonateAmount, "amount0 donation failed");
        assertEq(key.currency1.balanceOf(address(manager)), lBefore1 + lDonateAmount, "amount1 donation failed");

        // Close position that received the donate.
        vm.prank(lpInfo2.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo2.tickLower, lpInfo2.tickUpper, -lpInfo2.liquidity), ZERO_BYTES
        );

        // Ensure users received their intended donations.
        assertApproxEqAbs(
            key.currency0.balanceOf(lpInfo2.lpAddress), lpInfo2.amount0 + lDonateAmount, 1, "amount0 withdraw mismatch"
        );
        assertApproxEqAbs(
            key.currency1.balanceOf(lpInfo2.lpAddress), lpInfo2.amount1 + lDonateAmount, 1, "amount1 withdraw mismatch"
        );

        // Redeem the other position and ensure pool is empty (math precision leaves some wei).
        vm.prank(lpInfo0.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo0.tickLower, lpInfo0.tickUpper, -lpInfo0.liquidity), ZERO_BYTES
        );
        vm.prank(lpInfo1.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo1.tickLower, lpInfo1.tickUpper, -lpInfo1.liquidity), ZERO_BYTES
        );
        assertLt(key.currency0.balanceOf(address(manager)), 10, "Too much amount0 dust");
        assertLt(key.currency1.balanceOf(address(manager)), 10, "Too much amount1 dust");
        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity left over");
    }

    function testDonateTick_AboveActiveDirectBoundary() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create 2 LP positions, active tick and one tick above active.
        LpInfo memory lpInfo0 = _createLpPosition(key, 0, 10, 1e18);
        LpInfo memory lpInfo1 = _createLpPosition(key, 10, 20, 1e18);

        // Donate 2 eth of each asset to the position in range at tick 10 (tickLower = 10).
        uint256 lDonateAmount = 2 ether;
        uint256[] memory amounts0 = new uint[](1);
        amounts0[0] = lDonateAmount;
        uint256[] memory amounts1 = new uint[](1);
        amounts1[0] = lDonateAmount;
        int24[] memory ticks = new int24[](1);
        ticks[0] = lpInfo1.tickLower;

        // Donate & check that balances were pulled to the pool.
        uint256 lBefore0 = key.currency0.balanceOf(address(manager));
        uint256 lBefore1 = key.currency1.balanceOf(address(manager));
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), lBefore0 + lDonateAmount, "amount0 donation failed");
        assertEq(key.currency1.balanceOf(address(manager)), lBefore1 + lDonateAmount, "amount1 donation failed");

        // Check te target position received donate proceeds.
        vm.prank(lpInfo1.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo1.tickLower, lpInfo1.tickUpper, -lpInfo1.liquidity), ZERO_BYTES
        );
        assertApproxEqAbs(
            key.currency0.balanceOf(lpInfo1.lpAddress),
            lpInfo1.amount0 + lDonateAmount,
            1,
            "LP1: amount0 withdraw mismatch"
        );
        assertApproxEqAbs(
            key.currency1.balanceOf(lpInfo1.lpAddress),
            lpInfo1.amount1 + lDonateAmount,
            1,
            "LP1: amount1 withdraw mismatch"
        );

        // Check the other position did not receive any donate proceeds.
        vm.prank(lpInfo0.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo0.tickLower, lpInfo0.tickUpper, -lpInfo0.liquidity), ZERO_BYTES
        );
        assertApproxEqAbs(
            key.currency0.balanceOf(lpInfo0.lpAddress), lpInfo0.amount0, 1, "LP0: amount0 withdraw mismatch"
        );
        assertApproxEqAbs(
            key.currency1.balanceOf(lpInfo0.lpAddress), lpInfo0.amount1, 1, "LP0: amount1 withdraw mismatch"
        );

        // Make sure we emptied the pool.
        assertLt(key.currency0.balanceOf(address(manager)), 10, "Too much amount0 dust");
        assertLt(key.currency1.balanceOf(address(manager)), 10, "Too much amount1 dust");
        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity left over");
    }

    function testDonateTick_AboveActiveSkipOneBoundary() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create 2 LP positions, active tick and one tick above active.
        LpInfo memory lpInfo0 = _createLpPosition(key, 0, 10, 1e18);
        LpInfo memory lpInfo1 = _createLpPosition(key, 10, 20, 1e18);
        LpInfo memory lpInfo2 = _createLpPosition(key, 20, 30, 1e18);

        // Donate 2 eth of each asset to the position in range at tick 10 (tickLower = 10).
        uint256 lDonateAmount = 2 ether;
        uint256[] memory amounts0 = new uint[](1);
        amounts0[0] = lDonateAmount;
        uint256[] memory amounts1 = new uint[](1);
        amounts1[0] = lDonateAmount;
        int24[] memory ticks = new int24[](1);
        ticks[0] = lpInfo2.tickLower;

        uint256 lBefore0 = key.currency0.balanceOf(address(manager));
        uint256 lBefore1 = key.currency1.balanceOf(address(manager));

        // Donate & check that balances were pulled to the pool.
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), lBefore0 + lDonateAmount, "amount0 donation failed");
        assertEq(key.currency1.balanceOf(address(manager)), lBefore1 + lDonateAmount, "amount1 donation failed");

        // Close position that received the donate.
        vm.prank(lpInfo2.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo2.tickLower, lpInfo2.tickUpper, -lpInfo2.liquidity), ZERO_BYTES
        );

        // Ensure users received their intended donations.
        assertApproxEqAbs(
            key.currency0.balanceOf(lpInfo2.lpAddress), lpInfo2.amount0 + lDonateAmount, 1, "amount0 withdraw mismatch"
        );
        assertApproxEqAbs(
            key.currency1.balanceOf(lpInfo2.lpAddress), lpInfo2.amount1 + lDonateAmount, 1, "amount1 withdraw mismatch"
        );

        // Redeem the other position and ensure pool is empty (math precision leaves some wei).
        vm.prank(lpInfo0.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo0.tickLower, lpInfo0.tickUpper, -lpInfo0.liquidity), ZERO_BYTES
        );
        vm.prank(lpInfo1.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo1.tickLower, lpInfo1.tickUpper, -lpInfo1.liquidity), ZERO_BYTES
        );
        assertLt(key.currency0.balanceOf(address(manager)), 10, "Too much amount0 dust");
        assertLt(key.currency1.balanceOf(address(manager)), 10, "Too much amount1 dust");
        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity left over");
    }

    function testDonateTick_AboveActiveDirectMiddle() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create 2 LP positions, active tick and one tick above active.
        LpInfo memory lpInfo0 = _createLpPosition(key, 0, 10, 1e18);
        LpInfo memory lpInfo1 = _createLpPosition(key, 10, 20, 1e18);

        // Donate 2 eth of each asset to the position in range at tick 10 (tickLower = 10).
        uint256 lDonateAmount = 2 ether;
        uint256[] memory amounts0 = new uint[](1);
        amounts0[0] = lDonateAmount;
        uint256[] memory amounts1 = new uint[](1);
        amounts1[0] = lDonateAmount;
        int24[] memory ticks = new int24[](1);
        ticks[0] = 15;

        // Donate & check that balances were pulled to the pool.
        uint256 lBefore0 = key.currency0.balanceOf(address(manager));
        uint256 lBefore1 = key.currency1.balanceOf(address(manager));
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), lBefore0 + lDonateAmount, "amount0 donation failed");
        assertEq(key.currency1.balanceOf(address(manager)), lBefore1 + lDonateAmount, "amount1 donation failed");

        // Close position that received the donate.
        vm.prank(lpInfo1.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo1.tickLower, lpInfo1.tickUpper, -lpInfo1.liquidity), ZERO_BYTES
        );

        // Ensure users received their intended donations.
        assertApproxEqAbs(
            key.currency0.balanceOf(lpInfo1.lpAddress), lpInfo1.amount0 + lDonateAmount, 1, "amount0 withdraw mismatch"
        );
        assertApproxEqAbs(
            key.currency1.balanceOf(lpInfo1.lpAddress), lpInfo1.amount1 + lDonateAmount, 1, "amount1 withdraw mismatch"
        );

        // Redeem the other position and ensure pool is empty (math precision leaves some wei).
        vm.prank(lpInfo0.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo0.tickLower, lpInfo0.tickUpper, -lpInfo0.liquidity), ZERO_BYTES
        );
        assertLt(key.currency0.balanceOf(address(manager)), 10, "Too much amount0 dust");
        assertLt(key.currency1.balanceOf(address(manager)), 10, "Too much amount1 dust");
        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity left over");
    }

    function testDonateTick_AboveActiveSkipOneMiddle() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create 2 LP positions, active tick and one tick above active.
        LpInfo memory lpInfo0 = _createLpPosition(key, 0, 10, 1e18);
        LpInfo memory lpInfo1 = _createLpPosition(key, 10, 20, 1e18);
        LpInfo memory lpInfo2 = _createLpPosition(key, 20, 30, 1e18);

        // Donate 2 eth of each asset to the position in range at tick 10 (tickLower = 10).
        uint256 lDonateAmount = 2 ether;
        uint256[] memory amounts0 = new uint[](1);
        amounts0[0] = lDonateAmount;
        uint256[] memory amounts1 = new uint[](1);
        amounts1[0] = lDonateAmount;
        int24[] memory ticks = new int24[](1);
        ticks[0] = 25;

        uint256 lBefore0 = key.currency0.balanceOf(address(manager));
        uint256 lBefore1 = key.currency1.balanceOf(address(manager));

        // Donate & check that balances were pulled to the pool.
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), lBefore0 + lDonateAmount, "amount0 donation failed");
        assertEq(key.currency1.balanceOf(address(manager)), lBefore1 + lDonateAmount, "amount1 donation failed");

        // Close position that received the donate.
        vm.prank(lpInfo2.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo2.tickLower, lpInfo2.tickUpper, -lpInfo2.liquidity), ZERO_BYTES
        );

        // Ensure users received their intended donations.
        assertApproxEqAbs(
            key.currency0.balanceOf(lpInfo2.lpAddress), lpInfo2.amount0 + lDonateAmount, 1, "amount0 withdraw mismatch"
        );
        assertApproxEqAbs(
            key.currency1.balanceOf(lpInfo2.lpAddress), lpInfo2.amount1 + lDonateAmount, 1, "amount1 withdraw mismatch"
        );

        // Redeem the other position and ensure pool is empty (math precision leaves some wei).
        vm.prank(lpInfo0.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo0.tickLower, lpInfo0.tickUpper, -lpInfo0.liquidity), ZERO_BYTES
        );
        vm.prank(lpInfo1.lpAddress);
        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(lpInfo1.tickLower, lpInfo1.tickUpper, -lpInfo1.liquidity), ZERO_BYTES
        );
        assertLt(key.currency0.balanceOf(address(manager)), 10, "Too much amount0 dust");
        assertLt(key.currency1.balanceOf(address(manager)), 10, "Too much amount1 dust");
        assertEq(manager.getLiquidity(key.toId()), 0, "Liquidity left over");
    }

    function testDonateManyRangesBelowCurrentTick_2Positions(uint256 donateAmount) public {
        uint256 nPositions = 2;
        donateAmount = bound(donateAmount, 0, 2 ** 127 / nPositions - 1);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        LpInfo[] memory lpInfo = _createLpPositionsSymmetric(key, nPositions);

        uint256[] memory amounts0 = new uint[](nPositions);
        amounts0[0] = donateAmount;
        amounts0[1] = donateAmount;

        uint256[] memory amounts1 = new uint[](nPositions);
        amounts1[0] = donateAmount;
        amounts1[1] = donateAmount;

        int24[] memory ticks = new int24[](nPositions);
        ticks[0] = lpInfo[1].tickLower;
        ticks[1] = lpInfo[0].tickLower;

        uint256 liquidityBalance0 = key.currency0.balanceOf(address(manager));
        uint256 liquidityBalance1 = key.currency1.balanceOf(address(manager));

        // Donate and make sure all balances were pulled.
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), donateAmount * nPositions + liquidityBalance0);
        assertEq(key.currency1.balanceOf(address(manager)), donateAmount * nPositions + liquidityBalance1);

        // Close all positions.
        for (uint256 i = 0; i < lpInfo.length; i++) {
            vm.prank(lpInfo[i].lpAddress);
            modifyPositionRouter.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams(lpInfo[i].tickLower, lpInfo[i].tickUpper, -lpInfo[i].liquidity),
                ZERO_BYTES
            );
        }

        // Ensure the pool was emptied (some wei rounding imprecision may remain).
        assertLt(key.currency0.balanceOf(address(manager)), 10);
        assertLt(key.currency1.balanceOf(address(manager)), 10);
        assertEq(manager.getLiquidity(key.toId()), 0);
    }

    function testDonateManyRangesBelowCurrentTick_3Positions(uint256 donateAmount) public {
        uint256 nPositions = 3;
        donateAmount = bound(donateAmount, 0, 2 ** 127 / nPositions - 1);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        LpInfo[] memory lpInfo = _createLpPositionsSymmetric(key, nPositions);

        uint256[] memory amounts0 = new uint[](nPositions);
        amounts0[0] = donateAmount;
        amounts0[1] = donateAmount;
        amounts0[2] = donateAmount;

        uint256[] memory amounts1 = new uint[](nPositions);
        amounts1[0] = donateAmount;
        amounts1[1] = donateAmount;
        amounts1[2] = donateAmount;

        int24[] memory ticks = new int24[](nPositions);
        ticks[0] = lpInfo[2].tickLower;
        ticks[1] = lpInfo[1].tickLower;
        ticks[2] = lpInfo[0].tickLower;

        uint256 liquidityBalance0 = key.currency0.balanceOf(address(manager));
        uint256 liquidityBalance1 = key.currency1.balanceOf(address(manager));

        // Donate and make sure all balances were pulled.
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), donateAmount * nPositions + liquidityBalance0);
        assertEq(key.currency1.balanceOf(address(manager)), donateAmount * nPositions + liquidityBalance1);

        // Close all positions.
        for (uint256 i = 0; i < lpInfo.length; i++) {
            vm.prank(lpInfo[i].lpAddress);
            modifyPositionRouter.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams(lpInfo[i].tickLower, lpInfo[i].tickUpper, -lpInfo[i].liquidity),
                ZERO_BYTES
            );
        }

        // Ensure the pool was emptied (some wei rounding imprecision may remain).
        assertLt(key.currency0.balanceOf(address(manager)), 10);
        assertLt(key.currency1.balanceOf(address(manager)), 10);
        assertEq(manager.getLiquidity(key.toId()), 0);
    }

    function testDonateManyRangesAboveCurrentTick_2Positions(uint256 donateAmount) public {
        uint256 nPositions = 2;
        // NB: Withdrawing the position can overflow the BalanceDelta value.
        donateAmount = bound(donateAmount, 0, 2 ** 127 / uint256(3) - 1);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        LpInfo[] memory lpInfo = _createLpPositionsSymmetric(key, nPositions);

        uint256[] memory amounts0 = new uint[](nPositions);
        amounts0[0] = donateAmount;
        amounts0[1] = donateAmount;

        uint256[] memory amounts1 = new uint[](nPositions);
        amounts1[0] = donateAmount;
        amounts1[1] = donateAmount;

        int24[] memory ticks = new int24[](nPositions);
        ticks[0] = lpInfo[0].tickUpper;
        ticks[1] = lpInfo[1].tickUpper - 1;

        uint256 liquidityBalance0 = key.currency0.balanceOf(address(manager));
        uint256 liquidityBalance1 = key.currency1.balanceOf(address(manager));

        // Donate and make sure all balances were pulled.
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), donateAmount * nPositions + liquidityBalance0);
        assertEq(key.currency1.balanceOf(address(manager)), donateAmount * nPositions + liquidityBalance1);

        // Close all positions.
        for (uint256 i = 0; i < lpInfo.length; i++) {
            vm.prank(lpInfo[i].lpAddress);
            modifyPositionRouter.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams(lpInfo[i].tickLower, lpInfo[i].tickUpper, -lpInfo[i].liquidity),
                ZERO_BYTES
            );
        }

        // Ensure the pool was emptied (some wei rounding imprecision may remain).
        assertLt(key.currency0.balanceOf(address(manager)), 10);
        assertLt(key.currency1.balanceOf(address(manager)), 10);
        assertEq(manager.getLiquidity(key.toId()), 0);
    }

    function testDonateManyRangesAboveCurrentTick_3Positions(uint256 donateAmount) public {
        uint256 nPositions = 3;
        donateAmount = bound(donateAmount, 0, 2 ** 127 / nPositions - 1);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        LpInfo[] memory lpInfo = _createLpPositionsSymmetric(key, nPositions);

        uint256[] memory amounts0 = new uint[](nPositions);
        amounts0[0] = donateAmount;
        amounts0[1] = donateAmount;
        amounts0[2] = donateAmount;

        uint256[] memory amounts1 = new uint[](nPositions);
        amounts1[0] = donateAmount;
        amounts1[1] = donateAmount;
        amounts1[2] = donateAmount;

        int24[] memory ticks = new int24[](nPositions);
        ticks[0] = lpInfo[0].tickUpper;
        ticks[1] = lpInfo[1].tickUpper;
        ticks[2] = lpInfo[2].tickUpper - 1;

        uint256 liquidityBalance0 = key.currency0.balanceOf(address(manager));
        uint256 liquidityBalance1 = key.currency1.balanceOf(address(manager));

        // Donate and make sure all balances were pulled.
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), donateAmount * nPositions + liquidityBalance0);
        assertEq(key.currency1.balanceOf(address(manager)), donateAmount * nPositions + liquidityBalance1);

        // Close all positions.
        for (uint256 i = 0; i < lpInfo.length; i++) {
            vm.prank(lpInfo[i].lpAddress);
            modifyPositionRouter.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams(lpInfo[i].tickLower, lpInfo[i].tickUpper, -lpInfo[i].liquidity),
                ZERO_BYTES
            );
        }

        // Ensure the pool was emptied (some wei rounding imprecision may remain).
        assertLt(key.currency0.balanceOf(address(manager)), 10);
        assertLt(key.currency1.balanceOf(address(manager)), 10);
        assertEq(manager.getLiquidity(key.toId()), 0);
    }

    function testDonateManyRangesBelowOnAndAboveCurrentTick(uint256 donateAmount) public {
        uint256 nPositions = 3;
        donateAmount = bound(donateAmount, 0, 2 ** 127 / nPositions - 1);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        LpInfo[] memory lpInfo = _createLpPositionsSymmetric(key, nPositions);

        uint256[] memory amounts0 = new uint[](nPositions);
        amounts0[0] = donateAmount;
        amounts0[1] = donateAmount;
        amounts0[2] = donateAmount;

        uint256[] memory amounts1 = new uint[](nPositions);
        amounts1[0] = donateAmount;
        amounts1[1] = donateAmount;
        amounts1[2] = donateAmount;

        int24[] memory ticks = new int24[](nPositions);
        ticks[0] = lpInfo[0].tickLower;
        ticks[1] = 0;
        ticks[2] = lpInfo[0].tickUpper;

        uint256 liquidityBalance0 = key.currency0.balanceOf(address(manager));
        uint256 liquidityBalance1 = key.currency1.balanceOf(address(manager));

        // Donate and make sure all balances were pulled.
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
        assertEq(key.currency0.balanceOf(address(manager)), donateAmount * nPositions + liquidityBalance0);
        assertEq(key.currency1.balanceOf(address(manager)), donateAmount * nPositions + liquidityBalance1);

        // Close all positions.
        for (uint256 i = 0; i < lpInfo.length; i++) {
            vm.prank(lpInfo[i].lpAddress);
            modifyPositionRouter.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams(lpInfo[i].tickLower, lpInfo[i].tickUpper, -lpInfo[i].liquidity),
                ZERO_BYTES
            );
        }

        // Ensure the pool was emptied (some wei rounding imprecision may remain).
        assertLt(key.currency0.balanceOf(address(manager)), 10);
        assertLt(key.currency1.balanceOf(address(manager)), 10);
        assertEq(manager.getLiquidity(key.toId()), 0);
    }

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

    function _testDonateCase(PositionCase[] memory positions, DonateCase[] memory donations) private {
        // Bail if there are no donations.
        if (donations.length == 0) {
            return;
        }

        // Setup target pool.
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Bound positions to valid tick range & avoid liquidity overflow.
        for (uint256 i = 0; i < positions.length; ++i) {
            positions[i].liquidity = uint128(bound(positions[i].liquidity, 1, 2 ** 100));
            positions[i].tick0 = bound(positions[i].tick0, int256(TickMath.MIN_TICK + key.tickSpacing), int256(TickMath.MAX_TICK - key.tickSpacing));
            positions[i].tick1 = bound(positions[i].tick1, int256(TickMath.MIN_TICK + key.tickSpacing), int256(TickMath.MAX_TICK - key.tickSpacing));
        }

        // Bound donations to valid tick range.
        for (uint256 i = 0; i < donations.length; ++i) {
            donations[i].tick = bound(donations[i].tick, int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK));
        }

        // Add some full range liquidity to avoid no liquidity at tick errors.
        int24 minTick = _ceilToTickSpacing(key, TickMath.MIN_TICK);
        int24 maxTick = _floorToTickSpacing(key, TickMath.MAX_TICK);
        console2.logInt(minTick);
        console2.logInt(maxTick);
        _createLpPosition(key, minTick, maxTick, 1e18);

        // Create positions.
        LpInfo[] memory lpInfo = new LpInfo[](positions.length);
        for (uint256 i = 0; i < positions.length; ++i) {
            int24 tickLower = _min(int24(positions[i].tick0), int24(positions[i].tick1));
            int24 tickUpper = _max(int24(positions[i].tick0), int24(positions[i].tick1));

            // Bail if ticks are identical.
            if (tickLower == tickUpper) {
                return;
            }

            lpInfo[i] = _createLpPosition(
                key,
                _floorToTickSpacing(key, tickLower),
                _ceilToTickSpacing(key, tickUpper),
                int256(uint256(positions[i].liquidity))
            );
        }

        // Convert donations cases to donation arguments.
        uint256 amount0Sum;
        uint256 amount1Sum;
        uint256[] memory amounts0 = new uint256[](donations.length);
        uint256[] memory amounts1 = new uint256[](donations.length);
        int256[] memory ticks = new int256[](donations.length);
        for (uint256 i = 0; i < donations.length; ++i) {
            uint256 amount0 = bound(donations[i].amount0, 0, 2**127 / donations.length);
            uint256 amount1 = bound(donations[i].amount1, 0, 2**127 / donations.length);

            amount0Sum += amount0;
            amount1Sum += amount1;
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
                return;
            }
        }

        // Donate and make sure all balances were pulled.
        uint256 liquidityBalance0 = key.currency0.balanceOf(address(manager));
        uint256 liquidityBalance1 = key.currency1.balanceOf(address(manager));
        donateRouter.donateRange(key, amounts0, amounts1, ticksCast);
        assertEq(key.currency0.balanceOf(address(manager)), amount0Sum + liquidityBalance0);
        assertEq(key.currency1.balanceOf(address(manager)), amount1Sum + liquidityBalance1);

        // Close all positions.
        modifyPositionRouter.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(minTick, maxTick, -1e18),
            ZERO_BYTES
        );
        for (uint256 i = 0; i < lpInfo.length; i++) {
            vm.prank(lpInfo[i].lpAddress);
            modifyPositionRouter.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams(lpInfo[i].tickLower, lpInfo[i].tickUpper, -lpInfo[i].liquidity),
                ZERO_BYTES
            );
        }

        // Ensure the pool was emptied (some wei rounding imprecision may remain).
        assertLt(key.currency0.balanceOf(address(manager)), 2 * positions.length + 2);
        assertLt(key.currency1.balanceOf(address(manager)), 2 * positions.length + 2);
        assertEq(manager.getLiquidity(key.toId()), 0);
    }

    function testDonateMany_Fuzz(PositionCase[] memory positions, DonateCase[] memory donations) public {
        _testDonateCase(positions, donations);
    }

    function testDonateMany_Boundaries() public {
        PositionCase[] memory positions = new PositionCase[](0);
        DonateCase[] memory donations = new DonateCase[](1);
        donations[0] = DonateCase({
            amount0: 1e18,
            amount1: 1e18,
            tick: 887260
        });

        _testDonateCase(positions, donations);
    }

    function testDonateRevert_TickListEmpty() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 10.
        _createLpPosition(key, 0, 10, 1e18);

        vm.expectRevert(Pool.InvalidTickList.selector);
        donateRouter.donateRange(key, new uint256[](0), new uint256[](0), new int24[](0));
    }

    function testDonateRevert_TickListImbalancedAmounts0() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 10.
        _createLpPosition(key, 0, 10, 1e18);

        vm.expectRevert(Pool.InvalidTickList.selector);
        donateRouter.donateRange(key, new uint256[](2), new uint256[](1), new int24[](1));
    }

    function testDonateRevert_TickListImbalancedAmounts1() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 10.
        _createLpPosition(key, 0, 10, 1e18);

        vm.expectRevert(Pool.InvalidTickList.selector);
        donateRouter.donateRange(key, new uint256[](1), new uint256[](2), new int24[](1));
    }

    function testDonateRevert_TickListImbalancedTicks() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 10.
        _createLpPosition(key, 0, 10, 1e18);

        vm.expectRevert(Pool.InvalidTickList.selector);
        donateRouter.donateRange(key, new uint256[](1), new uint256[](1), new int24[](2));
    }

    function testDonateRevert_TickListTooLow() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 10.
        _createLpPosition(key, 0, 10, 1e18);

        uint256[] memory amounts0 = new uint256[](1);
        amounts0[0] = 1e18;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e18;
        int24[] memory ticks = new int24[](1);
        ticks[0] = TickMath.MIN_TICK - 1;

        vm.expectRevert(abi.encodePacked(Pool.TickLowerOutOfBounds.selector, int256(TickMath.MIN_TICK - 1)));
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
    }

    function testDonateRevert_TickListTooHigh() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 10.
        _createLpPosition(key, 0, 10, 1e18);

        uint256[] memory amounts0 = new uint256[](1);
        amounts0[0] = 1e18;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e18;
        int24[] memory ticks = new int24[](1);
        ticks[0] = TickMath.MAX_TICK + 1;

        vm.expectRevert(abi.encodePacked(Pool.TickUpperOutOfBounds.selector, int256(TickMath.MAX_TICK + 1)));
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
    }

    function testDonate_HasLiquidity() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 10.
        _createLpPosition(key, 0, 10, 1e18);

        uint256[] memory amounts0 = new uint256[](1);
        amounts0[0] = 1e18;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e18;
        int24[] memory ticks = new int24[](1);
        ticks[0] = 0;

        donateRouter.donateRange(key, amounts0, amounts1, ticks);
    }

    function testDonateRevert_NoLiquidity() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 10.
        _createLpPosition(key, 0, 10, 1e18);

        uint256[] memory amounts0 = new uint256[](1);
        amounts0[0] = 1e18;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e18;
        int24[] memory ticks = new int24[](1);
        ticks[0] = 20;

        vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
    }

    function testDonateRevert_MisorderdListAbove1() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 40.
        _createLpPosition(key, 0, 40, 1e18);

        uint256[] memory amounts0 = new uint256[](2);
        amounts0[0] = 1e18;
        amounts0[1] = 1e18;
        uint256[] memory amounts1 = new uint256[](2);
        amounts1[0] = 1e18;
        amounts1[1] = 1e18;
        int24[] memory ticks = new int24[](2);
        ticks[0] = 20;
        ticks[1] = 10;

        vm.expectRevert(Pool.InvalidTickList.selector);
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
    }

    function testDonateRevert_MisorderdListAbove2() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 40.
        _createLpPosition(key, 0, 40, 1e18);

        uint256[] memory amounts0 = new uint256[](2);
        amounts0[0] = 1e18;
        amounts0[1] = 1e18;
        uint256[] memory amounts1 = new uint256[](2);
        amounts1[0] = 1e18;
        amounts1[1] = 1e18;
        int24[] memory ticks = new int24[](2);
        ticks[0] = 20;
        ticks[1] = 0;

        // TODO: Shouldn't this revert? tick0 might be considered below active and is causing an issue.
        vm.expectRevert(Pool.InvalidTickList.selector);
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
    }

    function testDonateRevert_MisorderdListDual() external {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create an LP position with tickLower 0 and tickUpper 40.
        _createLpPosition(key, -40, 40, 1e18);

        uint256[] memory amounts0 = new uint256[](3);
        amounts0[0] = 1e18;
        amounts0[1] = 1e18;
        amounts0[2] = 1e18;
        uint256[] memory amounts1 = new uint256[](3);
        amounts1[0] = 1e18;
        amounts1[1] = 1e18;
        amounts1[2] = 1e18;
        int24[] memory ticks = new int24[](3);
        ticks[0] = 20;
        ticks[1] = 0;
        ticks[2] = -20;

        // TODO: Shouldn't ticks below be processed first?
        vm.expectRevert(Pool.InvalidTickList.selector);
        donateRouter.donateRange(key, amounts0, amounts1, ticks);
    }

    function test_take_failsWithNoLiquidity() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        vm.expectRevert();
        takeRouter.take(key, 100, 0);
    }

    function test_take_failsWithInvalidTokensThatDoNotReturnTrueOnTransfer() public {
        TestInvalidERC20 invalidToken = new TestInvalidERC20(2**255);
        Currency invalidCurrency = Currency.wrap(address(invalidToken));
        bool currency0Invalid = invalidCurrency < currency0;
        PoolKey memory key = PoolKey({
            currency0: currency0Invalid ? invalidCurrency : currency0,
            currency1: currency0Invalid ? currency0 : invalidCurrency,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: 60
        });

        invalidToken.approve(address(modifyPositionRouter), type(uint256).max);
        invalidToken.approve(address(takeRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(takeRouter), type(uint256).max);

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-60, 60, 1000);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);

        (uint256 amount0, uint256 amount1) = currency0Invalid ? (1, 0) : (0, 1);
        vm.expectRevert();
        takeRouter.take(key, amount0, amount1);

        // should not revert when non zero amount passed in for valid currency
        // assertions inside takeRouter because it takes then settles
        (amount0, amount1) = currency0Invalid ? (0, 1) : (1, 0);
        takeRouter.take(key, amount0, amount1);
    }

    function test_take_succeedsWithPoolWithLiquidity() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-60, 60, 100);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);
        takeRouter.take(key, 1, 1); // assertions inside takeRouter because it takes then settles
    }

    function test_take_succeedsWithPoolWithLiquidityWithNativeToken() public {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            fee: 100,
            hooks: IHooks(address(0)),
            tickSpacing: 10
        });
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-60, 60, 100);
        modifyPositionRouter.modifyPosition{value: 100}(key, params, ZERO_BYTES);
        takeRouter.take{value: 1}(key, 1, 1); // assertions inside takeRouter because it takes then settles
    }

    function test_setProtocolFee_updatesProtocolFeeForInitializedPool() public {
        uint24 protocolFee = 4;

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.protocolFees, 0);
        manager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeUpdated(key.toId(), protocolFee << 12);
        manager.setProtocolFees(key);
    }

    function test_collectProtocolFees_initializesWithProtocolFeeIfCalled() public {
        uint24 protocolFee = 260; // 0001 00 00 0100
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        // sets the upper 12 bits
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.protocolFees, protocolFee << 12);
    }

    function test_collectProtocolFees_ERC20_allowsOwnerToAccumulateFees_gas() public {
        uint24 protocolFee = 260; // 0001 00 00 0100
        uint256 expectedFees = 7;

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.protocolFees, protocolFee << 12);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-120, 120, 10 ether);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);
        swapRouter.swap(
            key, IPoolManager.SwapParams(true, 10000, SQRT_RATIO_1_2), PoolSwapTest.TestSettings(true, true), ZERO_BYTES
        );

        assertEq(manager.protocolFeesAccrued(currency0), expectedFees);
        assertEq(manager.protocolFeesAccrued(currency1), 0);
        assertEq(currency0.balanceOf(address(1)), 0);
        snapStart("erc20 collect protocol fees");
        manager.collectProtocolFees(address(1), currency0, expectedFees);
        snapEnd();
        assertEq(currency0.balanceOf(address(1)), expectedFees);
        assertEq(manager.protocolFeesAccrued(currency0), 0);
    }

    function test_collectProtocolFees_ERC20_returnsAllFeesIf0IsProvidedAsParameter() public {
        uint24 protocolFee = 260; // 0001 00 00 0100
        uint256 expectedFees = 7;

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.protocolFees, protocolFee << 12);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-120, 120, 10 ether);
        modifyPositionRouter.modifyPosition(key, params, ZERO_BYTES);
        swapRouter.swap(
            key, IPoolManager.SwapParams(true, 10000, SQRT_RATIO_1_2), PoolSwapTest.TestSettings(true, true), ZERO_BYTES
        );

        assertEq(manager.protocolFeesAccrued(currency0), expectedFees);
        assertEq(manager.protocolFeesAccrued(currency1), 0);
        assertEq(currency0.balanceOf(address(1)), 0);
        manager.collectProtocolFees(address(1), currency0, 0);
        assertEq(currency0.balanceOf(address(1)), expectedFees);
        assertEq(manager.protocolFeesAccrued(currency0), 0);
    }

    function test_collectProtocolFees_nativeToken_allowsOwnerToAccumulateFees_gas() public {
        uint24 protocolFee = 260; // 0001 00 00 0100
        uint256 expectedFees = 7;
        Currency nativeCurrency = CurrencyLibrary.NATIVE;

        PoolKey memory key = PoolKey({
            currency0: nativeCurrency,
            currency1: currency1,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: 10
        });
        manager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.protocolFees, protocolFee << 12);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-120, 120, 10 ether);
        modifyPositionRouter.modifyPosition{value: 10 ether}(key, params, ZERO_BYTES);
        swapRouter.swap{value: 10000}(
            key, IPoolManager.SwapParams(true, 10000, SQRT_RATIO_1_2), PoolSwapTest.TestSettings(true, true), ZERO_BYTES
        );

        assertEq(manager.protocolFeesAccrued(nativeCurrency), expectedFees);
        assertEq(manager.protocolFeesAccrued(currency1), 0);
        assertEq(nativeCurrency.balanceOf(address(1)), 0);
        snapStart("native collect protocol fees");
        manager.collectProtocolFees(address(1), nativeCurrency, expectedFees);
        snapEnd();
        assertEq(nativeCurrency.balanceOf(address(1)), expectedFees);
        assertEq(manager.protocolFeesAccrued(nativeCurrency), 0);
    }

    function test_collectProtocolFees_nativeToken_returnsAllFeesIf0IsProvidedAsParameter() public {
        uint24 protocolFee = 260; // 0001 00 00 0100
        uint256 expectedFees = 7;
        Currency nativeCurrency = CurrencyLibrary.NATIVE;

        PoolKey memory key = PoolKey({
            currency0: nativeCurrency,
            currency1: currency1,
            fee: 3000,
            hooks: IHooks(address(0)),
            tickSpacing: 10
        });
        manager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);
        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.protocolFees, protocolFee << 12);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams(-120, 120, 10 ether);
        modifyPositionRouter.modifyPosition{value: 10 ether}(key, params, ZERO_BYTES);
        swapRouter.swap{value: 10000}(
            key, IPoolManager.SwapParams(true, 10000, SQRT_RATIO_1_2), PoolSwapTest.TestSettings(true, true), ZERO_BYTES
        );

        assertEq(manager.protocolFeesAccrued(nativeCurrency), expectedFees);
        assertEq(manager.protocolFeesAccrued(currency1), 0);
        assertEq(nativeCurrency.balanceOf(address(1)), 0);
        manager.collectProtocolFees(address(1), nativeCurrency, 0);
        assertEq(nativeCurrency.balanceOf(address(1)), expectedFees);
        assertEq(manager.protocolFeesAccrued(nativeCurrency), 0);
    }

    function test_lock_NoOpIsOk() public {
        snapStart("gas overhead of no-op lock");
        lockTest.lock();
        snapEnd();
    }

    function test_lock_EmitsCorrectId() public {
        vm.expectEmit(false, false, false, true);
        emit LockAcquired();
        lockTest.lock();
    }

    // function testExtsloadForPoolPrice() public {
    //     IPoolManager.PoolKey memory key = IPoolManager.PoolKey({
    //         currency0: currency0,
    //         currency1: currency1,
    //         fee: 100,
    //         hooks: IHooks(address(0)),
    //         tickSpacing: 10
    //     });
    //     manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

    //     PoolId poolId = key.toId();
    //     snapStart("poolExtsloadSlot0");
    //     bytes32 slot0Bytes = manager.extsload(keccak256(abi.encode(poolId, POOL_SLOT)));
    //     snapEnd();

    //     uint160 sqrtPriceX96Extsload;
    //     assembly {
    //         sqrtPriceX96Extsload := and(slot0Bytes, sub(shl(160, 1), 1))
    //     }
    //     (uint160 sqrtPriceX96Slot0,,,,,) = manager.getSlot0(poolId);

    //     // assert that extsload loads the correct storage slot which matches the true slot0
    //     assertEq(sqrtPriceX96Extsload, sqrtPriceX96Slot0);
    // }

    // function testExtsloadMultipleSlots() public {
    //     IPoolManager.PoolKey memory key = IPoolManager.PoolKey({
    //         currency0: currency0,
    //         currency1: currency1,
    //         fee: 100,
    //         hooks: IHooks(address(0)),
    //         tickSpacing: 10
    //     });
    //     manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

    //     // populate feeGrowthGlobalX128 struct w/ modify + swap
    //     modifyPositionRouter.modifyPosition(key, IPoolManager.ModifyPositionParams(-120, 120, 5 ether));
    //     swapRouter.swap(
    //         key,
    //         IPoolManager.SwapParams(false, 1 ether, TickMath.MAX_SQRT_RATIO - 1),
    //         PoolSwapTest.TestSettings(true, true)
    //     );
    //     swapRouter.swap(
    //         key,
    //         IPoolManager.SwapParams(true, 5 ether, TickMath.MIN_SQRT_RATIO + 1),
    //         PoolSwapTest.TestSettings(true, true)
    //     );

    //     PoolId poolId = key.toId();
    //     snapStart("poolExtsloadTickInfoStruct");
    //     bytes memory value = manager.extsload(bytes32(uint256(keccak256(abi.encode(poolId, POOL_SLOT))) + 1), 2);
    //     snapEnd();

    //     uint256 feeGrowthGlobal0X128Extsload;
    //     uint256 feeGrowthGlobal1X128Extsload;
    //     assembly {
    //         feeGrowthGlobal0X128Extsload := and(mload(add(value, 0x20)), sub(shl(256, 1), 1))
    //         feeGrowthGlobal1X128Extsload := and(mload(add(value, 0x40)), sub(shl(256, 1), 1))
    //     }

    //     assertEq(feeGrowthGlobal0X128Extsload, 408361710565269213475534193967158);
    //     assertEq(feeGrowthGlobal1X128Extsload, 204793365386061595215803889394593);
    // }

    function test_getPosition() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, hooks: IHooks(address(0)), tickSpacing: 10});
        manager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        modifyPositionRouter.modifyPosition(key, IPoolManager.ModifyPositionParams(-120, 120, 5 ether), ZERO_BYTES);

        Position.Info memory managerPosition = manager.getPosition(key.toId(), address(modifyPositionRouter), -120, 120);

        assertEq(managerPosition.liquidity, 5 ether);
    }

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
        return tick > 0
            ? _truncateToTickSpacing(key, tick)
            : _truncateToTickSpacing(key, tick - key.tickSpacing + 1);
    }

    function _ceilToTickSpacing(PoolKey memory key, int24 tick) private pure returns (int24) {
        return tick > 0
            ? _truncateToTickSpacing(key, tick + key.tickSpacing - 1)
            : _truncateToTickSpacing(key, tick);
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
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyPositionRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyPositionRouter), type(uint256).max);
        BalanceDelta delta = modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams(tickLower, tickUpper, liquidity), ZERO_BYTES
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
}
