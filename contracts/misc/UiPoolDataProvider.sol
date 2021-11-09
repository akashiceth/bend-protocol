// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

import {IERC20Detailed} from "../interfaces/IERC20Detailed.sol";
import {IERC721Detailed} from "../interfaces/IERC721Detailed.sol";
import {ILendPoolAddressesProvider} from "../interfaces/ILendPoolAddressesProvider.sol";
import {IIncentivesController} from "../interfaces/IIncentivesController.sol";
import {IUiPoolDataProvider} from "../interfaces/IUiPoolDataProvider.sol";
import {ILendPool} from "../interfaces/ILendPool.sol";
import {ILendPoolLoan} from "../interfaces/ILendPoolLoan.sol";
import {IReserveOracleGetter} from "../interfaces/IReserveOracleGetter.sol";
import {INFTOracleGetter} from "../interfaces/INFTOracleGetter.sol";
import {IBToken} from "../interfaces/IBToken.sol";
import {IDebtToken} from "../interfaces/IDebtToken.sol";
import {WadRayMath} from "../libraries/math/WadRayMath.sol";
import {ReserveConfiguration} from "../libraries/configuration/ReserveConfiguration.sol";
import {NftConfiguration} from "../libraries/configuration/NftConfiguration.sol";
import {DataTypes} from "../libraries/types/DataTypes.sol";
import {InterestRate} from "../protocol/InterestRate.sol";
import {Errors} from "../libraries/helpers/Errors.sol";

