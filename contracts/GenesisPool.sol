// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";

import "./interfaces/IGenesisPool.sol";
import "./interfaces/IGenesisPoolBase.sol";
import "./interfaces/ITokenHandler.sol";
import "./interfaces/IAuction.sol";
import "./interfaces/IBribe.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IGauge.sol";

contract GenesisPool is IGenesisPool, IGenesisPoolBase {
    using SafeERC20 for IERC20;

    address internal immutable genesisManager;
    ITokenHandler internal immutable tokenHandler;
    IAuction internal auction;

    TokenAllocation public allocationInfo;
    GenesisInfo public genesisInfo;
    PoolStatus public poolStatus;
    LiquidityPool public liquidityPoolInfo;

    address[] public incentiveTokens;
    mapping(address => uint256) public incentives;

    address[] public depositers;
    mapping(address => uint256) public userDeposits;

    uint256 internal totalDeposits;
    uint256 liquidity;
    uint256 tokenOwnerUnstaked;

    event DepositedNativeToken(
        address native,
        address owner,
        address genesisPool,
        uint256 proposedNativeAmount,
        uint proposedFundingAmount
    );
    event AddedIncentives(
        address native,
        address[] incentivesToken,
        uint256[] incentivesAmount
    );
    event RejectedGenesisPool(address native);
    event ApprovedGenesisPool(address proposedToken);

    modifier onlyManager() {
        require(msg.sender == genesisManager);
        _;
    }

    modifier onlyManagerOrProtocol() {
        require(
            msg.sender == genesisManager || msg.sender == genesisInfo.tokenOwner
        );
        _;
    }

    modifier onlyGauge() {
        require(msg.sender == liquidityPoolInfo.gaugeAddress);
        _;
    }

    constructor(
        address _genesisManager,
        address _tokenHandler,
        address _tokenOwner,
        address _nativeToken,
        address _fundingToken
    ) {
        genesisInfo.tokenOwner = _tokenOwner;
        //@seashell $black 原生代幣
        genesisInfo.nativeToken = _nativeToken;
        //@seashell 用戶提供的代幣 可能部屬好幾個Genesis 一個池子處理一種代幣
        //@audit 每個代幣可能需要的處理邏輯不同，檢查他是否有相容他真的開放接受的各種代幣
        // -->  genesispoolinfo 有設定好funding token的address。  他轉帳的時候就只會呼叫那個地址的代幣被轉過來'

        genesisInfo.fundingToken = _fundingToken;

        genesisManager = _genesisManager;
        tokenHandler = ITokenHandler(_tokenHandler);

        totalDeposits = 0;
        liquidity = 0;
        tokenOwnerUnstaked = 0;
    }

    //@seashell: 改alloaction info 還有genesis info。 下面是allocation info的說明
    //@seashell 已經募集到的funding代幣、已經分配的原生代幣 (allocated)
    // 預計募集的funding和預計分配的原生代幣 (propose)
    // 還有一個單獨的 refundableNativeAmount。可能要退款給owner? 下面有一個rejectpool的函數 會把pool裡全部的原生代幣都紀錄為refundableNativeAmount
    function setGenesisPoolInfo(
        GenesisInfo calldata _genesisInfo,
        TokenAllocation calldata _allocationInfo,
        address _auction
    ) external onlyManager {
        genesisInfo = _genesisInfo;

        genesisInfo.duration = BlackTimeLibrary.epochMultiples(
            genesisInfo.duration
        );
        genesisInfo.startTime = BlackTimeLibrary.epochStart(
            genesisInfo.startTime
        );

        allocationInfo.proposedNativeAmount = _allocationInfo
            .proposedNativeAmount;
        allocationInfo.proposedFundingAmount = _allocationInfo
            .proposedFundingAmount;
        allocationInfo.allocatedNativeAmount = 0;
        allocationInfo.allocatedFundingAmount = 0;
        allocationInfo.refundableNativeAmount = 0;

        //所以一個 genesis pool會對應到一個 auction 拍賣。 可能就是透過拍賣來獲得最初資金
        auction = IAuction(_auction); //沒在函數裡面宣告 所以一定是狀態變數。

        //@audit 設定初始 pool info的時候 就把此pool的狀態設定為原生代幣已經存入。 明明沒看到存入邏輯
        poolStatus = PoolStatus.NATIVE_TOKEN_DEPOSITED;

        emit DepositedNativeToken(
            _genesisInfo.nativeToken,
            genesisInfo.tokenOwner,
            address(this),
            _allocationInfo.proposedNativeAmount,
            _allocationInfo.proposedFundingAmount
        );
    }

    //@todo:  誰是 genesis的tokenOwner 可以來加incentives?
    // 又是為甚麼要加入 incentive?
    //(原生代幣已經存入 或是 PRE_LISTING 狀態才能加incentive)  why?

    //@seashell:  這邊會有一個Incentive mapping，列出USDC 100、USDT 200 之類的來記錄incenvtives
    function addIncentives(
        address[] calldata _incentivesToken,
        uint256[] calldata _incentivesAmount
    ) external {
        address _sender = msg.sender;
        require(_sender == genesisInfo.tokenOwner, "NA");
        require(
            poolStatus == PoolStatus.NATIVE_TOKEN_DEPOSITED ||
                poolStatus == PoolStatus.PRE_LISTING,
            "INS"
        );
        require(_incentivesToken.length > 0, "ZV");
        require(
            _incentivesToken.length == _incentivesAmount.length,
            "MISMATCH_LEN"
        );
        uint256 _incentivesCnt = _incentivesToken.length;
        uint256 i = 0;

        address _token;
        uint256 _amount;
        for (i = 0; i < _incentivesCnt; i++) {
            _token = _incentivesToken[i];
            _amount = _incentivesAmount[i];
            if (
                _token != address(0) &&
                _amount > 0 &&
                (_token == genesisInfo.nativeToken ||
                    tokenHandler.isConnector(_token))
            ) {
                IERC20(_token).safeTransferFrom(
                    _sender,
                    address(this),
                    _amount
                );
                if (incentives[_token] == 0) {
                    incentiveTokens.push(_token);
                }
                incentives[_token] += _amount;
            }
        }

        emit AddedIncentives(
            genesisInfo.nativeToken,
            _incentivesToken,
            _incentivesAmount
        );
    }

//@seashell:  把refundable的數量變成 "預計要收的原生代幣的數量" ( proposedNativeAmount) ) 
    function rejectPool() external onlyManager {
        require(
            poolStatus == PoolStatus.NATIVE_TOKEN_DEPOSITED ||
                poolStatus == PoolStatus.PRE_LISTING,
            "INS"
        );
        poolStatus = PoolStatus.NOT_QUALIFIED;
        allocationInfo.refundableNativeAmount = allocationInfo
            .proposedNativeAmount;
        emit RejectedGenesisPool(genesisInfo.nativeToken);
    }

//@seashell:  approvePool 會把pool的狀態改成 PRE_LISTING
//@seashell: //@todo  不知道甚麼是 pairAddress。 liquiditypool也還不知道是啥   
    function approvePool(address _pairAddress) external onlyManager {
        require(poolStatus == PoolStatus.NATIVE_TOKEN_DEPOSITED, "INS");
        liquidityPoolInfo.pairAddress = _pairAddress;
        poolStatus = PoolStatus.PRE_LISTING;
        emit ApprovedGenesisPool(genesisInfo.nativeToken);
    }
//@seashell: 要被approve過( prelisting )或是 transfer incentive( prelaunch )之後才能存 //@todo
// 也要過了 startTime 才能存
    function depositToken(
        address spender,
        uint256 amount
    ) external onlyManager returns (bool) {
        require(
            poolStatus == PoolStatus.PRE_LISTING ||
                poolStatus == PoolStatus.PRE_LAUNCH,
            "INS"
        );
        require(block.timestamp >= genesisInfo.startTime, "INS");
//@seashell: 預計募集的fund和已經fund到的錢的差距
        uint256 _fundingLeft = allocationInfo.proposedFundingAmount -
            allocationInfo.allocatedFundingAmount;
            //@seashell: 預計募集的原生代幣和已經拿到的原生代幣的差距，
            // 把這個數額透過 _getFundingTokenAmount 轉換成 funding token 的數量
            //@ 當成 max funding left，表示 我預計提供的原生代幣就只能支撐起這麼多fund )
        uint256 _maxFundingLeft = _getFundingTokenAmount(
            allocationInfo.proposedNativeAmount -
                allocationInfo.allocatedNativeAmount
        );  //@seashell: 原生代幣能支持的funding VS 預計-已經收到的funding。 取小的當還能收的 amount
    // @todo 但我不是很懂。預計要收的代幣跟預計要收的fund不是都是協議方自己設置的嗎? 
    //不是可能換算起來，兩個數額差不多。 就隨便取一個當計算標準就好?  
    //還是只要超過上限任何一點點，都會造成危害?

        uint _amount = _maxFundingLeft <= _fundingLeft
            ? _maxFundingLeft
            : _fundingLeft;

            //@seashell: 上面計算的還能收多少的amount跟使用者輸入的amount比較，取小的。
            //@seashell: 協議還能收，使用者要給多少就全收。協議只能吃使用者的一半，那就只讓她轉帳一半
        _amount = _amount <= amount ? _amount : amount;
        require(_amount > 0, "ZV");

        IERC20(genesisInfo.fundingToken).safeTransferFrom(
            spender,
            address(this),
            _amount
        );

//@seashell: 如果spnder之前沒存過錢，就把spender加入到depositers名單裡面
        if (userDeposits[spender] == 0) {
            depositers.push(spender);
        }
//@seashell: 更新userDeposits的數額、totalDeposit( internal狀態變數 )的存量。
        userDeposits[spender] = userDeposits[spender] + _amount;
        totalDeposits += _amount;
//@seashell: 把fund算成等值的native token amount。 然後更新已經募集到的原生代幣數額、funding數額
//@audit: 如果在募資環節，原生代幣的價格波動很大，這樣會不會有問題? 可能同樣捐5usdc，
// 第一個人被計算成比較大的原生代幣資格之類的

//@todo 這邊用_getNativeTokenAmount去算對應的原生代幣數量，讓我感覺這個pool確實一次只能吃一種
//funding token?。  不然這邊只是傳給_getNativeTokenAmount 一個數字而已，他應該沒辦法辨別出傳入的
// fund是甚麼Token。  那我想知道的是，這個pool是怎麼設計他「只吃USDC」的限制的呢?

        uint256 nativeAmount = _getNativeTokenAmount(totalDeposits);
        allocationInfo.allocatedFundingAmount += _amount;
        allocationInfo.allocatedNativeAmount = nativeAmount;

        IAuction(auction).purchased(nativeAmount);

        return
            poolStatus == PoolStatus.PRE_LISTING && _eligbleForPreLaunchPool();
    }

    function eligbleForPreLaunchPool() external view returns (bool) {
        return _eligbleForPreLaunchPool();
    }
//@seashell: 如果募到的原生代幣達到預期的threshold 可能60%，並且這個pool 
// 要在結束前，而且還要在結束前一周內。 太早募集到還不能算過。 也許它其實就只給一周? 所以那個太早的檢查條件只是某種invarient check
// 就eligable For preLaunch。 但不知道可以幹嘛 @todo
    function _eligbleForPreLaunchPool() internal view returns (bool) {
        uint _endTime = genesisInfo.startTime + genesisInfo.duration;//@audit: 就是覺得加法搞不好會加出問題
        uint256 targetNativeAmount = (allocationInfo.proposedNativeAmount *
            genesisInfo.threshold) / 10000; // threshold is 100 * of original to support 2 deciamls
//@seashell: 如果 timestamp 落在 結束前一週內（含起點但不含結束點），就會回傳 true。
        return (BlackTimeLibrary.isLastEpoch(block.timestamp, _endTime) &&
            allocationInfo.allocatedNativeAmount >= targetNativeAmount);
    }

//@seashell: 募資到的原生代幣超過預計數量，可以eligble for complete launch ( 上面是preLaunch )
//@audit: 但這邊不用管時間喔? 萬一end time早就過了。原生代幣超過數額還是能complete launch?
    function _eligbleForCompleteLaunch() internal view returns (bool) {
        return
            allocationInfo.allocatedNativeAmount >=
            allocationInfo.proposedNativeAmount;
    }

    function eligbleForDisqualify() external view returns (bool) {
        uint256 _endTime = genesisInfo.startTime + genesisInfo.duration;
        uint256 targetNativeAmount = (allocationInfo.proposedNativeAmount *
            genesisInfo.threshold) / 10000; // threshold is 100 * of original to support 2 deciamls

//@seashell:如果時間已經到，結束前一周內，(但還沒結束)。 而這時候募集到的原生代幣沒過門檻
//就會回傳 true。  表示eligable for disqualify。 可能可以呼叫函數取消一個池子吧?
        return (BlackTimeLibrary.isLastEpoch(block.timestamp, _endTime) &&
            allocationInfo.allocatedNativeAmount < targetNativeAmount);
    }

    //@seashell: @todo 綜觀上面三個 elgiable 函數。感覺 endtime 其實不是池子的結束時間，
   // 而是池子準備階段的結束時間。 在準備階段，可以提前launch 也可以提前disqualify。
   // 如果時間過了，資金有收集到，就可以complete launch。 但我也不確定


//@seashell:  incentives 可以吃各種代幣的樣子。 但我還是先猜一個genesis pool只能吃一種funding token
//@seashell: @todo 他會是把incentivet傳給 bribe合約 我不了解為啥。 而且還有分內部外部。   
    function transferIncentives(
        address gauge,
        address external_bribe,
        address internal_bribe
    ) external onlyManager {
        liquidityPoolInfo.gaugeAddress = gauge;
        liquidityPoolInfo.external_bribe = external_bribe;
        liquidityPoolInfo.internal_bribe = internal_bribe;

//@seashell: loop過全部的incentive。一個種類>0才進行轉帳。 並且會notify外部bribe合約，有這些incentive可以發放?
        uint256 i = 0;
        uint256 _amount = 0;
        uint256 _incentivesCnt = incentiveTokens.length;
        for (i = 0; i < _incentivesCnt; i++) {
            _amount = incentives[incentiveTokens[i]];
            if (_amount > 0) {
                IERC20(incentiveTokens[i]).safeApprove(external_bribe, _amount);
                IBribe(external_bribe).notifyRewardAmount(
                    incentiveTokens[i],
                    _amount
                );
            }
        }

        poolStatus = PoolStatus.PRE_LAUNCH;
    }

    function setPoolStatus(PoolStatus status) external onlyManager {
        _setPoolStatus(status);
    }

    function _setPoolStatus(PoolStatus status) internal {
        if (status == PoolStatus.PARTIALLY_LAUNCHED) {
            allocationInfo.refundableNativeAmount =
                allocationInfo.proposedNativeAmount -
                allocationInfo.allocatedNativeAmount;
        } else if (status == PoolStatus.LAUNCH) {
            allocationInfo.refundableNativeAmount = 0;
        } else if (status == PoolStatus.NOT_QUALIFIED) {
            allocationInfo.refundableNativeAmount = allocationInfo
                .proposedNativeAmount;
        }

        poolStatus = status;
    }

    function _approveTokens(address router) internal {
        IERC20(genesisInfo.nativeToken).safeApprove(
            router,
            allocationInfo.allocatedNativeAmount
        );
        IERC20(genesisInfo.fundingToken).safeApprove(
            router,
            allocationInfo.allocatedFundingAmount
        );
    }

    function _addLiquidityAndDistribute(
        address _router,
        uint256 nativeDesired,
        uint256 fundingDesired,
        uint256 maturityTime
    ) internal {
        (, , uint _liquidity) = IRouter(_router).addLiquidity(
            genesisInfo.nativeToken,
            genesisInfo.fundingToken,
            genesisInfo.stable,
            nativeDesired,
            fundingDesired,
            0,
            0,
            address(this),
            block.timestamp + 100
        );
        liquidity = _liquidity;
        IERC20(liquidityPoolInfo.pairAddress).safeApprove(
            liquidityPoolInfo.gaugeAddress,
            liquidity
        );
        IGauge(liquidityPoolInfo.gaugeAddress).depositsForGenesis(
            genesisInfo.tokenOwner,
            block.timestamp + maturityTime,
            liquidity
        );
    }

    function _launchCompletely(address router, uint256 maturityTime) internal {
        _approveTokens(router);
        _addLiquidityAndDistribute(
            router,
            allocationInfo.allocatedNativeAmount,
            allocationInfo.allocatedFundingAmount,
            maturityTime
        );
        _setPoolStatus(PoolStatus.LAUNCH);
    }

    function _launchPartially(address router, uint256 maturityTime) internal {
        _approveTokens(router);
        _addLiquidityAndDistribute(
            router,
            allocationInfo.allocatedNativeAmount,
            allocationInfo.allocatedFundingAmount,
            maturityTime
        );
        _setPoolStatus(PoolStatus.PARTIALLY_LAUNCHED);
    }

    function launch(address router, uint256 maturityTime) external onlyManager {
        if (genesisInfo.maturityTime > 0) {
            maturityTime = genesisInfo.maturityTime;
        }
        if (_eligbleForCompleteLaunch()) {
            _launchCompletely(router, maturityTime);
        } else {
            _launchPartially(router, maturityTime);
        }
    }

    function claimableNative()
        public
        view
        returns (PoolStatus, address token, uint256 amount)
    {
        if (msg.sender == genesisInfo.tokenOwner) {
            if (
                poolStatus == PoolStatus.PARTIALLY_LAUNCHED ||
                poolStatus == PoolStatus.NOT_QUALIFIED
            ) {
                token = genesisInfo.nativeToken;
                amount = allocationInfo.refundableNativeAmount;
            }
        }
        return (poolStatus, token, amount);
    }

    function claimableDeposits()
        public
        view
        returns (PoolStatus, address token, uint256 amount)
    {
        if (poolStatus == PoolStatus.NOT_QUALIFIED) {
            token = genesisInfo.fundingToken;
            amount = userDeposits[msg.sender];
        }
        return (poolStatus, token, amount);
    }

    function claimNative() external {
        require(
            poolStatus == PoolStatus.NOT_QUALIFIED ||
                poolStatus == PoolStatus.PARTIALLY_LAUNCHED,
            "INS"
        );
        require(msg.sender == genesisInfo.tokenOwner, "NA");

        uint256 _amount = allocationInfo.refundableNativeAmount;
        allocationInfo.refundableNativeAmount = 0;

        if (_amount > 0) {
            IERC20(genesisInfo.nativeToken).safeTransfer(msg.sender, _amount);
        }
    }

    function claimDeposits() external {
        require(poolStatus == PoolStatus.NOT_QUALIFIED, "INS");

        uint256 _amount = userDeposits[msg.sender];
        userDeposits[msg.sender] = 0;

        if (_amount > 0) {
            IERC20(genesisInfo.fundingToken).safeTransfer(msg.sender, _amount);
        }
    }

    function claimableIncentives()
        public
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        if (
            poolStatus == PoolStatus.NOT_QUALIFIED &&
            msg.sender == genesisInfo.tokenOwner
        ) {
            tokens = incentiveTokens;
            uint256 incentivesCnt = incentiveTokens.length;
            amounts = new uint256[](incentivesCnt);
            uint256 i;
            for (i = 0; i < incentivesCnt; i++) {
                amounts[i] = incentives[incentiveTokens[i]];
            }
        }
    }

    function claimIncentives() external {
        require(poolStatus == PoolStatus.NOT_QUALIFIED, "INS");
        require(msg.sender == genesisInfo.tokenOwner, "NA");

        uint256 _incentivesCnt = incentiveTokens.length;
        uint256 i;
        uint _amount;

        for (i = 0; i < _incentivesCnt; i++) {
            _amount = incentives[incentiveTokens[i]];
            incentives[incentiveTokens[i]] = 0;

            IERC20(incentiveTokens[i]).safeTransfer(msg.sender, _amount);
        }
    }

    function balanceOf(address account) external view returns (uint256) {
        uint256 _depositerLiquidity = liquidity / 2;
        uint256 balance = (_depositerLiquidity * userDeposits[account]) /
            totalDeposits;
        if (account == genesisInfo.tokenOwner)
            balance += (liquidity - _depositerLiquidity - tokenOwnerUnstaked);
        return balance;
    }

    function deductAmount(
        address account,
        uint256 gaugeTokenAmount
    ) external onlyGauge {
        uint256 _depositerLiquidity = liquidity / 2;
        uint256 userAmount = (totalDeposits * gaugeTokenAmount) /
            _depositerLiquidity;

        if (account == genesisInfo.tokenOwner) {
            uint256 pendingOwnerStaked = liquidity -
                _depositerLiquidity -
                tokenOwnerUnstaked;

            if (gaugeTokenAmount < pendingOwnerStaked) {
                tokenOwnerUnstaked += gaugeTokenAmount;
                userAmount = 0;
            } else {
                tokenOwnerUnstaked = liquidity - _depositerLiquidity;
                userAmount -=
                    (totalDeposits * pendingOwnerStaked) /
                    _depositerLiquidity;
            }
        }
        userDeposits[account] -= userAmount;
    }

    function deductAllAmount(address account) external onlyGauge {
        uint256 _depositerLiquidity = liquidity / 2;
        if (account == genesisInfo.tokenOwner)
            tokenOwnerUnstaked = liquidity - _depositerLiquidity;
        userDeposits[account] = 0;
    }

    function getNativeTokenAmount(
        uint256 depositAmount
    ) external view returns (uint256) {
        if (depositAmount <= 0) return 0;
        return _getNativeTokenAmount(depositAmount);
    }

    function _getNativeTokenAmount(
        uint256 depositAmount
    ) internal view returns (uint256) {
        return auction.getNativeTokenAmount(depositAmount);
    }

    function getFundingTokenAmount(
        uint256 nativeAmount
    ) external view returns (uint256) {
        if (nativeAmount <= 0) return 0;
        return _getFundingTokenAmount(nativeAmount);
    }

    function _getFundingTokenAmount(
        uint256 nativeAmount
    ) internal view returns (uint256) {
        return auction.getFundingTokenAmount(nativeAmount);
    }

    function getAllocationInfo()
        external
        view
        returns (TokenAllocation memory)
    {
        return allocationInfo;
    }

    function getIncentivesInfo()
        external
        view
        returns (IGenesisPoolBase.TokenIncentiveInfo memory incentiveInfo)
    {
        uint256 incentivesCnt = incentiveTokens.length;
        incentiveInfo.incentivesToken = new address[](incentivesCnt);
        incentiveInfo.incentivesAmount = new uint256[](incentivesCnt);
        uint256 i;
        for (i = 0; i < incentivesCnt; i++) {
            incentiveInfo.incentivesToken[i] = incentiveTokens[i];
            incentiveInfo.incentivesAmount[i] = incentives[incentiveTokens[i]];
        }
    }

    function getGenesisInfo()
        external
        view
        returns (IGenesisPoolBase.GenesisInfo memory)
    {
        return genesisInfo;
    }

    function getLiquidityPoolInfo()
        external
        view
        returns (IGenesisPoolBase.LiquidityPool memory)
    {
        return liquidityPoolInfo;
    }

    function setAuction(address _auction) external onlyManagerOrProtocol {
        require(_auction != address(0), "ZA");
        require(poolStatus == PoolStatus.NATIVE_TOKEN_DEPOSITED, "INS");
        auction = IAuction(_auction);
    }

    function setMaturityTime(uint256 _maturityTime) external onlyManager {
        genesisInfo.maturityTime = _maturityTime;
    }

    function setStartTime(uint256 _startTime) external onlyManager {
        _startTime = BlackTimeLibrary.epochStart(_startTime);
        require(
            _startTime +
                genesisInfo.duration -
                BlackTimeLibrary.NO_GENESIS_DEPOSIT_WINDOW >
                block.timestamp,
            "TIME"
        );
        genesisInfo.startTime = _startTime;
    }
}
