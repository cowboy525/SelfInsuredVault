// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";

import { ControllerHelper } from "y2k-earthquake/test/ControllerHelper.sol";
import { Vault } from "y2k-earthquake/src/Vault.sol";
import { VaultFactory, TimeLock} from "y2k-earthquake/src/VaultFactory.sol";
import { Controller } from "y2k-earthquake/src/Controller.sol"; 
import { FakeOracle } from "y2k-earthquake/test/oracles/FakeOracle.sol";

import { BaseTest } from "./BaseTest.sol";
import { BaseTest as DLXBaseTest } from "dlx/test/BaseTest.sol";
import { FakeYieldSource as DLXFakeYieldSource } from "dlx/test/helpers/FakeYieldSource.sol";
import { FakeYieldSource as FakeYieldSource3 } from "./helpers/FakeYieldSource3.sol";
import { FakeYieldTracker } from "./helpers/FakeYieldTracker.sol";
import { FakeYieldOracle } from "./helpers/FakeYieldOracle.sol";

import { IWrappedETH } from "../src/interfaces/IWrappedETH.sol";
import { IRewardTracker } from "../src/interfaces/gmx/IRewardTracker.sol";
import { IInsuranceProvider } from "../src/interfaces/IInsuranceProvider.sol";
import { SelfInsuredVault } from "../src/vaults/SelfInsuredVault.sol";
import { Y2KEarthquakeV1InsuranceProvider } from "../src/providers/Y2KEarthquakeV1InsuranceProvider.sol";

// Delorean imports

import { UniswapV3LiquidityPool } from "dlx/src/liquidity/UniswapV3LiquidityPool.sol";
import { IUniswapV3Pool } from "dlx/src/interfaces/uniswap/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from "dlx/src/interfaces/uniswap/INonfungiblePositionManager.sol";
import { IUniswapV3Factory } from "dlx/src/interfaces/uniswap/IUniswapV3Factory.sol";
import { NPVToken } from "dlx/src/tokens/NPVToken.sol";
import { YieldSlice } from "dlx/src/core/YieldSlice.sol";
import { NPVSwap } from  "dlx/src/core/NPVSwap.sol";
import { Discounter } from "dlx/src/data/Discounter.sol";
import { YieldData } from "dlx/src/data/YieldData.sol";