contract UiPoolDataProvider is IUiPoolDataProvider {
  using WadRayMath for uint256;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using NftConfiguration for DataTypes.NftConfigurationMap;

  IIncentivesController public immutable override incentivesController;
  IReserveOracleGetter public immutable reserveOracle;
  INFTOracleGetter public immutable nftOracle;

  constructor(
    IIncentivesController _incentivesController,
    IReserveOracleGetter _reserveOracle,
    INFTOracleGetter _nftOracle
  ) {
    incentivesController = _incentivesController;
    reserveOracle = _reserveOracle;
    nftOracle = _nftOracle;
  }

  function getInterestRateStrategySlopes(InterestRate interestRate) internal view returns (uint256, uint256) {
    return (interestRate.variableRateSlope1(), interestRate.variableRateSlope2());
  }

  function getReservesList(ILendPoolAddressesProvider provider) public view override returns (address[] memory) {
    ILendPool lendPool = ILendPool(provider.getLendPool());
    return lendPool.getReservesList();
  }

  function getSimpleReservesData(ILendPoolAddressesProvider provider)
    public
    view
    override
    returns (AggregatedReserveData[] memory, uint256)
  {
    ILendPool lendPool = ILendPool(provider.getLendPool());
    address[] memory reserves = lendPool.getReservesList();
    AggregatedReserveData[] memory reservesData = new AggregatedReserveData[](reserves.length);

    for (uint256 i = 0; i < reserves.length; i++) {
      AggregatedReserveData memory reserveData = reservesData[i];

      DataTypes.ReserveData memory baseData = lendPool.getReserveData(reserves[i]);

      _fillReserveData(reserveData, reserves[i], baseData);
    }

    uint256 emissionEndTimestamp;
    if (address(0) != address(incentivesController)) {
      emissionEndTimestamp = incentivesController.DISTRIBUTION_END();
    }

    return (reservesData, emissionEndTimestamp);
  }

  function getUserReservesData(ILendPoolAddressesProvider provider, address user)
    external
    view
    override
    returns (UserReserveData[] memory, uint256)
  {
    ILendPool lendPool = ILendPool(provider.getLendPool());
    address[] memory reserves = lendPool.getReservesList();

    UserReserveData[] memory userReservesData = new UserReserveData[](user != address(0) ? reserves.length : 0);

    for (uint256 i = 0; i < reserves.length; i++) {
      DataTypes.ReserveData memory baseData = lendPool.getReserveData(reserves[i]);

      _fillUserReserveData(userReservesData[i], user, reserves[i], baseData);
    }

    uint256 userUnclaimedRewards;
    if (address(0) != address(incentivesController)) {
      userUnclaimedRewards = incentivesController.getUserUnclaimedRewards(user);
    }

    return (userReservesData, userUnclaimedRewards);
  }

  function getReservesData(ILendPoolAddressesProvider provider, address user)
    external
    view
    override
    returns (
      AggregatedReserveData[] memory,
      UserReserveData[] memory,
      IncentivesControllerData memory
    )
  {
    ILendPool lendPool = ILendPool(provider.getLendPool());
    address[] memory reserves = lendPool.getReservesList();

    AggregatedReserveData[] memory reservesData = new AggregatedReserveData[](reserves.length);
    UserReserveData[] memory userReservesData = new UserReserveData[](user != address(0) ? reserves.length : 0);

    for (uint256 i = 0; i < reserves.length; i++) {
      AggregatedReserveData memory reserveData = reservesData[i];

      DataTypes.ReserveData memory baseData = lendPool.getReserveData(reserves[i]);
      _fillReserveData(reserveData, reserves[i], baseData);

      if (user != address(0)) {
        _fillUserReserveData(userReservesData[i], user, reserves[i], baseData);
      }
    }

    IncentivesControllerData memory incentivesControllerData;

    if (address(0) != address(incentivesController)) {
      if (user != address(0)) {
        incentivesControllerData.userUnclaimedRewards = incentivesController.getUserUnclaimedRewards(user);
      }
      incentivesControllerData.emissionEndTimestamp = incentivesController.DISTRIBUTION_END();
    }

    return (reservesData, userReservesData, incentivesControllerData);
  }

  function _fillReserveData(
    AggregatedReserveData memory reserveData,
    address reserveAsset,
    DataTypes.ReserveData memory baseData
  ) internal view {
    reserveData.underlyingAsset = reserveAsset;

    // reserve current state
    reserveData.liquidityIndex = baseData.liquidityIndex;
    reserveData.variableBorrowIndex = baseData.variableBorrowIndex;
    reserveData.liquidityRate = baseData.currentLiquidityRate;
    reserveData.variableBorrowRate = baseData.currentVariableBorrowRate;
    reserveData.lastUpdateTimestamp = baseData.lastUpdateTimestamp;
    reserveData.bTokenAddress = baseData.bTokenAddress;
    reserveData.debtTokenAddress = baseData.debtTokenAddress;
    reserveData.interestRateAddress = baseData.interestRateAddress;
    reserveData.priceInEth = reserveOracle.getAssetPrice(reserveData.underlyingAsset);

    reserveData.availableLiquidity = IERC20Detailed(reserveData.underlyingAsset).balanceOf(reserveData.bTokenAddress);
    reserveData.totalScaledVariableDebt = IDebtToken(reserveData.debtTokenAddress).scaledTotalSupply();

    // reserve configuration
    reserveData.symbol = IERC20Detailed(reserveData.underlyingAsset).symbol();
    reserveData.name = IERC20Detailed(reserveData.underlyingAsset).name();

    (, , , reserveData.decimals, reserveData.reserveFactor) = baseData.configuration.getParamsMemory();
    (reserveData.isActive, reserveData.isFrozen, reserveData.borrowingEnabled, ) = baseData
      .configuration
      .getFlagsMemory();
    (reserveData.variableRateSlope1, reserveData.variableRateSlope2) = getInterestRateStrategySlopes(
      InterestRate(reserveData.interestRateAddress)
    );

    // incentives
    if (address(0) != address(incentivesController)) {
      (
        reserveData.bTokenIncentivesIndex,
        reserveData.bEmissionPerSecond,
        reserveData.bIncentivesLastUpdateTimestamp
      ) = incentivesController.getAssetData(reserveData.bTokenAddress);

      (
        reserveData.vTokenIncentivesIndex,
        reserveData.vEmissionPerSecond,
        reserveData.vIncentivesLastUpdateTimestamp
      ) = incentivesController.getAssetData(reserveData.debtTokenAddress);
    }
  }

  function _fillUserReserveData(
    UserReserveData memory userReserveData,
    address user,
    address reserveAsset,
    DataTypes.ReserveData memory baseData
  ) internal view {
    // user reserve data
    userReserveData.underlyingAsset = reserveAsset;
    userReserveData.scaledBTokenBalance = IBToken(baseData.bTokenAddress).scaledBalanceOf(user);
    userReserveData.scaledVariableDebt = IDebtToken(baseData.debtTokenAddress).scaledBalanceOf(user);
    // incentives
    if (address(0) != address(incentivesController)) {
      userReserveData.bTokenincentivesUserIndex = incentivesController.getUserAssetData(user, baseData.bTokenAddress);
      userReserveData.vTokenincentivesUserIndex = incentivesController.getUserAssetData(
        user,
        baseData.debtTokenAddress
      );
    }
  }

  function getNftsList(ILendPoolAddressesProvider provider) external view override returns (address[] memory) {
    ILendPool lendPool = ILendPool(provider.getLendPool());
    return lendPool.getNftsList();
  }

  function getSimpleNftsData(ILendPoolAddressesProvider provider)
    external
    view
    override
    returns (AggregatedNftData[] memory)
  {
    ILendPool lendPool = ILendPool(provider.getLendPool());
    ILendPoolLoan lendPoolLoan = ILendPoolLoan(provider.getLendPoolLoan());
    address[] memory nfts = lendPool.getNftsList();
    AggregatedNftData[] memory nftsData = new AggregatedNftData[](nfts.length);

    for (uint256 i = 0; i < nfts.length; i++) {
      AggregatedNftData memory nftData = nftsData[i];

      DataTypes.NftData memory baseData = lendPool.getNftData(nfts[i]);

      _fillNftData(nftData, nfts[i], baseData, lendPoolLoan);
    }

    return (nftsData);
  }

  function getUserNftsData(ILendPoolAddressesProvider provider, address user)
    external
    view
    override
    returns (UserNftData[] memory)
  {
    ILendPool lendPool = ILendPool(provider.getLendPool());
    ILendPoolLoan lendPoolLoan = ILendPoolLoan(provider.getLendPoolLoan());
    address[] memory nfts = lendPool.getNftsList();

    UserNftData[] memory userNftsData = new UserNftData[](user != address(0) ? nfts.length : 0);

    for (uint256 i = 0; i < nfts.length; i++) {
      UserNftData memory userNftData = userNftsData[i];

      DataTypes.NftData memory baseData = lendPool.getNftData(nfts[i]);

      _fillUserNftData(userNftData, user, nfts[i], baseData, lendPoolLoan);
    }

    return (userNftsData);
  }

  // generic method with full data
  function getNftsData(ILendPoolAddressesProvider provider, address user)
    external
    view
    override
    returns (AggregatedNftData[] memory, UserNftData[] memory)
  {
    ILendPool lendPool = ILendPool(provider.getLendPool());
    ILendPoolLoan lendPoolLoan = ILendPoolLoan(provider.getLendPoolLoan());
    address[] memory nfts = lendPool.getNftsList();

    AggregatedNftData[] memory nftsData = new AggregatedNftData[](nfts.length);
    UserNftData[] memory userNftsData = new UserNftData[](user != address(0) ? nfts.length : 0);

    for (uint256 i = 0; i < nfts.length; i++) {
      AggregatedNftData memory nftData = nftsData[i];
      UserNftData memory userNftData = userNftsData[i];

      DataTypes.NftData memory baseData = lendPool.getNftData(nfts[i]);

      _fillNftData(nftData, nfts[i], baseData, lendPoolLoan);
      if (user != address(0)) {
        _fillUserNftData(userNftData, user, nfts[i], baseData, lendPoolLoan);
      }
    }

    return (nftsData, userNftsData);
  }

  function _fillNftData(
    AggregatedNftData memory nftData,
    address nftAsset,
    DataTypes.NftData memory baseData,
    ILendPoolLoan lendPoolLoan
  ) internal view {
    nftData.underlyingAsset = nftAsset;

    // nft current state
    nftData.bNftAddress = baseData.bNftAddress;
    nftData.priceInEth = nftOracle.getAssetPrice(nftData.underlyingAsset);

    nftData.totalCollateral = lendPoolLoan.getNftCollateralAmount(nftAsset);

    // nft configuration
    nftData.symbol = IERC721Detailed(nftData.underlyingAsset).symbol();
    nftData.name = IERC721Detailed(nftData.underlyingAsset).name();

    (nftData.ltv, nftData.liquidationThreshold, nftData.liquidationBonus) = baseData.configuration.getParamsMemory();
    (nftData.isActive, nftData.isFrozen) = baseData.configuration.getFlagsMemory();
  }

  function _fillUserNftData(
    UserNftData memory userNftData,
    address user,
    address nftAsset,
    DataTypes.NftData memory baseData,
    ILendPoolLoan lendPoolLoan
  ) internal view {
    userNftData.underlyingAsset = nftAsset;

    // user nft data
    userNftData.bNftAddress = baseData.bNftAddress;

    userNftData.TotalCollateral = lendPoolLoan.getUserNftCollateralAmount(user, nftAsset);
  }

  function getSimpleLoansData(
    ILendPoolAddressesProvider provider,
    address[] memory nftAssets,
    uint256[] memory nftTokenIds
  ) external view override returns (AggregatedLoanData[] memory) {
    require(nftAssets.length == nftTokenIds.length, Errors.LP_INCONSISTENT_PARAMS);

    ILendPool lendPool = ILendPool(provider.getLendPool());

    AggregatedLoanData[] memory loansData = new AggregatedLoanData[](nftAssets.length);

    for (uint256 i = 0; i < nftAssets.length; i++) {
      AggregatedLoanData memory loanData = loansData[i];
      (
        loanData.totalCollateralETH,
        loanData.totalDebtETH,
        loanData.availableBorrowsETH,
        loanData.ltv,
        loanData.liquidationThreshold,
        loanData.loanId,
        loanData.healthFactor
      ) = lendPool.getNftLoanData(nftAssets[i], nftTokenIds[i]);
    }

    return loansData;
  }
}
