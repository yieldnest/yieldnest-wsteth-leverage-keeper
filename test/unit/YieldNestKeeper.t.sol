// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YieldNestKeeper} from "src/YieldNestKeeper.sol";
import {IYnVault} from "src/interfaces/IYnVault.sol";
import {IConversionRateProvider} from "src/interfaces/IConversionRateProvider.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockYnRWAx is IERC20 {
    address public asset_;
    mapping(address => uint256) public override balanceOf;
    uint256 public override totalSupply;
    uint256 public rate; // assets per share, scaled by 1e18

    constructor(address _asset) {
        asset_ = _asset;
        rate = 1.05e18; // 5% yield
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

    function getRate() external view override returns (uint256) {
        return rate;
    }
}

contract MockOracle is AggregatorV3Interface {
    int256 public price;
    uint8 public override decimals;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimals = _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
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

contract YieldNestKeeperTest is Test {
    YieldNestKeeper public keeper;
    MockYnRWAx public ynRWAx;
    MockERC20 public asset; // underlying asset of ynRWAx
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
        // Deploy mocks
        asset = new MockERC20("Asset", 18);
        debtToken = new MockERC20("DebtToken", 6);
        rewardAsset = new MockERC20("Reward", 18);
        ynRWAx = new MockYnRWAx(address(asset));
        // 1 asset = 1e18 debt tokens (1:1 rate, scaled by 1e18)
        rateProvider = new MockRateProvider(1e18);
        assetOracle = new MockOracle(1e8, 8); // $1 with 8 decimals
        rewardOracle = new MockOracle(1e8, 8); // $1 with 8 decimals
        curveRouter = new MockCurveRouter(address(asset), address(rewardAsset), 100e18);

        // Set up position: give position1 some ynRWAx and some debt
        ynRWAx.mint(position1, 1000e18);
        // With 1.05x rate, 1000 ynRWAx = 1050 asset. Give 1000 debt.
        // Yield = 1050 - 1000 = 50 asset = ~47.6 ynRWAx shares
        debtToken.mint(position1, 1000e6); // debtToken has 6 decimals

        // Give the wallet ynRWAx to be pulled
        ynRWAx.mint(wallet, 1000e18);

        address[] memory positions = new address[](1);
        positions[0] = position1;

        address[11] memory route;
        uint256[5][5] memory swapParams;
        address[5] memory pools;

        YieldNestKeeper.Config memory config = YieldNestKeeper.Config({
            vault: IYnVault(address(ynRWAx)),
            positions: positions,
            debtToken: IERC20(address(debtToken)),
            rateProvider: IConversionRateProvider(address(rateProvider)),
            approvedWallet: wallet,
            rewardAsset: address(rewardAsset),
            destinationStrategy: destinationStrategy,
            curveRouter: address(curveRouter),
            route: route,
            swapParams: swapParams,
            pools: pools,
            assetOracle: AggregatorV3Interface(address(assetOracle)),
            rewardOracle: AggregatorV3Interface(address(rewardOracle)),
            maxOracleAge: 86400,
            minOutputBps: 9900
        });

        keeper = new YieldNestKeeper(admin, config);

        vm.prank(admin);
        keeper.grantRole(keccak256("HARVESTER_ROLE"), address(this));
    }

    function test_harvest_succeeds() public {
        uint256 destBefore = rewardAsset.balanceOf(destinationStrategy);
        keeper.harvest();
        uint256 destAfter = rewardAsset.balanceOf(destinationStrategy);
        assertGt(destAfter, destBefore, "Destination should have received reward tokens");
    }

    function test_harvest_noYield_reverts() public {
        // Position has 1000 ynRWAx at 1.05x = 1050e18 asset value.
        // Debt is 1000e6 (6 decimals), with rate 1e18 and decimal normalization = 1000e18 asset.
        // So yield = 50e18. To make it revert, we need debt >= position value.
        // Mint enough debt to exceed 1050 asset (in 6 decimal terms = 1050e6 additional).
        debtToken.mint(position1, 1050e6);
        vm.expectRevert(YieldNestKeeper.NoYieldToHarvest.selector);
        keeper.harvest();
    }

    function test_earnedYield_view() public view {
        uint256 yield_ = keeper.earnedYield();
        assertGt(yield_, 0, "Should report yield");
    }

    function test_totalPositionShares() public view {
        uint256 shares = keeper.totalPositionShares();
        assertEq(shares, 1000e18, "Total position shares should be 1000e18");
    }

    function test_harvest_reverts_without_role() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        keeper.harvest();
    }

    function test_setMinOutputBps() public {
        vm.prank(admin);
        keeper.setMinOutputBps(9500);
        // Verify by calling harvest successfully (would revert if config broken)
        keeper.harvest();
    }

    function test_recoverToken() public {
        MockERC20 stuckToken = new MockERC20("Stuck", 18);
        stuckToken.mint(address(keeper), 100e18);
        vm.prank(admin);
        keeper.recoverToken(address(stuckToken), admin, 100e18);
        assertEq(stuckToken.balanceOf(admin), 100e18);
    }
}
