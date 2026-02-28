// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {YieldNestKeeper} from "../../src/YieldNestKeeper.sol";
import {IYnVault} from "../../src/interfaces/IYnVault.sol";
import {IConversionRateProvider} from "../../src/interfaces/IConversionRateProvider.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IAccessControl {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @dev Simple rate provider for USDC/USDe peg. The on-chain rate provider from the strategy
///      deployment has a different interface (getRate(address) instead of getRate()).
contract MockRateProvider is IConversionRateProvider {
    uint256 public immutable rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function getRate() external view override returns (uint256) {
        return rate;
    }
}

contract YieldNestKeeperMainnetTest is Test {
    // ─── Mainnet Contract Addresses ─────────────────────────────────────────────

    // ynRWAx vault (asset = USDC)
    address constant YNRWAX = 0x01Ba69727E2860b37bc1a2bd56999c1aFb4C15D8;

    // Strategy deployment (from ynFlex-wstETH-ynETHx-LVG1-1.json)
    address constant SAFE = 0x24D2486F5b2C2c225B6be8B4f72D46349cBf4458;
    address constant STRATEGY = 0x115B50649e50c2b36B3D2Ec0928E72492c85dA7D;

    // Tokens
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Aave V3
    address constant A_WSTETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address constant VARIABLE_DEBT_USDE = 0x015396E1F286289aE23a762088E863b3ec465145;

    // Chainlink Oracles
    address constant USDC_USD_ORACLE = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant WSTETH_USD_ORACLE = 0x8B6851156023f4f5A66F68BEA80851c3D905Ac93;

    // Curve Router NG v1.1
    address constant CURVE_ROUTER = 0x16C6521Dff6baB339122a0FE25a9116693265353;

    // Curve pools
    address constant TRICRYPTO_USDC = 0x7F86Bf177Dd4F3494b841a37e810A34dD56c829B;
    address constant STETH_NG_POOL = 0x21E27a5E5513D6e65C4f830167390997aA84843a;

    // ynRWAx admin (YNSecurityCouncil)
    address constant YN_ADMIN = 0xfcad670592a3b24869C0b51a6c6FDED4F95D6975;

    // ynRWAx roles
    bytes32 constant ASSET_WITHDRAWER_ROLE = keccak256("ASSET_WITHDRAWER_ROLE");

    // ─── Test State ─────────────────────────────────────────────────────────────

    YieldNestKeeper keeper;
    MockRateProvider rateProvider;
    address admin = makeAddr("admin");

    function setUp() public {
        // Fork is configured via [profile.mainnet] eth_rpc_url in foundry.toml

        // Deploy mock rate provider: 1e18 = 1:1 USDC/USDe value peg
        rateProvider = new MockRateProvider(1e18);

        // Deploy keeper with mainnet config
        keeper = new YieldNestKeeper(admin, _buildConfig());

        // Grant ASSET_WITHDRAWER_ROLE on ynRWAx so keeper can call withdrawAsset
        vm.prank(YN_ADMIN);
        IAccessControl(YNRWAX).grantRole(ASSET_WITHDRAWER_ROLE, address(keeper));

        // Approve keeper to pull ynRWAx from safe
        vm.prank(SAFE);
        IERC20(YNRWAX).approve(address(keeper), type(uint256).max);

        // Grant HARVESTER_ROLE to the test contract
        vm.prank(admin);
        keeper.grantRole(keccak256("HARVESTER_ROLE"), address(this));

        // Mock wstETH/USD oracle: the BGD adapter returns updatedAt=0 from latestRoundData
        _mockWstethOracle();
    }

    // ─── Discovery Tests ────────────────────────────────────────────────────────

    function test_ynRWAxAssetIsUSDC() public view {
        address asset = IYnVault(YNRWAX).asset();
        assertEq(asset, USDC, "ynRWAx underlying asset should be USDC");
    }

    function test_discoverAaveCollateralIsWsteth() public view {
        uint256 collateral = IERC20(A_WSTETH).balanceOf(SAFE);
        assertGt(collateral, 0, "Safe should hold aWstETH (Aave wstETH collateral)");
        console2.log("Safe aWstETH balance:", collateral);
    }

    function test_discoverAaveDebtIsUSDe() public view {
        uint256 debt = IERC20(VARIABLE_DEBT_USDE).balanceOf(SAFE);
        assertGt(debt, 0, "Safe should have USDe variable debt on Aave");
        console2.log("Safe variableDebtUSDe balance:", debt);
    }

    // ─── View Function Tests ────────────────────────────────────────────────────

    function test_totalPositionShares() public view {
        uint256 shares = keeper.totalPositionShares();
        uint256 expected = IERC20(YNRWAX).balanceOf(SAFE);
        assertEq(shares, expected, "totalPositionShares should match safe's ynRWAx balance");
        console2.log("Total position shares:", shares);
    }

    function test_totalDebt() public view {
        uint256 debt = keeper.totalDebt();
        uint256 expected = IERC20(VARIABLE_DEBT_USDE).balanceOf(SAFE);
        assertEq(debt, expected, "totalDebt should match safe's variableDebtUSDe balance");
        console2.log("Total debt (USDe):", debt);
    }

    function test_earnedYield() public view {
        uint256 yield_ = keeper.earnedYield();
        console2.log("Earned yield (ynRWAx shares):", yield_);

        uint256 shares = keeper.totalPositionShares();
        uint256 positionValue = IYnVault(YNRWAX).convertToAssets(shares);
        uint256 debt = keeper.totalDebt();
        console2.log("Position value (convertToAssets):", positionValue);
        console2.log("Total debt (USDe):", debt);
    }

    // ─── Harvest Tests ──────────────────────────────────────────────────────────

    function test_harvest() public {
        uint256 yield_ = keeper.earnedYield();
        if (yield_ == 0) {
            console2.log("SKIP: No yield to harvest at current block");
            return;
        }

        uint256 strategyWstethBefore = IERC20(WSTETH).balanceOf(STRATEGY);

        keeper.harvest();

        uint256 strategyWstethAfter = IERC20(WSTETH).balanceOf(STRATEGY);
        assertGt(strategyWstethAfter, strategyWstethBefore, "Strategy should receive wstETH reward");

        uint256 received = strategyWstethAfter - strategyWstethBefore;
        console2.log("wstETH sent to strategy:", received);
    }

    function test_harvestSendsWstethToStrategy() public {
        uint256 yield_ = keeper.earnedYield();
        if (yield_ == 0) {
            console2.log("SKIP: No yield to harvest at current block");
            return;
        }

        uint256 before = IERC20(WSTETH).balanceOf(STRATEGY);
        keeper.harvest();
        uint256 received = IERC20(WSTETH).balanceOf(STRATEGY) - before;

        assertGt(received, 0, "Strategy must receive wstETH");
        console2.log("wstETH reward received by strategy:", received);
    }

    function test_harvestEmitsEvent() public {
        uint256 yield_ = keeper.earnedYield();
        if (yield_ == 0) {
            console2.log("SKIP: No yield to harvest at current block");
            return;
        }

        vm.expectEmit(false, false, false, false);
        emit YieldNestKeeper.Harvested(0, 0, 0);
        keeper.harvest();
    }

    function test_harvestRevertsWhenNoYield() public {
        // Mock the safe's ynRWAx balance to 0 so there's no position value
        vm.mockCall(YNRWAX, abi.encodeWithSelector(IERC20.balanceOf.selector, SAFE), abi.encode(uint256(0)));

        vm.expectRevert(YieldNestKeeper.NoYieldToHarvest.selector);
        keeper.harvest();
    }

    function test_harvestRevertsWithoutRole() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        keeper.harvest();
    }

    // ─── Harvest Tests (with yield setup) ───────────────────────────────────────

    /// @dev Creates yield by mocking debt lower than position value.
    ///      Position value is ~$588K USDC. The vault naturally holds ~$158K liquid USDC.
    ///      We mock debt to $550K USDe to create ~$38K yield, well within the vault's
    ///      liquid USDC reserves. We do NOT deal USDC to the vault as that would inflate
    ///      the share-to-asset conversion rate.
    function _setupHarvestableYield() internal {
        vm.mockCall(
            VARIABLE_DEBT_USDE, abi.encodeWithSelector(IERC20.balanceOf.selector, SAFE), abi.encode(uint256(550_000e18))
        );
    }

    function test_harvestWithYield() public {
        _setupHarvestableYield();

        uint256 yield_ = keeper.earnedYield();
        assertGt(yield_, 0, "Should have yield after debt mock");
        console2.log("Yield (ynRWAx shares):", yield_);

        uint256 strategyWstethBefore = IERC20(WSTETH).balanceOf(STRATEGY);
        keeper.harvest();
        uint256 strategyWstethAfter = IERC20(WSTETH).balanceOf(STRATEGY);

        uint256 received = strategyWstethAfter - strategyWstethBefore;
        assertGt(received, 0, "Strategy should receive wstETH reward");
        console2.log("wstETH harvested to strategy:", received);
    }

    function test_harvestWithYieldEmitsEvent() public {
        _setupHarvestableYield();

        vm.expectEmit(false, false, false, false);
        emit YieldNestKeeper.Harvested(0, 0, 0);
        keeper.harvest();
    }

    function test_harvestWithYieldSendsWsteth() public {
        _setupHarvestableYield();

        uint256 before = IERC20(WSTETH).balanceOf(STRATEGY);
        keeper.harvest();
        uint256 received = IERC20(WSTETH).balanceOf(STRATEGY) - before;

        assertGt(received, 0, "Strategy must receive wstETH");
        console2.log("wstETH reward received:", received);
    }

    function test_harvestWithYieldAccessControl() public {
        _setupHarvestableYield();

        address harvester = makeAddr("harvester2");
        bytes32 harvesterRole = keeper.HARVESTER_ROLE();

        vm.prank(admin);
        keeper.grantRole(harvesterRole, harvester);

        // Non-harvester should revert
        vm.prank(makeAddr("random2"));
        vm.expectRevert();
        keeper.harvest();

        // Harvester should succeed
        vm.prank(harvester);
        keeper.harvest();
    }

    // ─── Admin Tests ────────────────────────────────────────────────────────────

    function test_recoverToken() public {
        deal(WSTETH, address(keeper), 1e18);

        vm.prank(admin);
        keeper.recoverToken(WSTETH, admin, 1e18);
        assertEq(IERC20(WSTETH).balanceOf(admin), 1e18);
    }

    function test_setMinOutputBps() public {
        vm.prank(admin);
        keeper.setMinOutputBps(9800);
        // Verify earnedYield still returns without revert
        keeper.earnedYield();
    }

    function test_setMaxOracleAge() public {
        vm.prank(admin);
        keeper.setMaxOracleAge(3600);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────

    function _buildConfig() internal view returns (YieldNestKeeper.Config memory) {
        address[] memory positions = new address[](1);
        positions[0] = SAFE;

        (address[11] memory route, uint256[5][5] memory swapParams, address[5] memory pools) = _curveRoute();

        return YieldNestKeeper.Config({
            vault: IYnVault(YNRWAX),
            positions: positions,
            debtToken: IERC20(VARIABLE_DEBT_USDE),
            rateProvider: IConversionRateProvider(address(rateProvider)),
            approvedWallet: SAFE,
            rewardAsset: WSTETH,
            destinationStrategy: STRATEGY,
            curveRouter: CURVE_ROUTER,
            route: route,
            swapParams: swapParams,
            pools: pools,
            assetOracle: AggregatorV3Interface(USDC_USD_ORACLE),
            rewardOracle: AggregatorV3Interface(WSTETH_USD_ORACLE),
            maxOracleAge: 86400,
            minOutputBps: 9500 // 5% slippage tolerance for fork testing
        });
    }

    /// @dev Curve route: USDC -> WETH -> ETH -> stETH -> wstETH
    ///      4 hops: TricryptoUSDC exchange, WETH unwrap, stETH-ng exchange, wstETH wrap
    function _curveRoute()
        internal
        pure
        returns (address[11] memory route, uint256[5][5] memory swapParams, address[5] memory pools)
    {
        address ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        // Hop 1: USDC -> WETH via TricryptoUSDC pool
        route[0] = USDC;
        route[1] = TRICRYPTO_USDC;
        route[2] = WETH;

        // Hop 2: WETH -> ETH (unwrap)
        route[3] = WETH;
        route[4] = ETH;

        // Hop 3: ETH -> stETH via stETH-ng pool
        route[5] = STETH_NG_POOL;
        route[6] = STETH;

        // Hop 4: stETH -> wstETH via wrapping
        route[7] = WSTETH;
        route[8] = WSTETH;
        // route[9..10] = address(0) by default

        // Swap params: [i, j, swap_type, pool_type, n_coins]
        // Hop 1: USDC(0) -> WETH(2), exchange(uint256), tricrypto, 3 coins
        swapParams[0] = [uint256(0), 2, 1, 3, 3];
        // Hop 2: WETH -> ETH, unwrap via swap_type 8
        swapParams[1] = [uint256(0), 0, 8, 0, 0];
        // Hop 3: ETH(0) -> stETH(1), exchange(int128), stableswap, 2 coins
        swapParams[2] = [uint256(0), 1, 1, 1, 2];
        // Hop 4: stETH -> wstETH, wrap via swap_type 8
        swapParams[3] = [uint256(0), 0, 8, 0, 0];
        // swapParams[4] = [0,0,0,0,0] by default
    }

    /// @dev Mock the wstETH/USD oracle's latestRoundData to return proper timestamps.
    ///      The BGD WstETHSynchronicityPriceAdapter returns updatedAt=0 which fails staleness checks.
    function _mockWstethOracle() internal {
        // Read the real price from latestAnswer (which the adapter does support)
        (, bytes memory data) = WSTETH_USD_ORACLE.staticcall(abi.encodeWithSignature("latestAnswer()"));
        int256 price = abi.decode(data, (int256));

        vm.mockCall(
            WSTETH_USD_ORACLE,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), price, block.timestamp, block.timestamp, uint80(1))
        );
    }
}
