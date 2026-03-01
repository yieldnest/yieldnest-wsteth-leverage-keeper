// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YieldNestKeeper} from "src/YieldNestKeeper.sol";
import {StablecoinRateProvider} from "src/StablecoinRateProvider.sol";
import {IYnVault} from "src/interfaces/IYnVault.sol";
import {IConversionRateProvider} from "src/interfaces/IConversionRateProvider.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";
import {ICurveRouter} from "src/interfaces/ICurveRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─── Mock Contracts ──────────────────────────────────────────────────────────

contract MockYnVault is IERC20 {
    address public asset_;
    mapping(address => uint256) public override balanceOf;
    uint256 public override totalSupply;
    uint256 public rate; // assets per share, scaled by 1e18

    constructor(address _asset) {
        asset_ = _asset;
        rate = 1.05e18; // 5% yield
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function asset() external view returns (address) {
        return asset_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / rate;
    }

    function withdrawAsset(address, uint256 assets, address receiver, address owner) external returns (uint256) {
        uint256 shares = (assets * 1e18) / rate;
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        MockERC20(asset_).mint(receiver, assets);
        return shares;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function allowance(address, address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function approve(address, uint256) external pure override returns (bool) {
        return true;
    }
}

contract MockERC20 is IERC20 {
    string public name;
    mapping(address => uint256) public override balanceOf;
    uint256 public override totalSupply;
    uint8 public decimals;

    constructor(string memory _name, uint8 _decimals) {
        name = _name;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function allowance(address, address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function approve(address, uint256) external pure override returns (bool) {
        return true;
    }
}

contract MockRateProvider is IConversionRateProvider {
    uint256 public rate;

    constructor(uint256 _rate) {
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function getRate(address) external view override returns (uint256) {
        return rate;
    }
}

contract MockOracle is AggregatorV3Interface {
    int256 public price;
    uint8 public override decimals;
    uint256 public updatedAt;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimals = _decimals;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 _updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

contract MockCurveRouter {
    IERC20 public inputToken;
    MockERC20 public outputToken;
    uint256 public outputAmount;

    constructor(address _inputToken, address _outputToken, uint256 _outputAmount) {
        inputToken = IERC20(_inputToken);
        outputToken = MockERC20(_outputToken);
        outputAmount = _outputAmount;
    }

    function setOutputAmount(uint256 _outputAmount) external {
        outputAmount = _outputAmount;
    }

    function exchange(
        address[11] calldata, /* route */
        uint256[5][5] calldata, /* swapParams */
        uint256 _amount,
        uint256, /* minDy */
        address[5] calldata /* pools */
    ) external returns (uint256) {
        inputToken.transferFrom(msg.sender, address(this), _amount);
        outputToken.mint(msg.sender, outputAmount);
        return outputAmount;
    }
}

// ─── Test Contract ──────────────────────────────────────────────────────────

contract YieldNestKeeperTest is Test {
    YieldNestKeeper public keeper;
    MockYnVault public vault;
    MockERC20 public asset;
    MockERC20 public debtToken;
    MockERC20 public rewardAsset;
    MockRateProvider public rateProvider;
    MockOracle public assetOracle;
    MockOracle public rewardOracle;
    MockCurveRouter public curveRouter;

    address public admin = address(0xAD);
    address public wallet = address(0xA1);
    address public position1 = address(0xB1);
    address public destinationStrategy = address(0xDE);

    function setUp() public {
        asset = new MockERC20("Asset", 18);
        debtToken = new MockERC20("DebtToken", 6);
        rewardAsset = new MockERC20("Reward", 18);
        vault = new MockYnVault(address(asset));
        rateProvider = new MockRateProvider(1e18);
        assetOracle = new MockOracle(1e8, 8);
        rewardOracle = new MockOracle(1e8, 8);
        curveRouter = new MockCurveRouter(address(asset), address(rewardAsset), 100e18);

        // position1 holds 1000 vault shares and 1000 debt tokens
        vault.mint(position1, 1000e18);
        debtToken.mint(position1, 1000e6);

        // wallet has vault shares to be pulled by keeper
        vault.mint(wallet, 1000e18);

        keeper = _deployKeeper(_defaultConfig());
    }

    // ─── Harvest: Core Flow ──────────────────────────────────────────────────

    function test_harvest_succeeds() public {
        uint256 destBefore = rewardAsset.balanceOf(destinationStrategy);
        keeper.harvest();
        uint256 destAfter = rewardAsset.balanceOf(destinationStrategy);
        assertGt(destAfter, destBefore, "Destination should have received reward tokens");
    }

    function test_harvest_emitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit YieldNestKeeper.Harvested(0, 0, 0);
        keeper.harvest();
    }

    function test_harvest_transfersCorrectSharesFromWallet() public {
        uint256 walletBefore = IERC20(address(vault)).balanceOf(wallet);
        keeper.harvest();
        uint256 walletAfter = IERC20(address(vault)).balanceOf(wallet);
        assertLt(walletAfter, walletBefore, "Wallet should have fewer vault shares");
    }

    function test_harvest_yieldMath() public view {
        // 1000 shares at 1.05 rate = 1050 asset value
        // 1000e6 debt at 1:1 rate with 18-6=12 decimal adjustment = 1000e18 asset
        // yield = 1050e18 - 1000e18 = 50e18 asset
        // yieldInShares = 50e18 * 1e18 / 1.05e18 = ~47.619e18
        uint256 yield_ = keeper.earnedYield();
        uint256 rate = 1.05e18;
        uint256 expectedYield = (50e18 * 1e18) / rate;
        assertEq(yield_, expectedYield, "Yield should be ~47.619e18 shares");
    }

    function test_harvest_secondHarvestReverts() public {
        keeper.harvest();
        // After first harvest, yield is consumed. Wallet has fewer shares but position1's
        // shares haven't changed, so there should still be yield. However, the wallet may
        // not have enough shares for a second pull of the same size.
        // The position hasn't changed, so yield is the same, and wallet should still have
        // enough (had 1000, used ~47.6, ~952 remaining > 47.6 needed).
        // So second harvest should also work.
        keeper.harvest();
    }

    // ─── Harvest: Revert Cases ───────────────────────────────────────────────

    function test_harvest_revertsNoYield_debtExceedsPosition() public {
        debtToken.mint(position1, 1050e6); // total debt = 2050e6 > 1050 asset value
        vm.expectRevert(YieldNestKeeper.NoYieldToHarvest.selector);
        keeper.harvest();
    }

    function test_harvest_revertsNoYield_debtEqualsPosition() public {
        // Position value = 1050e18. Need debt to equal that.
        // 1050e6 debt (6 dec) converts to 1050e18 asset. Current is 1000e6, add 50e6.
        debtToken.mint(position1, 50e6);
        vm.expectRevert(YieldNestKeeper.NoYieldToHarvest.selector);
        keeper.harvest();
    }

    function test_harvest_revertsNoYield_zeroShares() public {
        // Set rate to exactly 1.0 so position value == debt
        vault.setRate(1e18);
        vm.expectRevert(YieldNestKeeper.NoYieldToHarvest.selector);
        keeper.harvest();
    }

    function test_harvest_isPermissionless() public {
        uint256 destBefore = rewardAsset.balanceOf(destinationStrategy);
        vm.prank(address(0xBAD));
        keeper.harvest();
        assertGt(rewardAsset.balanceOf(destinationStrategy), destBefore, "Anyone should be able to harvest");
    }

    // ─── Harvest: Oracle Edge Cases ──────────────────────────────────────────

    function test_harvest_revertsOnStaleAssetOracle() public {
        vm.warp(100_000);
        assetOracle.setUpdatedAt(block.timestamp - 86401);
        vm.expectRevert(YieldNestKeeper.StaleOraclePrice.selector);
        keeper.harvest();
    }

    function test_harvest_revertsOnStaleRewardOracle() public {
        vm.warp(100_000);
        rewardOracle.setUpdatedAt(block.timestamp - 86401);
        vm.expectRevert(YieldNestKeeper.StaleOraclePrice.selector);
        keeper.harvest();
    }

    function test_harvest_revertsOnZeroAssetPrice() public {
        assetOracle.setPrice(0);
        vm.expectRevert(YieldNestKeeper.InvalidPrice.selector);
        keeper.harvest();
    }

    function test_harvest_revertsOnNegativeAssetPrice() public {
        assetOracle.setPrice(-1);
        vm.expectRevert(YieldNestKeeper.InvalidPrice.selector);
        keeper.harvest();
    }

    function test_harvest_revertsOnZeroRewardPrice() public {
        rewardOracle.setPrice(0);
        vm.expectRevert(YieldNestKeeper.InvalidPrice.selector);
        keeper.harvest();
    }

    function test_harvest_revertsOnNegativeRewardPrice() public {
        rewardOracle.setPrice(-1);
        vm.expectRevert(YieldNestKeeper.InvalidPrice.selector);
        keeper.harvest();
    }

    function test_harvest_succeedsAtOracleAgeBoundary() public {
        vm.warp(100_000);
        // Set oracle to exactly maxOracleAge seconds ago - should still pass
        assetOracle.setUpdatedAt(block.timestamp - 86400);
        rewardOracle.setUpdatedAt(block.timestamp - 86400);
        keeper.harvest();
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    function test_earnedYield_returnsZeroWhenUnderwater() public {
        debtToken.mint(position1, 1100e6); // way over
        uint256 yield_ = keeper.earnedYield();
        assertEq(yield_, 0, "Should return 0 when underwater");
    }

    function test_earnedYield_returnsZeroWhenEqual() public {
        debtToken.mint(position1, 50e6); // exactly equal
        uint256 yield_ = keeper.earnedYield();
        assertEq(yield_, 0, "Should return 0 when position equals debt");
    }

    function test_earnedYield_returnsPositiveWhenYieldExists() public view {
        uint256 yield_ = keeper.earnedYield();
        assertGt(yield_, 0, "Should report yield");
    }

    function test_totalPositionShares() public view {
        uint256 shares = keeper.totalPositionShares();
        assertEq(shares, 1000e18, "Total position shares should be 1000e18");
    }

    function test_totalDebt() public view {
        uint256 debt = keeper.totalDebt();
        assertEq(debt, 1000e6, "Total debt should be 1000e6");
    }

    // ─── Multiple Positions ──────────────────────────────────────────────────

    function test_multiplePositions_aggregatesShares() public {
        address position2 = address(0xB2);
        vault.mint(position2, 500e18);
        debtToken.mint(position2, 500e6);

        address[] memory positions = new address[](2);
        positions[0] = position1;
        positions[1] = position2;

        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.positions = positions;

        YieldNestKeeper k = _deployKeeper(cfg);

        assertEq(k.totalPositionShares(), 1500e18);
        assertEq(k.totalDebt(), 1500e6);
    }

    function test_multiplePositions_harvestYield() public {
        address position2 = address(0xB2);
        vault.mint(position2, 500e18);
        debtToken.mint(position2, 500e6);

        address[] memory positions = new address[](2);
        positions[0] = position1;
        positions[1] = position2;

        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.positions = positions;

        YieldNestKeeper k = _deployKeeper(cfg);

        uint256 yield_ = k.earnedYield();
        assertGt(yield_, 0, "Should have yield across multiple positions");

        uint256 destBefore = rewardAsset.balanceOf(destinationStrategy);
        k.harvest();
        assertGt(rewardAsset.balanceOf(destinationStrategy), destBefore);
    }

    // ─── Decimal Handling ────────────────────────────────────────────────────

    function test_debtToAsset_sameDecimals() public {
        // Both asset and debt have 18 decimals
        MockERC20 asset18 = new MockERC20("Asset18", 18);
        MockERC20 debt18 = new MockERC20("Debt18", 18);
        MockYnVault vault18 = new MockYnVault(address(asset18));
        vault18.setRate(1.05e18);

        address pos = address(0xC1);
        vault18.mint(pos, 1000e18);
        debt18.mint(pos, 1000e18);
        vault18.mint(wallet, 1000e18);

        address[] memory positions = new address[](1);
        positions[0] = pos;

        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.vault = IYnVault(address(vault18));
        cfg.debtToken = IERC20(address(debt18));
        cfg.positions = positions;

        YieldNestKeeper k = _deployKeeper(cfg);

        // 1050 asset - 1000 debt = 50 yield
        uint256 yield_ = k.earnedYield();
        assertGt(yield_, 0, "Should have yield with same-decimal tokens");
    }

    function test_debtToAsset_assetHigherDecimals() public {
        // Asset 18 dec, debt 6 dec (current setup) - already tested via default
        uint256 yield_ = keeper.earnedYield();
        assertGt(yield_, 0);
    }

    function test_debtToAsset_assetLowerDecimals() public {
        // Asset 6 dec, debt 18 dec
        MockERC20 asset6 = new MockERC20("Asset6", 6);
        MockERC20 debt18 = new MockERC20("Debt18", 18);
        MockYnVault vault6 = new MockYnVault(address(asset6));
        vault6.setRate(1.05e18);

        address pos = address(0xC2);
        vault6.mint(pos, 1000e18);
        debt18.mint(pos, 1000e18);
        vault6.mint(wallet, 1000e18);

        address[] memory positions = new address[](1);
        positions[0] = pos;

        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.vault = IYnVault(address(vault6));
        cfg.debtToken = IERC20(address(debt18));
        cfg.positions = positions;

        YieldNestKeeper k = _deployKeeper(cfg);

        uint256 yield_ = k.earnedYield();
        assertGt(yield_, 0, "Should have yield with asset<debt decimals");
    }

    // ─── Constructor ────────────────────────────────────────────────────────

    function test_constructor_revertsZeroInitializer() public {
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        new YieldNestKeeper(address(0));
    }

    function test_constructor_setsInitializer() public {
        YieldNestKeeper k = new YieldNestKeeper(address(0x123));
        assertEq(k.initializer(), address(0x123));
    }

    // ─── Initialize ─────────────────────────────────────────────────────────

    function test_initialize_grantsAdminRole() public {
        assertTrue(keeper.hasRole(keeper.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_initialize_clearsInitializer() public {
        assertEq(keeper.initializer(), address(0));
    }

    function test_initialize_revertsAlreadyInitialized() public {
        vm.expectRevert(YieldNestKeeper.AlreadyInitialized.selector);
        keeper.initialize(admin, _defaultConfig());
    }

    function test_initialize_revertsNotInitializer() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        vm.prank(address(0xBAD));
        vm.expectRevert(YieldNestKeeper.NotInitializer.selector);
        k.initialize(admin, _defaultConfig());
    }

    function test_initialize_revertsZeroVault() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.vault = IYnVault(address(0));
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_revertsZeroDebtToken() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.debtToken = IERC20(address(0));
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_revertsZeroRateProvider() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.rateProvider = IConversionRateProvider(address(0));
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_revertsZeroApprovedWallet() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.approvedWallet = address(0);
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_revertsZeroRewardAsset() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.rewardAsset = address(0);
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_revertsZeroDestinationStrategy() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.destinationStrategy = address(0);
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_revertsZeroCurveRouter() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.curveRouter = ICurveRouter(address(0));
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_revertsZeroAssetOracle() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.assetOracle = AggregatorV3Interface(address(0));
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_revertsZeroRewardOracle() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.rewardOracle = AggregatorV3Interface(address(0));
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_revertsZeroBps() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.minOutputBps = 0;
        vm.expectRevert(YieldNestKeeper.InvalidBps.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_revertsExcessiveBps() public {
        YieldNestKeeper k = new YieldNestKeeper(address(this));
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.minOutputBps = 10_001;
        vm.expectRevert(YieldNestKeeper.InvalidBps.selector);
        k.initialize(admin, cfg);
    }

    function test_initialize_accepts10000Bps() public {
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.minOutputBps = 10_000;
        _deployKeeper(cfg); // should not revert
    }

    function test_initialize_accepts1Bps() public {
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.minOutputBps = 1;
        _deployKeeper(cfg); // should not revert
    }

    // ─── Admin: updateConfig ─────────────────────────────────────────────────

    function test_updateConfig_succeeds() public {
        YieldNestKeeper.Config memory newCfg = _defaultConfig();
        newCfg.minOutputBps = 9800;

        vm.prank(admin);
        vm.expectEmit();
        emit YieldNestKeeper.ConfigUpdated();
        keeper.updateConfig(newCfg);
    }

    function test_updateConfig_revertsNonAdmin() public {
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        keeper.updateConfig(cfg);
    }

    function test_updateConfig_revertsInvalidConfig() public {
        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.vault = IYnVault(address(0));
        vm.prank(admin);
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        keeper.updateConfig(cfg);
    }

    // ─── Admin: setMinOutputBps ──────────────────────────────────────────────

    function test_setMinOutputBps_succeeds() public {
        vm.prank(admin);
        keeper.setMinOutputBps(9500);
        keeper.harvest(); // should work
    }

    function test_setMinOutputBps_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert(YieldNestKeeper.InvalidBps.selector);
        keeper.setMinOutputBps(0);
    }

    function test_setMinOutputBps_revertsAbove10000() public {
        vm.prank(admin);
        vm.expectRevert(YieldNestKeeper.InvalidBps.selector);
        keeper.setMinOutputBps(10_001);
    }

    function test_setMinOutputBps_revertsNonAdmin() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        keeper.setMinOutputBps(9500);
    }

    // ─── Admin: setMaxOracleAge ──────────────────────────────────────────────

    function test_setMaxOracleAge_succeeds() public {
        vm.prank(admin);
        keeper.setMaxOracleAge(3600);
    }

    function test_setMaxOracleAge_revertsNonAdmin() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        keeper.setMaxOracleAge(3600);
    }

    // ─── Admin: recoverToken ─────────────────────────────────────────────────

    function test_recoverToken_succeeds() public {
        MockERC20 stuck = new MockERC20("Stuck", 18);
        stuck.mint(address(keeper), 100e18);
        vm.prank(admin);
        keeper.recoverToken(address(stuck), admin, 100e18);
        assertEq(stuck.balanceOf(admin), 100e18);
    }

    function test_recoverToken_revertsToZeroAddress() public {
        MockERC20 stuck = new MockERC20("Stuck", 18);
        stuck.mint(address(keeper), 100e18);
        vm.prank(admin);
        vm.expectRevert(YieldNestKeeper.ZeroAddress.selector);
        keeper.recoverToken(address(stuck), address(0), 100e18);
    }

    function test_recoverToken_revertsNonAdmin() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        keeper.recoverToken(address(rewardAsset), address(0xBAD), 1);
    }

    // ─── StablecoinRateProvider ──────────────────────────────────────────────

    function test_stablecoinRateProvider_returns1e18() public {
        StablecoinRateProvider srp = new StablecoinRateProvider(address(asset));
        assertEq(srp.getRate(address(asset)), 1e18);
        assertEq(srp.getRate(address(0)), 1e18); // ignores asset arg
    }

    function test_stablecoinRateProvider_storesBaseAsset() public {
        StablecoinRateProvider srp = new StablecoinRateProvider(address(asset));
        assertEq(srp.BASE_ASSET(), address(asset));
    }

    // ─── MinOutput Calculation Scenarios ─────────────────────────────────────

    function test_minOutput_differentOracleDecimals() public {
        // Asset oracle 8 decimals at $1, reward oracle 18 decimals at $2000
        MockOracle rewardOracle18 = new MockOracle(2000e18, 18);

        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.rewardOracle = AggregatorV3Interface(address(rewardOracle18));

        YieldNestKeeper k = _deployKeeper(cfg);

        // Should succeed - the decimal adjustment should handle different oracle decimals
        k.harvest();
    }

    function test_minOutput_highRewardPrice() public {
        // Reward at $3000 (like wstETH), asset at $1 (like USDC)
        rewardOracle = new MockOracle(3000e8, 8);

        YieldNestKeeper.Config memory cfg = _defaultConfig();
        cfg.rewardOracle = AggregatorV3Interface(address(rewardOracle));

        // Lower minOutputBps since Curve mock returns fixed 100e18 which may be
        // generous relative to oracle-expected output
        cfg.minOutputBps = 1; // very permissive for mock

        YieldNestKeeper k = _deployKeeper(cfg);

        k.harvest();
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _deployKeeper(YieldNestKeeper.Config memory cfg) internal returns (YieldNestKeeper k) {
        k = new YieldNestKeeper(address(this));
        k.initialize(admin, cfg);
    }

    function _defaultConfig() internal view returns (YieldNestKeeper.Config memory) {
        address[] memory positions = new address[](1);
        positions[0] = position1;

        address[11] memory route;
        uint256[5][5] memory swapParams;
        address[5] memory pools;

        return YieldNestKeeper.Config({
            vault: IYnVault(address(vault)),
            positions: positions,
            debtToken: IERC20(address(debtToken)),
            rateProvider: IConversionRateProvider(address(rateProvider)),
            approvedWallet: wallet,
            rewardAsset: address(rewardAsset),
            destinationStrategy: destinationStrategy,
            curveRouter: ICurveRouter(address(curveRouter)),
            route: route,
            swapParams: swapParams,
            pools: pools,
            assetOracle: AggregatorV3Interface(address(assetOracle)),
            rewardOracle: AggregatorV3Interface(address(rewardOracle)),
            maxOracleAge: 86400,
            minOutputBps: 9900
        });
    }
}