/* contract SelfInsuredVaultTest is BaseTest, DLXBaseTest, ControllerHelper { */
contract SelfInsuredVaultTest is BaseTest, ControllerHelper {
    // From https://docs.uniswap.org/contracts/v3/reference/deployments
    address public arbitrumUniswapV3Factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public arbitrumNonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public arbitrumSwapRouter = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public arbitrumQuoterV2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address public arbitrumWeth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    NPVToken public npvToken;
    NPVSwap public npvSwap;
    YieldSlice public slice;
    YieldData public dataDebt;
    YieldData public dataCredit;
    Discounter public discounter;

    IERC20 public generatorToken;
    IERC20 public yieldToken;

    UniswapV3LiquidityPool public pool;
    IUniswapV3Pool public uniswapV3Pool;
    INonfungiblePositionManager public manager;

    address glpWallet = 0x3aaF2aCA2a0A6b6ec227Bbc2bF5cEE86c2dC599d;

    IRewardTracker public gmxRewardsTracker = IRewardTracker(0x4e971a87900b931fF39d1Aad67697F49835400b6);

    function epochPayout(SelfInsuredVault vault, address provider, uint256 index) internal view returns (uint256) {
        ( , , uint256 payout, ) = vault.providerEpochs(provider, index);
        return payout;
    }

    function testYieldAccounting() public {
        vm.selectFork(vm.createFork(ARBITRUM_RPC_URL));

        uint256 wethAmount = 1000000e18;
        vm.deal(address(this), wethAmount);
        IWrappedETH(WETH).deposit{value: wethAmount}();
        FakeYieldSource3 source = new FakeYieldSource3(200, WETH);
        IERC20(WETH).transfer(address(source), wethAmount);

        /* DLXFakeYieldSource source = new DLXFakeYieldSource(200); */
        FakeYieldOracle oracle = new FakeYieldOracle(address(source.generatorToken()),
                                                     address(source.yieldToken()),
                                                     200,
                                                     18);

        // TODO: fix import namespacing
        address gtA = address(source.generatorToken());
        address ytA = address(source.yieldToken());
        IERC20 gt = IERC20(gtA);
        IERC20 yt = IERC20(ytA);

        SelfInsuredVault vault = new SelfInsuredVault("Self Insured YS:G Vault",
                                                      "siYS:G",
                                                      address(source.yieldToken()),
                                                      address(source),
                                                      address(oracle),
                                                      address(0));
        source.setOwner(address(vault));

        uint256 before;
        address user0 = createTestUser(0);
        source.mintGenerator(user0, 10e18);

        vm.startPrank(user0);

        // Set balance to 0 WETH for user0
        IERC20(WETH).transfer(address(source), IERC20(WETH).balanceOf(user0));

        IERC20(gt).approve(address(vault), 2e18);
        assertEq(vault.previewDeposit(2e18), 2e18);
        vault.deposit(2e18, user0);
        assertEq(IERC20(gt).balanceOf(user0), 8e18);
        assertEq(IERC20(gt).balanceOf(address(vault)), 0);
        assertEq(IERC20(gt).balanceOf(address(source)), 2e18);
        assertEq(vault.balanceOf(user0), 2e18);
        vm.stopPrank();

        assertEq(vault.cumulativeYield(), 0);

        // Verify yield accounting with one user
        vm.roll(block.number + 1);
        assertEq(vault.cumulativeYield(), 400e18);
        assertEq(vault.calculatePendingYield(user0), 400e18);
        assertEq(IERC20(yt).balanceOf(address(vault)), 0);
        assertEq(IERC20(yt).balanceOf(user0), 0);

        vm.prank(user0);
        vault.claimRewards();

        assertEq(IERC20(yt).balanceOf(address(vault)), 0);
        assertEq(IERC20(yt).balanceOf(user0), 400e18);

        vm.prank(user0);
        vault.claimRewards();
        assertEq(IERC20(yt).balanceOf(address(vault)), 0);
        assertEq(IERC20(yt).balanceOf(user0), 400e18);

        // Advance multiple blocks
        vm.roll(block.number + 2);
        assertEq(vault.cumulativeYield(), 1200e18);
        assertEq(vault.calculatePendingYield(user0), 800e18);

        vm.roll(block.number + 3);
        assertEq(vault.cumulativeYield(), 2400e18);
        assertEq(vault.calculatePendingYield(user0), 2000e18);

        assertEq(IERC20(yt).balanceOf(address(vault)), 0);
        assertEq(IERC20(yt).balanceOf(user0), 400e18);

        vm.prank(user0);
        vault.claimRewards();
        assertEq(IERC20(yt).balanceOf(address(vault)), 0);
        assertEq(IERC20(yt).balanceOf(user0), 2400e18);

        // Advance multiple blocks, change yield rate, advance more blocks
        vm.roll(block.number + 2);
        assertEq(vault.cumulativeYield(), 3200e18);
        assertEq(vault.calculatePendingYield(user0), 800e18);

        before = source.amountPending();
        source.setYieldPerBlock(100);
        assertEq(source.amountPending(), before);

        vm.roll(block.number + 1);
        assertEq(vault.cumulativeYield(), 3400e18);
        assertEq(vault.calculatePendingYield(user0), 1000e18);

        vm.roll(block.number + 2);
        assertEq(vault.cumulativeYield(), 3800e18);
        assertEq(vault.calculatePendingYield(user0), 1400e18);

        vm.prank(user0);
        vault.claimRewards();
        assertEq(vault.cumulativeYield(), 3800e18);
        assertEq(vault.calculatePendingYield(user0), 0);
        assertEq(IERC20(yt).balanceOf(address(vault)), 0);
        assertEq(IERC20(yt).balanceOf(user0), 3800e18);

        // Add a second user
        address user1 = createTestUser(1);

        source.mintGenerator(user1, 20e18);
        assertEq(vault.calculatePendingYield(user0), 0);
        assertEq(vault.calculatePendingYield(user1), 0);

        vm.roll(block.number + 1);
        assertEq(vault.calculatePendingYield(user0), 200e18);
        assertEq(vault.calculatePendingYield(user1), 0);

        // Second user deposits
        vm.startPrank(user1);

        // Set balance to 0 WETH for user1
        IERC20(WETH).transfer(address(source), IERC20(WETH).balanceOf(user1));

        IERC20(gt).approve(address(vault), 4e18);
        assertEq(vault.previewDeposit(4e18), 4e18);

        before = vault.cumulativeYield();

        vault.deposit(4e18, user1);
        assertEq(vault.cumulativeYield(), before);
        assertEq(IERC20(gt).balanceOf(user0), 8e18);
        assertEq(IERC20(gt).balanceOf(user1), 16e18);
        assertEq(IERC20(gt).balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(user0), 2e18);
        assertEq(vault.balanceOf(user1), 4e18);
        assertEq(vault.totalAssets(), 6e18);
        vm.stopPrank();

        vm.roll(block.number + 1);
        assertEq(vault.calculatePendingYield(user0), 400e18);
        assertEq(vault.calculatePendingYield(user1), 400e18);

        vm.roll(block.number + 1);
        assertEq(vault.calculatePendingYield(user0), 600e18);
        assertEq(vault.calculatePendingYield(user1), 800e18);

        vm.roll(block.number + 2);
        assertEq(vault.calculatePendingYield(user0), 1000e18);
        assertEq(vault.calculatePendingYield(user1), 1600e18);

        vm.prank(user0);
        vault.claimRewards();
        assertEq(vault.calculatePendingYield(user0), 0);
        assertEq(yt.balanceOf(user0), 4800e18);

        vm.prank(user1);
        vault.claimRewards();
        assertEq(vault.calculatePendingYield(user1), 0);
        assertEq(yt.balanceOf(user1), 1600e18);

        // Third user deposits, advance some blocks, change yield rate, users claim on different blocks
        address user2 = createTestUser(2);
        source.mintGenerator(user2, 20e18);
        vm.startPrank(user2);

        // Set balance to 0 WETH for user2
        IERC20(WETH).transfer(address(source), IERC20(WETH).balanceOf(user2));

        gt.approve(address(vault), 8e18);
        assertEq(vault.previewDeposit(8e18), 8e18);
        before = vault.cumulativeYield();
        vault.deposit(8e18, user2);
        assertEq(vault.cumulativeYield(), before);
        assertEq(gt.balanceOf(user0), 8e18);
        assertEq(gt.balanceOf(user1), 16e18);
        assertEq(gt.balanceOf(user2), 12e18);
        assertEq(gt.balanceOf(address(source)), 14e18);
        assertEq(vault.balanceOf(user0), 2e18);
        assertEq(vault.balanceOf(user1), 4e18);
        assertEq(vault.balanceOf(user2), 8e18);
        assertEq(vault.totalAssets(), 14e18);
        vm.stopPrank();

        vm.roll(block.number + 1);
        assertEq(vault.calculatePendingYield(user0), 200e18);
        assertEq(vault.calculatePendingYield(user1), 400e18);
        assertEq(vault.calculatePendingYield(user2), 800e18);

        vm.roll(block.number + 1);
        assertEq(vault.calculatePendingYield(user0), 400e18);
        assertEq(vault.calculatePendingYield(user1), 800e18);
        assertEq(vault.calculatePendingYield(user2), 1600e18);

        source.setYieldPerBlock(300);

        vm.roll(block.number + 1);
        assertEq(vault.calculatePendingYield(user0), 1000e18);
        assertEq(vault.calculatePendingYield(user1), 2000e18);
        assertEq(vault.calculatePendingYield(user2), 4000e18);

        vm.prank(user1);
        vault.claimRewards();
        assertEq(vault.calculatePendingYield(user0), 1000e18);
        assertEq(vault.calculatePendingYield(user1), 0);
        assertEq(vault.calculatePendingYield(user2), 4000e18);
        assertEq(yt.balanceOf(user0), 4800e18);
        assertEq(yt.balanceOf(user1), 3600e18);
        assertEq(yt.balanceOf(user2), 0);

        vm.roll(block.number + 1);
        assertEq(vault.calculatePendingYield(user0), 1600e18);
        assertEq(vault.calculatePendingYield(user1), 1200e18);
        assertEq(vault.calculatePendingYield(user2), 6400e18);

        vm.prank(user2);
        vault.claimRewards();
        assertEq(vault.calculatePendingYield(user0), 1600e18);
        assertEq(vault.calculatePendingYield(user1), 1200e18);
        assertEq(vault.calculatePendingYield(user2), 0);
        assertEq(yt.balanceOf(user0), 4800e18);
        assertEq(yt.balanceOf(user1), 3600e18);
        assertEq(yt.balanceOf(user2), 6400e18);

        vm.prank(user0);
        vault.claimRewards();
        vm.prank(user1);
        vault.claimRewards();
        assertEq(vault.calculatePendingYield(user0), 0);
        assertEq(vault.calculatePendingYield(user1), 0);
        assertEq(vault.calculatePendingYield(user2), 0);
        assertEq(yt.balanceOf(user0), 6400e18);
        assertEq(yt.balanceOf(user1), 4800e18);
        assertEq(yt.balanceOf(user2), 6400e18);
    }

    function testDepegYieldAccounting() public {
        depositDepeg();

        FakeYieldSource3 source = new FakeYieldSource3(200, WETH);
        FakeYieldOracle oracle = new FakeYieldOracle(address(source.generatorToken()),
                                                     address(source.yieldToken()),
                                                     200,
                                                     18);

        IERC20 gt = IERC20(source.generatorToken());
        IERC20 yt = IERC20(source.yieldToken());
        vm.startPrank(ADMIN);
        SelfInsuredVault vault = new SelfInsuredVault("Self Insured YS:G Vault",
                                                      "siYS:G",
                                                      address(source.yieldToken()),
                                                      address(source),
                                                      address(oracle),
                                                      address(0));

        // Set up Y2K insurance vault
        vaultFactory.createNewMarket(FEE, TOKEN_FRAX, DEPEG_AAA, beginEpoch, endEpoch, ORACLE_FRAX, "y2kFRAX_99*");

        hedge = vaultFactory.getVaults(1)[0];
        risk = vaultFactory.getVaults(1)[1];

        vHedge = Vault(hedge);
        vRisk = Vault(risk);

        // Set up the insurance provider
        Y2KEarthquakeV1InsuranceProvider provider;
        provider = new Y2KEarthquakeV1InsuranceProvider(address(vHedge), address(vault));

        // Set the insurance provider at 10% of expected yield
        vault.addInsuranceProvider(IInsuranceProvider(provider), 10_00);
        vm.stopPrank();  // ADMIN

        // Alice deposits into self insured vault
        source.mintGenerator(ALICE, 10e18);

        vm.startPrank(ALICE);
        gt.approve(address(vault), 2e18);
        assertEq(vault.previewDeposit(2e18), 2e18);
        vault.deposit(2e18, ALICE);

        {
            (uint256 epochId, uint256 totalShares, , ) = vault.providerEpochs(address(provider), 0);
            assertEq(totalShares, 2e18);

            (uint256 startEpochId,
             uint256 shares,
             uint256 nextEpochId,
             uint256 nextShares,
             uint256 accumulatedPayouts,
             uint256 claimedPayouts) = vault.userEpochTrackers(ALICE);
            assertEq(startEpochId, 0);
            assertEq(shares, 0);
            assertEq(nextEpochId, epochId);
            assertEq(nextShares, 2e18);
            assertEq(accumulatedPayouts, 0);
            assertEq(claimedPayouts, 0);
        }

        gt.approve(address(vault), 1e18);
        vault.deposit(1e18, ALICE);
        {
            (uint256 epochId, uint256 totalShares, , ) = vault.providerEpochs(address(provider), 0);
            assertEq(totalShares, 3e18);

            (uint256 startEpochId,
             uint256 shares,
             uint256 nextEpochId,
             uint256 nextShares,
             uint256 accumulatedPayouts,
             uint256 claimedPayouts) = vault.userEpochTrackers(ALICE);
            assertEq(startEpochId, 0);
            assertEq(shares, 0);
            assertEq(nextEpochId, epochId);
            assertEq(nextShares, 3e18);
            assertEq(accumulatedPayouts, 0);
            assertEq(claimedPayouts, 0);
        }

        vm.stopPrank();

        // Move ahead to next epoch, end it
        vm.warp(beginEpoch + 10 days);
        vm.startPrank(vHedge.controller());
        vHedge.endEpoch(provider.currentEpoch());
        vm.stopPrank();

        // Create two more epochs
        vm.startPrank(vHedge.factory());
        vHedge.createAssets(endEpoch, endEpoch + 1 days, 5);
        vm.stopPrank();

        vm.startPrank(vHedge.factory());
        vHedge.createAssets(endEpoch + 1 days, endEpoch + 2 days, 5);
        vm.stopPrank();

        // Move into the first epoch, with one more created epoch available after it
        vm.warp(endEpoch + 10 minutes);
        vm.startPrank(vHedge.controller());
        vm.stopPrank();

        // Alice deposits more shares
        vm.startPrank(ALICE);
        gt.approve(address(vault), 3e18);

        console.log("");
        console.log("==> Make another deposit");
        console.log("");

        vault.deposit(3e18, ALICE);
        vm.stopPrank();

        vault.pprintEpochs();

        {
            (uint256 epochId0, uint256 totalShares0, , ) = vault.providerEpochs(address(provider), 0);
            assertEq(totalShares0, 3e18);
            (uint256 epochId1, uint256 totalShares1, , ) = vault.providerEpochs(address(provider), 1);
            assertEq(totalShares1, 3e18);
            (uint256 epochId2, uint256 totalShares2, , ) = vault.providerEpochs(address(provider), 2);
            assertEq(totalShares2, 6e18);

            (uint256 startEpochId,
             uint256 shares,
             uint256 nextEpochId,
             uint256 nextShares,
             uint256 accumulatedPayouts,
             uint256 claimedPayouts) = vault.userEpochTrackers(ALICE);

            assertEq(startEpochId, epochId0);
            assertEq(nextEpochId, epochId2);
            assertEq(shares, 3e18);
            assertEq(nextShares, 6e18);
            assertEq(accumulatedPayouts, 0);
            assertEq(claimedPayouts, 0);
        }

        // TODO: finish this test, or delete it as it is covered by the one below
    }

    function testPurchaseWithDLXFutureYield() public {
        // Send lots of WETH to vaultSource
        uint256 wethAmount = 1000000e18;
        vm.deal(address(this), wethAmount);
        IWrappedETH(WETH).deposit{value: wethAmount}();

        FakeYieldSource3 vaultSource = new FakeYieldSource3(200, WETH);
        IERC20(WETH).transfer(address(vaultSource), wethAmount);

        FakeYieldOracle oracle = new FakeYieldOracle(address(vaultSource.generatorToken()),
                                                     address(vaultSource.yieldToken()),
                                                     200,
                                                     18);
        generatorToken = IERC20(vaultSource.generatorToken());
        yieldToken = IERC20(vaultSource.yieldToken());
        vaultSource.mintBoth(ALICE, 10e18);

        vm.startPrank(ADMIN);
        fakeOracle = new FakeOracle(ORACLE_FRAX, STRIKE_PRICE_FAKE_ORACLE);
        vaultFactory.createNewMarket(FEE, TOKEN_FRAX, DEPEG_AAA, beginEpoch, endEpoch, address(fakeOracle), "y2kFRAX_99*");
        vm.stopPrank();
        hedge = vaultFactory.getVaults(1)[0];
        risk = vaultFactory.getVaults(1)[1];
        vHedge = Vault(hedge);
        vRisk = Vault(risk);

        // TODO: Consolidate this setup code
        // -- Set up Delorean market --/
        YieldData dataDebt = new YieldData(20);
        YieldData dataCredit = new YieldData(20);
        Discounter discounter = new Discounter(1e13, 500, 360, 18);

        FakeYieldSource3 dlxSource = vaultSource;
        slice = new YieldSlice("npvETH-FAKE",
                               address(dlxSource),
                               address(dataDebt),
                               address(dataCredit),
                               address(discounter),
                               1e18);
        slice.setDebtFee(10_0);
        slice.setCreditFee(10_0);

        dlxSource.setOwner(address(slice));
        dataDebt.setWriter(address(slice));
        dataCredit.setWriter(address(slice));

        dlxSource.mintBoth(ALICE, 1000e18);

        npvToken = slice.npvToken();

        // Uniswap V3 setup for Delorean
        manager = INonfungiblePositionManager(arbitrumNonfungiblePositionManager);
        (address token0, address token1) = address(npvToken) < address(yieldToken)
            ? (address(npvToken), address(yieldToken))
            : (address(yieldToken), address(npvToken));
        uniswapV3Pool = IUniswapV3Pool(IUniswapV3Factory(arbitrumUniswapV3Factory).getPool(token0, token1, 3000));
        if (address(uniswapV3Pool) == address(0)) {
            uniswapV3Pool = IUniswapV3Pool(IUniswapV3Factory(arbitrumUniswapV3Factory).createPool(token0, token1, 3000));
            IUniswapV3Pool(uniswapV3Pool).initialize(79228162514264337593543950336);
        }
        pool = new UniswapV3LiquidityPool(address(uniswapV3Pool), arbitrumSwapRouter, arbitrumQuoterV2);
        npvSwap = new NPVSwap(address(npvToken), address(slice), address(pool));
        console.log("made the swap:", address(npvSwap));

        // Add liquidity
        vm.startPrank(ALICE);
        generatorToken.approve(address(npvSwap), 1000e18);
        npvSwap.lockForNPV(ALICE, ALICE, 1000e18, 10e18, new bytes(0));
        uint256 token0Amount = 1e18;
        uint256 token1Amount = 1e18;
        dlxSource.mintGenerator(ALICE, 1e18);
        dlxSource.mintYield(ALICE, 1e18);
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: uniswapV3Pool.token0(),
            token1: uniswapV3Pool.token1(),
            fee: 3000,
            tickLower: -180,
            tickUpper: 180,
            amount0Desired: token0Amount,
            amount1Desired: token1Amount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: ALICE,
            deadline: block.timestamp + 1 });
        assertEq(uniswapV3Pool.liquidity(), 0);
        IERC20(params.token0).approve(address(manager), token0Amount);
        IERC20(params.token1).approve(address(manager), token1Amount);
        manager.mint(params);
        assertTrue(uniswapV3Pool.liquidity() > 0);
        vm.stopPrank();

        // -- Delorean setup complete -- //

        vm.startPrank(ADMIN);
        SelfInsuredVault vault = new SelfInsuredVault("Self Insured YS:G Vault",
                                                      "siYS:G",
                                                      address(vaultSource.yieldToken()),
                                                      address(vaultSource),
                                                      address(oracle),
                                                      address(npvSwap));
        vm.stopPrank();

        // Set up the insurance provider
        Y2KEarthquakeV1InsuranceProvider provider = new Y2KEarthquakeV1InsuranceProvider(address(vHedge),
                                                                                         address(vault));

        // Bob buys the risk
        vm.startPrank(BOB);
        vm.deal(BOB, 200 ether);
        IWrappedETH(WETH).deposit{value: 200 ether}();
        IERC20(WETH).approve(address(vRisk), 200e18);
        vRisk.deposit(endEpoch, 200e18, BOB);
        vm.stopPrank();

        // Set the insurance provider at 10% of expected yield
        vm.startPrank(ADMIN);
        vault.addInsuranceProvider(IInsuranceProvider(provider), 0);
        vault.setWeight(0, 10_00);
        vm.stopPrank();

        // Deposit into the vault
        vm.startPrank(ALICE);
        generatorToken.approve(address(vault), 2e18);
        vault.deposit(2e18, ALICE);
        vm.stopPrank();

        vm.prank(ADMIN);
        vault.purchaseInsuranceForNextEpoch(99_00);

        // Trigger a depeg
        vm.warp(beginEpoch + 10 days);
        assertEq(epochPayout(vault, address(provider), 0), 0);
        controller.triggerDepeg(SINGLE_MARKET_INDEX, endEpoch);

        vault.claimInsurancePayouts();

        assertTrue(IERC20(WETH).balanceOf(address(vault)) > 199e18);
        assertTrue(IERC20(WETH).balanceOf(address(vault)) >= epochPayout(vault, address(provider), 0));
        assertEq(IERC20(WETH).balanceOf(address(vault)), 199000000043502021492);

        assertEq(epochPayout(vault, address(provider), 0), 199000000000024154370);

        // Redundant claim should not change it
        vault.claimInsurancePayouts();
        assertEq(epochPayout(vault, address(provider), 0), 199000000000024154370);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 199000000043502021492);

        vault.pprintEpochs();

        // Alice claims rewards
        {
            uint256[] memory previewRewards = vault.previewClaimRewards(ALICE);
            uint256 previewPayouts = vault.previewClaimPayouts(ALICE);
            assertEq(previewPayouts, 199000000000024154370);
            assertEq(previewPayouts, epochPayout(vault, address(provider), 0));
        }

        {
            uint256 before = IERC20(WETH).balanceOf(ALICE);
            vm.prank(ALICE);
            vault.claimPayouts();
            assertEq(IERC20(WETH).balanceOf(ALICE) - before, 199000000000024154370);
        }

        // Partial withdraw from the vault
        {
            uint256 before = IERC20(generatorToken).balanceOf(ALICE);
            vm.prank(ALICE);
            vault.withdraw(15e17, ALICE, ALICE);
            uint256 delta = IERC20(generatorToken).balanceOf(ALICE) - before;
            assertEq(delta, 15e17);
            assertEq(vault.balanceOf(ALICE), 5e17);
        }

        // Withdraw the rest
        {
            uint256 before = IERC20(generatorToken).balanceOf(ALICE);
            vm.prank(ALICE);
            vault.withdraw(5e17, ALICE, ALICE);
            uint256 delta = IERC20(generatorToken).balanceOf(ALICE) - before;
            assertEq(delta, 5e17);
            assertEq(vault.balanceOf(ALICE), 0);
        }

        vault.pprintEpochs();
    }
}
