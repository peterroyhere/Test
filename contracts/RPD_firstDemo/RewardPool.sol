// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

import "./RewardDistributor.sol";
import "./interfaces/IRewardPool.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IRewardDistributor.sol";
import "./interfaces/IRewardPoolManager.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract RewardPool is Ownable, Pausable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    IUniswapV2Router02 public uniswapV2Router;
    IRewardPoolManager public rewardPoolManager;

    address public uniswapV2Pair;
    address public nativeAsset;
    address public constant deadWallet = 0x000000000000000000000000000000000000dEaD; 
    uint256 public buyBackClaimWait = 86400;
    uint256 public lastBuyBackTimestamp;

    uint256 private constant distributeSharePrecision = 100;
    uint256 public gasForProcessing;

    bool private swapping;

    struct rewardStore {
        address rewardAsset;
        address rewardDistributor;
        uint256 distributeShare;
        bool isActive;
    }
    rewardStore[] private _rewardInfo;
    mapping (address => uint8) private _rewardStoreId;

    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event LiquidityWalletUpdated(address indexed newLiquidityWallet, address indexed oldLiquidityWallet);
    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);
    event SwapAndLiquify(uint256 tokensSwapped,uint256 ethReceived,uint256 tokensIntoLiqudity);
    event SendRewards(uint256 tokensSwapped,uint256 amount);
    event ProcessedDistributorTracker(uint256 iterations,uint256 claims,uint256 lastProcessedIndex,bool indexed automatic,uint256 gas,address indexed processor);

    constructor(
        address _nativeAsset,
        address _projectAdmin
    ) {
        require(_projectAdmin != address(0), "RewardDistributor: projectAdmin can't be zero");
        _transferOwnership(_projectAdmin);  

        rewardPoolManager = IRewardPoolManager(_msgSender());                 
        nativeAsset = _nativeAsset;

        // Mainnet
        // uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

        // Testnet
        uniswapV2Router = IUniswapV2Router02(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).getPair(uniswapV2Router.WETH(),_nativeAsset);

        _rewardStoreId[deadWallet] = uint8(_rewardInfo.length);
        _rewardInfo.push(
            rewardStore({
                rewardAsset: deadWallet,
                rewardDistributor: deadWallet,
                distributeShare: 0,
                isActive: false
            })
        ); 
    }

    receive() external payable {}

    modifier onlyOperator(address account) {
        require(
            account == owner() ||
            account == address(rewardPoolManager) ||
            account == rewardPoolManager.owner(), "Not a Operator Person"
        );
        _;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function validateDistributeShare(uint256 newShare) public view returns (bool) {
        uint256 currenShares = newShare;
        for(uint8 i=1;i<_rewardInfo.length;i++) {
            currenShares = currenShares.add(_rewardInfo[i].distributeShare);
        }
        return (currenShares <= distributeSharePrecision);
    }

    function setDistributeShare(address rewardToken,uint256 newShare) external onlyOperator(_msgSender()) {
        require(_rewardStoreId[rewardToken] != 0 , "RewardPool: Reward Token is invalid");
        _rewardInfo[_rewardStoreId[rewardToken]].distributeShare = newShare;
        require(validateDistributeShare(0), "RewardPool: DistributeShare is invalid");
    }

    function setBuyBackClaimWait(uint256 newClaimWait) external onlyOperator(_msgSender()) {
        buyBackClaimWait = newClaimWait;
    }

    function createRewardDistributor(
        address _implementation,
        address _nativeAsset,
        address _rewardAsset,
        uint256 _distributeShare,
        uint256 _minimumTokenBalanceForRewards
    ) external returns (address){
        require(_msgSender() == address(rewardPoolManager), "RewardPool: Only manager can accessible");
        require(validateDistributeShare(_distributeShare), "RewardPool: DistributeShare is invalid");

        RewardDistributor newRewardsDistributor = RewardDistributor(payable(Clones.clone(_implementation)));
        newRewardsDistributor.initialize(
            _nativeAsset,
            _rewardAsset,
            _minimumTokenBalanceForRewards
        );

        _rewardStoreId[_rewardAsset] = uint8(_rewardInfo.length);
        _rewardInfo.push(
            rewardStore({
                rewardAsset: _rewardAsset,
                rewardDistributor: address(newRewardsDistributor),
                distributeShare: _distributeShare,
                isActive: true
            })
        ); 

        // exclude from receiving rewards
        newRewardsDistributor.excludeFromRewards(address(newRewardsDistributor),false);
        newRewardsDistributor.excludeFromRewards(address(this),false);
        newRewardsDistributor.excludeFromRewards(owner(),false);
        newRewardsDistributor.excludeFromRewards(deadWallet,false);
        newRewardsDistributor.excludeFromRewards(address(uniswapV2Router),false);
        newRewardsDistributor.excludeFromRewards(address(uniswapV2Pair),false);

        return address(newRewardsDistributor);
    }

    function setRewardActiveStatus(address rewardAsset,bool status) external onlyOperator(_msgSender()) {
        _rewardInfo[_rewardStoreId[rewardAsset]].isActive = status;
    }

    function getBuyBackLimit(uint256 currentBalance) internal view returns (uint256,uint256) {
        (uint256 minimum,uint256 maximum) = rewardPoolManager.buyBackRidge();

        return (currentBalance.mul(minimum).div(1e2),currentBalance.mul(maximum).div(1e2));
    }

    function generateBuyBack(uint256 buyBackAmount) external whenNotPaused onlyOperator(_msgSender()) {
        require(lastBuyBackTimestamp.add(buyBackClaimWait) < block.timestamp, "RewardPool: buybackclaim still not over");

        uint256 initialBalance = address(this).balance;

        (uint256 minimumBnbBalanceForBuyback,uint256 maximumBnbBalanceForBuyback) = getBuyBackLimit(initialBalance);

        require(initialBalance > minimumBnbBalanceForBuyback, "RewardPool: Required Minimum BuyBack Amount");

        lastBuyBackTimestamp = block.timestamp;
        buyBackAmount = buyBackAmount > maximumBnbBalanceForBuyback ? 
                            maximumBnbBalanceForBuyback : 
                            buyBackAmount > minimumBnbBalanceForBuyback ? buyBackAmount : minimumBnbBalanceForBuyback;
        
        for(uint8 i=1; i<_rewardInfo.length; i++) {
            if(_rewardInfo[i].isActive) {                
                swapAndSendReward(
                    IRewardDistributor(_rewardInfo[i].rewardDistributor),
                    _rewardInfo[i].rewardAsset,
                    buyBackAmount.mul(_rewardInfo[i].distributeShare).div(1e2));
            }
        }
    }

    function updateDexStore(address newRouter) public onlyOwner {
        require(newRouter != address(uniswapV2Router), "HAM: The router already has that address");
        emit UpdateUniswapV2Router(newRouter, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newRouter);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).getPair(uniswapV2Router.WETH(),nativeAsset);
    }

    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(newValue >= 200000 && newValue <= 500000, "HAM: gasForProcessing must be between 200,000 and 500,000");
        require(newValue != gasForProcessing, "HAM: Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function updateClaimWait(IRewardDistributor rewardsDistributor,uint256 claimWait) external onlyOwner {
        rewardsDistributor.updateClaimWait(claimWait);
    }

    function updateClaimWaitForAllDistributore(
        uint256 claimWait
    )  external onlyOwner {
        for(uint8 i=1; i<_rewardInfo.length; i++) {
            if(_rewardInfo[i].isActive) {  
                IRewardDistributor(_rewardInfo[i].rewardDistributor).updateClaimWait(claimWait);
            }
        }
    }

    function getClaimWait(IRewardDistributor rewardsDistributor) external view returns(uint256) {
        return rewardsDistributor.claimWait();
    }

    function getTotalRewardsDistribute(IRewardDistributor rewardsDistributor) external view returns (uint256) {
        return rewardsDistributor.totalRewardsDistributed();
    }

    function withdrawableRewardOf(IRewardDistributor rewardsDistributor,address account) public view returns(uint256) {
    	return rewardsDistributor.withdrawableRewardOf(account);
  	}

	function excludeFromRewards(IRewardDistributor rewardsDistributor,address account) external onlyOwner{
	    rewardsDistributor.excludeFromRewards(account,false);
	}

    function includeFromRewards(IRewardDistributor rewardsDistributor,address account) external onlyOwner{
	    rewardsDistributor.excludeFromRewards(account,true);
	}

    function getAccountRewardsInfo(IRewardDistributor rewardsDistributor,address account)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256) {
        return rewardsDistributor.getAccount(account);
    }

	function getAccountRewardsInfoAtIndex(IRewardDistributor rewardsDistributor,int256 index)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256) {
    	return rewardsDistributor.getAccountAtIndex(index);
    }

    function enrollForSingleRewardByUser(
        address rewardAsset,
        address account
    ) external whenNotPaused {
        require(_rewardInfo[_rewardStoreId[rewardAsset]].isActive, "RewardPool: Pool is not active");
        IRewardDistributor(_rewardInfo[_rewardStoreId[rewardAsset]].rewardDistributor).setBalance(
            account, 
            IERC20(nativeAsset).balanceOf(account)
        );
    }

    function multipleAccountEnRollForSingleRewardByUser(
        address rewardAsset,
        address[] calldata accounts
    ) external whenNotPaused {     
        address distributor = _rewardInfo[_rewardStoreId[rewardAsset]].rewardDistributor;
        require(_rewardInfo[_rewardStoreId[rewardAsset]].isActive ,"RewardPool: Reward Distributor is not active");
        for(uint256 i; i<accounts.length; i++) {
                IRewardDistributor(distributor).setBalance(
                    accounts[i],
                    IERC20(nativeAsset).balanceOf(accounts[i])
                );
        }
    }

    function enrollForAllRewardByUser(
        address account
    ) external whenNotPaused {
        uint256 balance = IERC20(nativeAsset).balanceOf(account);
        for(uint8 i=1; i<_rewardInfo.length; i++) {
            if(_rewardInfo[i].isActive) {
                IRewardDistributor(_rewardInfo[i].rewardDistributor).setBalance(account,balance);
            }
        }        
    }

    function multipleAccountEnRollForAllRewardByUser(
        address[] calldata accounts
    ) external whenNotPaused { 
        for(uint8 k; k<accounts.length; k++) {
            uint256 balance = IERC20(nativeAsset).balanceOf(accounts[k]);
            for(uint8 i=1; i<_rewardInfo.length; i++) {
                if(_rewardInfo[i].isActive) {
                    address distributor = _rewardInfo[i].rewardDistributor;
                    IRewardDistributor(distributor).setBalance(
                        accounts[k],
                        balance
                    );
                }            
            }
        }
    }

    function singleRewardClaimByUser(address rewardToken) external whenNotPaused{
        address rewardDistributor = _rewardInfo[_rewardStoreId[rewardToken]].rewardDistributor;
        require(rewardDistributor != address(0), "RewardPool: Invalid Reward Asset");
        require(_rewardInfo[_rewardStoreId[rewardToken]].isActive, "RewardPool: Pool is not active");
		IRewardDistributor(rewardDistributor).processAccount(_msgSender(), false);
    }

    function multipleRewardClaimByUser() external whenNotPaused{
        address user = _msgSender();
        for(uint8 i=1; i<_rewardInfo.length; i++) {
            if(_rewardInfo[i].isActive) {               
		        IRewardDistributor(_rewardInfo[i].rewardDistributor).processAccount(user, false);
            }
        }
    }

    function getLastProcessedIndex(IRewardDistributor rewardsDistributor) external view returns(uint256) {
    	return rewardsDistributor.getLastProcessedIndex();
    }

    function getNumberOfRewardTokenHolders(IRewardDistributor rewardsDistributor) external view returns(uint256) {
        return rewardsDistributor.getNumberOfTokenHolders();
    }

    function singleRewardDistributeOnlyEnrolled(address rewardToken) external whenNotPaused {
        uint256 gas = gasForProcessing;
	    address rewardDistributor = _rewardInfo[_rewardStoreId[rewardToken]].rewardDistributor;
        require(_rewardInfo[_rewardStoreId[rewardToken]].isActive, "RewardPool: Pool is not active");
        try IRewardDistributor(rewardDistributor).process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
	        emit ProcessedDistributorTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
        }
	    catch {}
    }

    function multiRewardDistributeOnlyEnrolled() external whenNotPaused {        
	    uint256 gas = gasForProcessing;
        for(uint8 i=1;i<_rewardInfo.length;i++) {
            if(_rewardInfo[i].isActive) {
                try IRewardDistributor(_rewardInfo[i].rewardDistributor).process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
                    emit ProcessedDistributorTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
                }
                catch {}
            }

        }
    }

    function swapBNBForReward(address rewardAsset,uint256 bnbAmount) private {
        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = rewardAsset;

        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnbAmount}(
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function swapAndSendReward(IRewardDistributor rewardsDistributor,address rewardAsset,uint256 bnbAmount) private{
        swapBNBForReward(rewardAsset,bnbAmount);
        uint256 rewards = IERC20(rewardAsset).balanceOf(address(this));
        bool success = IERC20(rewardAsset).transfer(address(rewardsDistributor), rewards);
		
        if (success) {
            rewardsDistributor.distributeRewards(rewards);
            emit SendRewards(bnbAmount, rewards);
        }
    }

    function getRewardsDistributor(address rewardAsset) external view returns (address) {
        return _rewardInfo[_rewardStoreId[rewardAsset]].rewardDistributor;
    }

    function getRewardDistributorInfo(address rewardAsset) external view returns (
        address rewardDistributor,
        uint256 distributeShare,
        bool isActive
    ) {
        return (
            _rewardInfo[_rewardStoreId[rewardAsset]].rewardDistributor,
            _rewardInfo[_rewardStoreId[rewardAsset]].distributeShare,
            _rewardInfo[_rewardStoreId[rewardAsset]].isActive
        );
    }

    function rewardsDistributorContains(address rewardAsset) external view returns (bool) {
        return (_rewardStoreId[rewardAsset] != 0);
    }

    function getTotalNumberofRewardsDistributor() external view returns (uint256) {
        return _rewardInfo.length - 1;
    }

    function getPoolStatus(address rewardAsset) external view returns (bool isActive) {
        return _rewardInfo[_rewardStoreId[rewardAsset]].isActive;
    }

    function rewardsDistributorAt(uint256 index) external view returns (address) {
        return  _rewardInfo[index].rewardDistributor;
    }

    function getAllRewardsDistributor() external view returns (address[] memory rewardDistributors) {
        rewardDistributors = new address[](_rewardInfo.length);
        for(uint8 i=1; i<_rewardInfo.length; i++) {
            rewardDistributors[i] = _rewardInfo[i].rewardDistributor;
        }
    }
}