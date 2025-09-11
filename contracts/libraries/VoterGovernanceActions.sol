// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VoterStorage} from "contracts/libraries/VoterStorage.sol";
import {Errors} from "contracts/libraries/Errors.sol";

import {IAccessHub} from "contracts/interfaces/IAccessHub.sol";
import {IRamsesV3Factory} from "contracts/CL/core/interfaces/IRamsesV3Factory.sol";
import {INonfungiblePositionManager} from "contracts/CL/periphery/interfaces/INonfungiblePositionManager.sol";
import {IGauge} from "contracts/interfaces/IGauge.sol";
import {IGaugeV3} from "contracts/CL/gauge/interfaces/IGaugeV3.sol";
import {IClGaugeFactory} from "contracts/CL/gauge/interfaces/IClGaugeFactory.sol";
import {IVoteModule} from "contracts/interfaces/IVoteModule.sol";
import {IFeeDistributor} from "contracts/interfaces/IFeeDistributor.sol";
import {IXRex} from "contracts/interfaces/IXRex.sol";
import {IPair} from "contracts/interfaces/IPair.sol";
import {IPairFactory} from "contracts/interfaces/IPairFactory.sol";
import {IRouter} from "contracts/interfaces/IRouter.sol";
import {IVoter} from "contracts/interfaces/IVoter.sol";
import {IFeeRecipientFactory} from "contracts/interfaces/IFeeRecipientFactory.sol";
import {IGaugeFactory} from "contracts/interfaces/IGaugeFactory.sol";
import {IFeeRecipient} from "contracts/interfaces/IFeeRecipient.sol";
import {IFeeDistributorFactory} from "contracts/interfaces/IFeeDistributorFactory.sol";
import {IRamsesV3Pool} from "contracts/CL/core/interfaces/IRamsesV3Pool.sol";

/// @title VoterGovernanceActions
/// @notice Governance logic for Voter
/// @dev Used to reduce Voter contract size by moving all governance related logic to a library
library VoterGovernanceActions {
    event FeeDistributorUpdated(address indexed gauge, address oldFeeDistributor, address newFeeDistributor);   
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 internal constant DURATION = 7 days;
    uint256 public constant BASIS = 1_000_000;
    uint256 public constant OLD_LEGACY_FEE_SPLIT_BASIS = 10_000;

    function setGlobalRatio(uint256 _xRatio) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        require(_xRatio <= BASIS, Errors.RATIO_TOO_HIGH(_xRatio));

        emit IVoter.EmissionsRatio(msg.sender, $.xRatio, _xRatio);
        $.xRatio = _xRatio;
    }

    function setGovernor(address _governor) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        if ($.governor != _governor) {
            $.governor = _governor;
            emit IVoter.NewGovernor(msg.sender, _governor);
        }
    }



    function whitelist(address _token) public {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        require(!$.isWhitelisted[_token], Errors.ALREADY_WHITELISTED(_token));
        $.isWhitelisted[_token] = true;
        emit IVoter.Whitelisted(msg.sender, _token);
    }

    function revokeWhitelist(address _token) public {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        require($.isWhitelisted[_token], Errors.NOT_WHITELISTED(_token));
        $.isWhitelisted[_token] = false;
        emit IVoter.WhitelistRevoked(msg.sender, _token);
    }

    function killGauge(address _gauge) public {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev ensure the gauge is alive already, and exists
        require($.isAlive[_gauge] && $.gauges.contains(_gauge), Errors.GAUGE_INACTIVE(_gauge));
        /// @dev set the gauge to dead
        $.isAlive[_gauge] = false;
        address pool = $.poolForGauge[_gauge];

        /// @dev fetch the last distribution
        uint256 _lastDistro = $.lastDistro[_gauge];
        /// @dev fetch the current period
        uint256 currentPeriod = getPeriod();
        /// @dev placeholder
        uint256 _claimable;
        /// @dev loop through the last distribution period up to and including the current period
        for (uint256 period = _lastDistro; period <= currentPeriod; ++period) {
            /// @dev if the gauge isn't distributed for the period
            if (!$.gaugePeriodDistributed[_gauge][period]) {
                uint256 additionalClaimable = _claimablePerPeriod(pool, period);
                _claimable += additionalClaimable;

                /// @dev prevent gaugePeriodDistributed being marked true when the minter hasn't updated yet
                if (additionalClaimable > 0) {
                    $.gaugePeriodDistributed[_gauge][period] = true;
                }
            }
        }
        /// @dev if there is anything claimable left
        if (_claimable > 0) {
            /// @dev send to the governor contract
            IERC20($.ram).transfer($.governor, _claimable);
        }

        /// @dev we dont update lastDistro here so distribute can still be called to pass if revived

        emit IVoter.GaugeKilled(_gauge);
    }

    function reviveGauge(address _gauge) public {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev ensure the gauge is dead and exists
        require(!$.isAlive[_gauge] && $.gauges.contains(_gauge), Errors.ACTIVE_GAUGE(_gauge));
        /// @dev set the gauge to alive
        $.isAlive[_gauge] = true;
        /// @dev check if it's a legacy gauge
        if ($.isLegacyGauge[_gauge]) {
            address pool = $.poolForGauge[_gauge];

            /// @dev MarbleMinter will handle the fee redirection to feeDist
            /// @dev review this for fresh deployments
            // address feeRecipient = IFeeRecipientFactory($.feeRecipientFactory).feeRecipientForPair(pool);
            // IPairFactory($.legacyFactory).setFeeRecipient(pool, feeRecipient);

            /// @dev revert back to the 100% feeSplit going to feeRecipient
            // IPairFactory($.legacyFactory).setPairFeeSplit(pool, BASIS);

            address[] memory pools = new address[](1);
            uint256[] memory feeSplits = new uint256[](1);

            pools[0] = pool;
            feeSplits[0] = OLD_LEGACY_FEE_SPLIT_BASIS;

            IAccessHub($.accessHub).setFeeSplitLegacy(pools, feeSplits);
        }

        /// @dev we dont update lastDistro here so distribute can still be called to pass fees

        emit IVoter.GaugeRevived(_gauge);
    }

    function createGauge(address _pool) external returns (address) {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev ensure there is no gauge for the pool
        require($.gaugeForPool[_pool] == address(0), Errors.ACTIVE_GAUGE($.gaugeForPool[_pool]));
        /// @dev check if it's a legacy pair
        bool isPair = IPairFactory($.legacyFactory).isPair(_pool);
        require(isPair, Errors.NOT_POOL(_pool));
        /// @dev fetch token0 and token1 from the pool's metadata
        (,,,,, address token0, address token1) = IPair(_pool).metadata();
        /// @dev ensure that both tokens are whitelisted
        require($.isWhitelisted[token0] && $.isWhitelisted[token1], Errors.BOTH_NOT_WHITELISTED());

        /// @dev create the feeRecipient via the factory
        address feeRecipient = IFeeRecipientFactory($.feeRecipientFactory).createFeeRecipient(_pool);
        /// @dev create the feeDist via factory from the feeRecipient
        address _feeDistributor = IFeeDistributorFactory($.feeDistributorFactory).createFeeDistributor(feeRecipient);
        /// @dev init feeRecipient with the feeDist
        IFeeRecipient(feeRecipient).initialize(_feeDistributor);

        /// @dev set the feeRecipient in the factory
        IPairFactory($.legacyFactory).setFeeRecipient(_pool, feeRecipient);

        /// @dev create a legacy gauge from the factory
        address _gauge = IGaugeFactory($.gaugeFactory).createGauge(_pool);
        /// @dev give infinite approvals in advance
        IERC20($.ram).approve(_gauge, type(uint256).max);
        IERC20($.xRam).approve(_gauge, type(uint256).max);
        /// @dev update voter mappings
        $.feeDistributorForGauge[_gauge] = _feeDistributor;
        $.originalFeeDistributorForGauge[_gauge] = _feeDistributor;
        $.gaugeForPool[_pool] = _gauge;
        $.poolForGauge[_gauge] = _pool;
        $.poolForFeeDistributor[_feeDistributor] = _pool;
        /// @dev set gauge to alive
        $.isAlive[_gauge] = true;
        /// @dev add to the sets
        $.pools.add(_pool);
        $.gauges.add(_gauge);
        $.feeDistributors.add(_feeDistributor);
        /// @dev set true that it is a legacy gauge
        $.isLegacyGauge[_gauge] = true;
        /// @dev set the last distribution as the current period
        $.lastDistro[_gauge] = getPeriod();
        /// @dev emit the gauge creation event
        emit IVoter.GaugeCreated(_gauge, msg.sender, _feeDistributor, _pool);

        /// @dev set up fee redirection
        // IMarbleMinter($.minter).postCreateLegacyGaugeHook(_pool);

        /// @dev whitelist gauge and feeDist to transfer xRam
        // IAccessHub($.accessHub).whitelistGaugeAndFeeDistributorOnXRam(_gauge, _feeDistributor);

        /// @dev return the new created gauge address
        return _gauge;
    }

    function createCLGauge(address tokenA, address tokenB, int24 tickSpacing) external returns (address) {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        IRamsesV3Factory _factory = IRamsesV3Factory($.clFactory);
        /// @dev fetch the V3 pool's address
        address _pool = _factory.getPool(tokenA, tokenB, tickSpacing);
        /// @dev require the pool exists
        require(_pool != address(0), Errors.NOT_POOL(_pool));
        /// @dev check the reentrancy lock
        (,,,,,, bool unlocked) = IRamsesV3Pool(_pool).slot0();
        /// @dev require it is unlocked, else it is considered not initialized
        require(unlocked, Errors.NOT_INIT());
        /// @dev ensure a gauge does not already exist for the pool
        require($.gaugeForPool[_pool] == address(0), Errors.ACTIVE_GAUGE($.gaugeForPool[_pool]));
        /// @dev ensure both tokens are whitelisted
        require($.isWhitelisted[tokenA] && $.isWhitelisted[tokenB], Errors.BOTH_NOT_WHITELISTED());
        /// @dev fetch the feeCollector
        address _feeCollector = _factory.feeCollector();

        /// @dev sort tokens
        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        /// @dev create a FeeDistributor if needed
        address _feeDistributor = $.feeDistributorForClPair[token0][token1];
        if (_feeDistributor == address(0)) {
            _feeDistributor = IFeeDistributorFactory($.feeDistributorFactory).createFeeDistributor(_feeCollector);
            $.feeDistributorForClPair[token0][token1] = _feeDistributor;
        }

        /// @dev create the gauge
        address _gauge = IClGaugeFactory($.clGaugeFactory).createGauge(_pool);
        /// @dev unlimited approve ram and xRam to the gauge
        IERC20($.ram).approve(_gauge, type(uint256).max);
        IERC20($.xRam).approve(_gauge, type(uint256).max);
        /// @dev update mappings
        $.feeDistributorForGauge[_gauge] = _feeDistributor;
        $.originalFeeDistributorForGauge[_gauge] = _feeDistributor;
        $.gaugeForPool[_pool] = _gauge;
        $.poolForGauge[_gauge] = _pool;
        $.poolForFeeDistributor[_feeDistributor] = _pool;
        $.lastDistro[_gauge] = getPeriod();
        $.pools.add(_pool);
        $.gauges.add(_gauge);
        $.feeDistributors.add(_feeDistributor);
        $.isClGauge[_gauge] = true;
        $._tickSpacingsForPair[token0][token1].push(tickSpacing);
        $._gaugeForClPool[token0][token1][tickSpacing] = _gauge;
        $.isAlive[_gauge] = true;

        /// @dev add this new gauge to the enumerable set
        $.gaugesForClPair[token0][token1].add(_gauge);

        /// @dev redirect gauges for the same cl pair to the new gauge
        /// governance most likely made this new gauge to replace others
        redirectEmissions(token0, token1, _gauge);

        /// @dev whitelist gauge and feeDist to transfer xRam
        // IAccessHub($.accessHub).whitelistGaugeAndFeeDistributorOnXRam(_gauge, _feeDistributor);

        emit IVoter.GaugeCreated(_gauge, msg.sender, _feeDistributor, _pool);

        return _gauge;
    }

    function redirectEmissions(address tokenA, address tokenB, address destinationGauge) public {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev sort tokens
        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        EnumerableSet.AddressSet storage _gaugesForClPair = $.gaugesForClPair[token0][token1];

        /// @dev require the destination gauge to be of the same token0/token1 pair
        require(_gaugesForClPair.contains(destinationGauge), Errors.GAUGE_INACTIVE(destinationGauge));

        /// @dev redirect the gauges
        uint256 length = _gaugesForClPair.length();
        for (uint256 i; i < length; i++) {
            address sourceGauge = _gaugesForClPair.at(i);
            $.gaugeRedirect[sourceGauge] = destinationGauge;

            emit IVoter.EmissionsRedirected(sourceGauge, destinationGauge);

            /// @dev kill the gauge if it's not the main gauge
            if (sourceGauge != destinationGauge && $.isAlive[sourceGauge]) {
                killGauge(sourceGauge);
            }
        }
    }

    /// @dev in case of emission stuck due to killed gauges and unsupported operations
    function stuckEmissionsRecovery(address _gauge, uint256 _period) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev require gauge is dead
        require(!$.isAlive[_gauge], Errors.ACTIVE_GAUGE(_gauge));

        /// @dev ensure the gauge exists
        require($.gauges.contains(_gauge), Errors.GAUGE_INACTIVE(_gauge));

        /// @dev check if the period has been distributed already
        if (!$.gaugePeriodDistributed[_gauge][_period]) {
            address pool = $.poolForGauge[_gauge];
            uint256 _claimable = _claimablePerPeriod(pool, _period);
            /// @dev if there is gt 0 emissions, send to governor
            if (_claimable > 0) {
                IERC20($.ram).transfer($.governor, _claimable);
                /// @dev mark period as distributed
                $.gaugePeriodDistributed[_gauge][_period] = true;
            }
        }
    }

    function removeFeeDistributorReward(address _feeDistributor, address reward) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev ensure the feeDist exists
        require($.feeDistributors.contains(_feeDistributor));
        IFeeDistributor(_feeDistributor).removeReward(reward);
    }

    /// @notice Update FeeDistributor for a gauge (emergency governance function)
    function updateFeeDistributorForGauge(address _gauge, address _newFeeDistributor) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();
        
        require($.poolForGauge[_gauge] != address(0), "Invalid gauge");
        require(_newFeeDistributor != address(0), "Zero address");
        
        address oldFeeDistributor = $.feeDistributorForGauge[_gauge];
        
        // Update mappings
        $.feeDistributorForGauge[_gauge] = _newFeeDistributor;
        $.poolForFeeDistributor[_newFeeDistributor] = $.poolForGauge[_gauge];
        
        // Update the sets if needed
        if (oldFeeDistributor != address(0)) {
            $.feeDistributors.remove(oldFeeDistributor);
        }
        $.feeDistributors.add(_newFeeDistributor);
        
        emit FeeDistributorUpdated(_gauge, oldFeeDistributor, _newFeeDistributor);
    }

    /// @notice Create a new FeeDistributor with specified feeRecipient (emergency governance function)
    function createFeeDistributorWithRecipient(address _feeRecipient) external returns (address) {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();
        
        // Create the FeeDistributor (msg.sender will be the Voter contract)
        address _feeDistributor = IFeeDistributorFactory($.feeDistributorFactory).createFeeDistributor(_feeRecipient);
        
        // Add to the feeDistributors set
        $.feeDistributors.add(_feeDistributor);
        
        return _feeDistributor;
    }

    function setNfpManager(address _newNfpManager) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        $.nfpManager = _newNfpManager;
        IClGaugeFactory($.clGaugeFactory).setNfpManager(_newNfpManager);
    }

    function getPeriod() private view returns (uint256 period) {
        return (block.timestamp / 1 weeks);
    }

    /// @dev shows how much is claimable per period
    function _claimablePerPeriod(address pool, uint256 period) private view returns (uint256) {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        uint256 numerator = ($.totalRewardPerPeriod[period] * $.poolTotalVotesPerPeriod[pool][period]) * 1e18;

        /// @dev return 0 if this happens, or else there could be a divide by zero next
        return (numerator == 0 ? 0 : (numerator / $.totalVotesPerPeriod[period] / 1e18));
    }

    /// @dev sorts the two tokens
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        token0 = tokenA < tokenB ? tokenA : tokenB;
        token1 = token0 == tokenA ? tokenB : tokenA;
    }
}
