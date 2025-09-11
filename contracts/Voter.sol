// SPDX-License-Identifier: kBUSL-1.1
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {VoterRewardClaimers} from "./libraries/VoterRewardClaimers.sol";

import {IAccessHub} from "./interfaces/IAccessHub.sol";
import {IMinter} from "./interfaces/IMinter.sol";
import {IPair} from "./interfaces/IPair.sol";
import {IPairFactory} from "./interfaces/IPairFactory.sol";
import {IFeeRecipient} from "./interfaces/IFeeRecipient.sol";
import {IFeeRecipientFactory} from "./interfaces/IFeeRecipientFactory.sol";

import {IRamsesV3Factory} from "./CL/core/interfaces/IRamsesV3Factory.sol";
import {IRamsesV3Pool} from "./CL/core/interfaces/IRamsesV3Pool.sol";
import {IClGaugeFactory} from "./CL/gauge/interfaces/IClGaugeFactory.sol";
import {IFeeCollector} from "./CL/gauge/interfaces/IFeeCollector.sol";
import {GaugeV3} from "./CL/gauge/GaugeV3.sol";

import {IVoteModule} from "./interfaces/IVoteModule.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {Errors} from "contracts/libraries/Errors.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {IFeeDistributorFactory} from "./interfaces/IFeeDistributorFactory.sol";
import {IGauge} from "./interfaces/IGauge.sol";
import {IGaugeFactory} from "./interfaces/IGaugeFactory.sol";
import {IXRex} from "./interfaces/IXRex.sol";

import {VoterStorage} from "./libraries/VoterStorage.sol";
import {VoterGovernanceActions} from "./libraries/VoterGovernanceActions.sol";

contract Voter is IVoter, ReentrancyGuard, Initializable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev internal duration constant
    uint256 internal constant DURATION = 7 days;
    /// @inheritdoc IVoter
    uint256 public constant BASIS = 1_000_000;

    modifier onlyGovernance() {
        _onlyGovernance();
        _;
    }

    function _onlyGovernance() internal view {
        require(msg.sender == VoterStorage.getStorage().accessHub, Errors.NOT_AUTHORIZED(msg.sender));
    }

    constructor() {
        _disableInitializers();
    }

    /// @dev should be called with upgradeToAndInitialize
    function initializeAccessHub(address _accessHub) external initializer {
        VoterStorage.getStorage().accessHub = _accessHub;
    }

    /// @dev separated from initializeAccessHub to minimize changes to deployment scripts
    function initialize(InitializationParams memory inputs) external reinitializer(2) {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev ensure only accessHub can initialize
        require($.accessHub == msg.sender, Errors.NOT_AUTHORIZED(msg.sender));
        $.legacyFactory = inputs.legacyFactory;
        $.ram = inputs.ram;
        $.gaugeFactory = inputs.gauges;
        $.feeDistributorFactory = inputs.feeDistributorFactory;
        $.minter = inputs.minter;
        $.xRam = inputs.xRam;
        $.governor = inputs.msig;
        $.feeRecipientFactory = inputs.feeRecipientFactory;
        $.voteModule = inputs.voteModule;

        $.clFactory = inputs.clFactory;
        $.clGaugeFactory = inputs.clGaugeFactory;
        $.nfpManager = inputs.nfpManager;
        
        // initialize the authorizedClaimers set with the initial nfpManager + Voter
        if (inputs.nfpManager != address(0)) {
            $.authorizedClaimers.add(inputs.nfpManager);
        }
        $.authorizedClaimers.add(address(this));
        $.timeThresholdForRewarder = 60;
        /// @dev default at 0% xRatio
        $.xRatio = 0;
        /// @dev emits from the zero address since it's the first time
        emit EmissionsRatio(address(0), 0, 0);
        /// @dev perma approval
        IERC20(inputs.ram).approve(inputs.xRam, type(uint256).max);

        /// @dev whitelist ram and xram
        $.isWhitelisted[inputs.ram] = true;
        emit Whitelisted(msg.sender, inputs.ram);
        $.isWhitelisted[inputs.xRam] = true;
        emit Whitelisted(msg.sender, inputs.xRam);
    }

    function transferOwnership(address _newAccessHub) external onlyGovernance {
        VoterStorage.getStorage().accessHub = _newAccessHub;
    }

    ////////////////////
    // View Functions //
    ////////////////////

    /// @inheritdoc IVoter
    function getVotes(address user, uint256 period)
        external
        view
        returns (address[] memory votes, uint256[] memory weights)
    {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev fetch the user's voted pools for the period
        votes = $.userVotedPoolsPerPeriod[user][period];
        /// @dev set weights array length equal to the votes length
        weights = new uint256[](votes.length);
        /// @dev loop through the votes and populate the weights
        for (uint256 i; i < votes.length; ++i) {
            weights[i] = $.userVotesForPoolPerPeriod[user][period][votes[i]];
        }
    }

    /// @inheritdoc IVoter
    function legacyFactory() external view returns (address) {
        return VoterStorage.getStorage().legacyFactory;
    }

    /// @inheritdoc IVoter
    function ram() external view returns (address) {
        return VoterStorage.getStorage().ram;
    }

    /// @inheritdoc IVoter
    function gaugeFactory() external view returns (address) {
        return VoterStorage.getStorage().gaugeFactory;
    }

    /// @inheritdoc IVoter
    function feeDistributorFactory() external view returns (address) {
        return VoterStorage.getStorage().feeDistributorFactory;
    }

    /// @inheritdoc IVoter
    function minter() external view returns (address) {
        return VoterStorage.getStorage().minter;
    }

    /// @inheritdoc IVoter
    function accessHub() external view returns (address) {
        return VoterStorage.getStorage().accessHub;
    }

    /// @inheritdoc IVoter
    function governor() external view returns (address) {
        return VoterStorage.getStorage().governor;
    }

    /// @inheritdoc IVoter
    function clFactory() external view returns (address) {
        return VoterStorage.getStorage().clFactory;
    }

    /// @inheritdoc IVoter
    function clGaugeFactory() external view returns (address) {
        return VoterStorage.getStorage().clGaugeFactory;
    }


    /// @inheritdoc IVoter
    function nfpManager() external view returns (address) {
        return VoterStorage.getStorage().nfpManager;
    }

    /// @inheritdoc IVoter
    function feeRecipientFactory() external view returns (address) {
        return VoterStorage.getStorage().feeRecipientFactory;
    }

    /// @inheritdoc IVoter
    function xRam() external view returns (address) {
        return VoterStorage.getStorage().xRam;
    }

    /// @inheritdoc IVoter
    function voteModule() external view returns (address) {
        return VoterStorage.getStorage().voteModule;
    }

    /// @inheritdoc IVoter
    function xRatio() external view returns (uint256) {
        return VoterStorage.getStorage().xRatio;
    }

 
    function gaugeForPool(address pool) external view returns (address) {
        return VoterStorage.getStorage().gaugeForPool[pool];
    }

    function poolForGauge(address gauge) external view returns (address) {
        return VoterStorage.getStorage().poolForGauge[gauge];
    }

    function feeDistributorForGauge(address gauge) external view returns (address) {
        return VoterStorage.getStorage().feeDistributorForGauge[gauge];
    }

    function poolTotalVotesPerPeriod(address pool, uint256 period) external view returns (uint256) {
        return VoterStorage.getStorage().poolTotalVotesPerPeriod[pool][period];
    }

    function userVotesForPoolPerPeriod(address user, uint256 period, address pool) external view returns (uint256) {
        return VoterStorage.getStorage().userVotesForPoolPerPeriod[user][period][pool];
    }

    function userVotedPoolsPerPeriod(address user, uint256 period, uint256 index) external view returns (address) {
        return VoterStorage.getStorage().userVotedPoolsPerPeriod[user][period][index];
    }

    function userVotedPoolsPerPeriodLength(address user, uint256 period) external view returns (uint256) {
        return VoterStorage.getStorage().userVotedPoolsPerPeriod[user][period].length;
    }

    function getAllUserVotedPoolsPerPeriod(address user, uint256 period) external view returns (address[] memory) {
        return VoterStorage.getStorage().userVotedPoolsPerPeriod[user][period];
    }

    function userVotingPowerPerPeriod(address user, uint256 period) external view returns (uint256) {
        return VoterStorage.getStorage().userVotingPowerPerPeriod[user][period];
    }

    function lastVoted(address user) external view returns (uint256) {
        return VoterStorage.getStorage().lastVoted[user];
    }

    function totalRewardPerPeriod(uint256 period) external view returns (uint256) {
        return VoterStorage.getStorage().totalRewardPerPeriod[period];
    }

    function totalVotesPerPeriod(uint256 period) external view returns (uint256) {
        return VoterStorage.getStorage().totalVotesPerPeriod[period];
    }

    function gaugeRewardsPerPeriod(address gauge, uint256 period) external view returns (uint256) {
        return VoterStorage.getStorage().gaugeRewardsPerPeriod[gauge][period];
    }

    function gaugePeriodDistributed(address gauge, uint256 period) external view returns (bool) {
        return VoterStorage.getStorage().gaugePeriodDistributed[gauge][period];
    }

    function lastDistro(address gauge) external view returns (uint256) {
        return VoterStorage.getStorage().lastDistro[gauge];
    }

    function isLegacyGauge(address gauge) external view returns (bool) {
        return VoterStorage.getStorage().isLegacyGauge[gauge];
    }

    function isClGauge(address gauge) external view returns (bool) {
        return VoterStorage.getStorage().isClGauge[gauge];
    }

    function isWhitelisted(address token) external view returns (bool) {
        return VoterStorage.getStorage().isWhitelisted[token];
    }

    function isAlive(address gauge) external view returns (bool) {
        return VoterStorage.getStorage().isAlive[gauge];
    }

    function poolForFeeDistributor(address feeDist) external view returns (address) {
        return VoterStorage.getStorage().poolForFeeDistributor[feeDist];
    }

    /// @inheritdoc IVoter
    function getPeriod() public view returns (uint256 period) {
        return (block.timestamp / 1 weeks);
    }

    ////////////
    // Voting //
    ////////////

    /// @inheritdoc IVoter
    function reset(address user) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev if the caller isn't the user
        if (msg.sender != user) {
            /// @dev check for delegation
            require(
                IVoteModule($.voteModule).isDelegateFor(msg.sender, user) || msg.sender == $.accessHub,
                Errors.NOT_AUTHORIZED(msg.sender)
            );
        }
        _reset(user);

        $.lastVoted[user] = getPeriod();
    }

    function _reset(address user) internal {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev voting for the next period
        uint256 nextPeriod = getPeriod() + 1;
        /// @dev fetch the previously voted pools
        address[] memory votedPools = $.userVotedPoolsPerPeriod[user][nextPeriod];
        /// @dev fetch the user's stored voting power for the voting period
        uint256 votingPower = $.userVotingPowerPerPeriod[user][nextPeriod];
        /// @dev if an existing vote is cast
        if (votingPower > 0) {
            /// @dev loop through the pools
            for (uint256 i; i < votedPools.length; ++i) {
                /// @dev fetch the individual casted for the pool for the next period
                uint256 userVote = $.userVotesForPoolPerPeriod[user][nextPeriod][votedPools[i]];
                /// @dev decrement the total vote by the existing vote
                $.poolTotalVotesPerPeriod[votedPools[i]][nextPeriod] -= userVote;
                /// @dev wipe the mapping
                delete $.userVotesForPoolPerPeriod[user][nextPeriod][votedPools[i]];
                /// @dev call _withdraw on the FeeDistributor
                IFeeDistributor feeDist =
                    IFeeDistributor($.feeDistributorForGauge[$.gaugeForPool[votedPools[i]]]);
                uint256 currentAmount = feeDist.userVotes(nextPeriod, user);
                if (currentAmount > 0) {
                    IFeeDistributor(feeDist)._withdraw(currentAmount, user);
                }
            }
            /// @dev reduce the overall vote power casted
            $.totalVotesPerPeriod[nextPeriod] -= votingPower;
            /// @dev wipe the mappings
            delete $.userVotingPowerPerPeriod[user][nextPeriod];
            delete $.userVotedPoolsPerPeriod[user][nextPeriod];
        }
    }

    /// @inheritdoc IVoter
    function poke(address user) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev ensure the caller is either the user or the vote module
        if (msg.sender != user) {
            /// @dev ...require they are authorized to be a delegate
            require(
                IVoteModule($.voteModule).isDelegateFor(msg.sender, user) || msg.sender == $.voteModule
                    || msg.sender == $.accessHub,
                Errors.NOT_AUTHORIZED(msg.sender)
            );
        }
        uint256 _lastVoted = $.lastVoted[user];
        /// @dev has no prior vote, terminate early
        if (_lastVoted == 0) return;
        /// @dev fetch the last voted pools since votes are casted into the next week's mapping
        address[] memory votedPools = $.userVotedPoolsPerPeriod[user][_lastVoted + 1];
        /// @dev fetch the voting power of the user in that period after
        uint256 userVotePower = $.userVotingPowerPerPeriod[user][_lastVoted + 1];
        /// @dev if nothing, terminate
        if (userVotePower == 0) return;

        uint256[] memory voteWeights = new uint256[](votedPools.length);
        /// @dev loop and fetch weights
        for (uint256 i; i < votedPools.length; i++) {
            voteWeights[i] = $.userVotesForPoolPerPeriod[user][_lastVoted + 1][votedPools[i]];
        }
        /// @dev recast with new voting power and same weights/pools as prior
        _vote(user, votedPools, voteWeights);
        emit Poke(user);
    }
    /// @inheritdoc IVoter
    /**
     * important information on the mappings (since it is quite confusing):
     * - userVotedPoolsPerPeriod is stored in the NEXT period when triggered
     * - userVotingPowerPerPeriod  is stored in the NEXT period
     * - userVotesForPoolPerPeriod is stored in the NEXT period
     * - poolTotalVotesPerPeriod is stored in the NEXT period
     * - lastVoted is stored in the CURRENT period
     */

    function vote(address user, address[] calldata _pools, uint256[] calldata _weights) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev ensure that the arrays length matches and that the length is > 0
        require(_pools.length > 0 && _pools.length == _weights.length, Errors.LENGTH_MISMATCH());
        /// @dev if the caller isn't the user...
        if (msg.sender != user) {
            /// @dev ...require they are authorized to be a delegate
            require(
                IVoteModule($.voteModule).isDelegateFor(msg.sender, user) || msg.sender == $.accessHub,
                Errors.NOT_AUTHORIZED(msg.sender)
            );
        }

        /// @dev cast new votes
        _vote(user, _pools, _weights);
    }

    function _vote(address user, address[] memory _pools, uint256[] memory _weights) internal {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev wipe all votes if needed, the checks are in _reset()
        /// @dev keep this here, DO NOT REMOVE THIS. The gas saving isn't worth it
        /// @dev Prevents footguns where _vote() is called without resetting
        _reset(user);

        /// @dev grab the nextPeriod
        uint256 nextPeriod = getPeriod() + 1;
        /// @dev fetch the user's votingPower
        uint256 votingPower = IVoteModule($.voteModule).balanceOf(user);

        /// @dev loop through and add up the amounts, we do this because weights are proportions and not directly the vote power values
        uint256 totalVoteWeight;
        for (uint256 i; i < _pools.length; i++) {
            totalVoteWeight += _weights[i];
        }
        /// @dev if totalVoteWeight is 0, make it a 1 instead and let the rest of the tx go through
        /// incase anything else needs to be written
        /// early returns can be a footgun here if some data are written to storage and others not
        if (totalVoteWeight == 0) {
            totalVoteWeight = 1;
        }

        /// @dev assign variables for validation
        address[] memory validPools = new address[](_pools.length);
        uint256 validTotalWeight;
        uint256 validPoolLength;

        /// @dev loop through all pools
        for (uint256 i; i < _pools.length; i++) {
            /// @dev fetch the gauge for the pool
            address _gauge = $.gaugeForPool[_pools[i]];
            /// @dev skip if dead gauge
            if (!$.isAlive[_gauge]) {
                continue;
            }
            /// @dev scale the weight of the pool
            uint256 _poolWeight = (_weights[i] * votingPower) / totalVoteWeight;
            /// @dev skip if 0 weight
            if (_poolWeight == 0) {
                continue;
            }
            /// @dev skip if repeat vote
            if ($.userVotesForPoolPerPeriod[user][nextPeriod][_pools[i]] != 0) {
                continue;
            }
            /// @dev add to valid pools and valid total weights
            validPools[validPoolLength] = _pools[i];
            validTotalWeight += _poolWeight;
            validPoolLength++;

            /// @dev increment to the votes for this pool
            $.poolTotalVotesPerPeriod[_pools[i]][nextPeriod] += _poolWeight;
            /// @dev increment the user's votes for this pool
            $.userVotesForPoolPerPeriod[user][nextPeriod][_pools[i]] += _poolWeight;
            /// @dev deposit the votes to the FeeDistributor
            IFeeDistributor($.feeDistributorForGauge[_gauge])._deposit(_poolWeight, user);
            /// @dev emit the voted event, passing the user and the raw vote weight given to the pool
            emit Voted(user, _poolWeight, _pools[i]);
        }

        /// @dev trim length if needed
        if (validPoolLength != validPools.length) {
            assembly ("memory-safe") {
                mstore(validPools, validPoolLength)
            }
        }

        /// @dev set the voting power for the user for the period
        $.userVotingPowerPerPeriod[user][nextPeriod] = validTotalWeight;
        /// @dev update the pools voted for
        $.userVotedPoolsPerPeriod[user][nextPeriod] = validPools;

        /// @dev increment to the total
        $.totalVotesPerPeriod[nextPeriod] += validTotalWeight;
        /// @dev last vote as current epoch
        $.lastVoted[user] = nextPeriod - 1;

        $.votedUsersPerPeriod[nextPeriod].add(user);
    }

    ///////////////////////////
    // Emission Distribution //
    ///////////////////////////

    function _distribute(address _gauge, uint256 _claimable, uint256 _period) internal {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev check if the gauge is even alive
        if ($.isAlive[_gauge]) {
            /// @dev if there is 0 claimable terminate
            if (_claimable == 0) return;
            /// @dev if the gauge is already distributed for the period, terminate
            if ($.gaugePeriodDistributed[_gauge][_period]) return;

            /// @dev fetch ram address
            address _xRam = address($.xRam);
            /// @dev fetch the current ratio and multiply by the claimable
            uint256 _xRamClaimable = (_claimable * $.xRatio) / BASIS;
            /// @dev remove from the regular claimable tokens (RAM)
            _claimable -= _xRamClaimable;

            /// @dev can only distribute if the distributed amount / week > 0 and is > left()
            bool canDistribute = true;

            /// @dev _claimable could be 0 if emission is 100% xRam
            if (_claimable > 0) {
                if (
                    _claimable / DURATION == 0
                        || (_claimable < IGauge(_gauge).left($.ram) && $.isLegacyGauge[_gauge])
                ) {
                    canDistribute = false;
                }
            }
            /// @dev _xRamClaimable could be 0 if ratio is 100% emissions
            if (_xRamClaimable > 0) {
                if (
                    _xRamClaimable / DURATION == 0
                        || (_xRamClaimable < IGauge(_gauge).left(_xRam) && $.isLegacyGauge[_gauge])
                ) {
                    canDistribute = false;
                }
            }

            /// @dev if the checks pass and the gauge can be distributed
            if (canDistribute) {
                /// @dev set it to true firstly
                $.gaugePeriodDistributed[_gauge][_period] = true;

                /// @dev fetch destination gauge if there is an override
                address destinationGauge = $.gaugeRedirect[_gauge];
                if (destinationGauge == address(0)) {
                    destinationGauge = _gauge;
                }

                /// @dev check RAM "claimable"
                if (_claimable > 0) {
                    /// @dev notify emissions
                    IGauge(destinationGauge).notifyRewardAmount($.ram, _claimable);
                }
                /// @dev check xRAM "claimable"
                if (_xRamClaimable > 0) {
                    /// @dev convert, then notify the xRam
                    IXRex(_xRam).convertEmissionsToken(_xRamClaimable);
                    IGauge(destinationGauge).notifyRewardAmount(_xRam, _xRamClaimable);
                }

                emit DistributeReward(msg.sender, _gauge, _claimable + _xRamClaimable);
            }
        }
    }

    ////////////////////////////////
    // Governance Gated Functions //
    ////////////////////////////////

    /// @inheritdoc IVoter
    /// @notice sets the default xRamRatio
    function setGlobalRatio(uint256 _xRatio) external onlyGovernance {
        VoterGovernanceActions.setGlobalRatio(_xRatio);
    }

    /// @inheritdoc IVoter
    function setGovernor(address _governor) external onlyGovernance {
        VoterGovernanceActions.setGovernor(_governor);
    }

    /// @inheritdoc IVoter
    function whitelist(address _token) public onlyGovernance {
        VoterGovernanceActions.whitelist(_token);
    }

    /// @inheritdoc IVoter
    function revokeWhitelist(address _token) public onlyGovernance {
        VoterGovernanceActions.revokeWhitelist(_token);
    }

    /// @inheritdoc IVoter
    function killGauge(address _gauge) public onlyGovernance {
        VoterGovernanceActions.killGauge(_gauge);
    }

    /// @inheritdoc IVoter
    function reviveGauge(address _gauge) public onlyGovernance {
        VoterGovernanceActions.reviveGauge(_gauge);
    }

    /// @inheritdoc IVoter
    /// @dev in case of emission stuck due to killed gauges and unsupported operations
    function stuckEmissionsRecovery(address _gauge, uint256 _period) external onlyGovernance {
        VoterGovernanceActions.stuckEmissionsRecovery(_gauge, _period);
    }

    /// @inheritdoc IVoter
    function removeFeeDistributorReward(address _feeDistributor, address reward) external onlyGovernance {
        VoterGovernanceActions.removeFeeDistributorReward(_feeDistributor, reward);
    }

    /// @inheritdoc IVoter
    function setNfpManager(address _nfpManager) external onlyGovernance {
        VoterGovernanceActions.setNfpManager(_nfpManager);
        
        // Also update the nfpManagers set for multiple nfpManagers support
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();
        if (!$.authorizedClaimers.contains(_nfpManager)) {
            $.authorizedClaimers.add(_nfpManager);
        }
    }

    /// @inheritdoc IVoter
    function getAllAuthorizedClaimers() external view returns (address[] memory) {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();
        
        // If nfpManagers set is empty, return the legacy nfpManager
        if ($.authorizedClaimers.length() == 0 && $.nfpManager != address(0)) {
            address[] memory managers = new address[](1);
            managers[0] = $.nfpManager;
            return managers;
        }
        
        return $.authorizedClaimers.values();
    }

    /// @notice Add a new authorized claimer to the whitelist
    /// @param _claimer The authorized claimer address to add
    function addAuthorizedClaimer(address _claimer) external onlyGovernance {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();
        require(_claimer != address(0), "Zero address");
        require($.authorizedClaimers.add(_claimer), "Already added");
    }

    /// @notice Remove an authorized claimer from the whitelist
    /// @param _claimer The authorized claimer address to remove
    function removeAuthorizedClaimer(address _claimer) external onlyGovernance {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();
        require($.authorizedClaimers.remove(_claimer), "Not found");
    }

    /// @notice Set the minimum time threshold for rewarder (in seconds)
    function setTimeThresholdForRewarder(uint256 _timeThreshold) external onlyGovernance {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();
        $.timeThresholdForRewarder = _timeThreshold;    
    }

    /// @inheritdoc IVoter
    function setRewardValidator(address _rewardValidator) external onlyGovernance {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();
        $.rewardValidator = _rewardValidator;
    }
    
    ////////////////////
    // Gauge Creation //
    ////////////////////

    /// @inheritdoc IVoter
    function createGauge(address _pool) external onlyGovernance returns (address) {
        return VoterGovernanceActions.createGauge(_pool);
    }

    /// @inheritdoc IVoter
    function createCLGauge(address tokenA, address tokenB, int24 tickSpacing)
        external
        onlyGovernance
        returns (address)
    {
        return VoterGovernanceActions.createCLGauge(tokenA, tokenB, tickSpacing);
    }

    /// @inheritdoc IVoter
    function redirectEmissions(address tokenA, address tokenB, address destinationGauge) public onlyGovernance {
        VoterGovernanceActions.redirectEmissions(tokenA, tokenB, destinationGauge);
    }

    /// @notice Create a new FeeDistributor with specified feeRecipient (emergency governance function)
    function createFeeDistributorWithRecipient(address _feeRecipient) external onlyGovernance returns (address) {
        return VoterGovernanceActions.createFeeDistributorWithRecipient(_feeRecipient);
    }

    /// @notice Update FeeDistributor for a gauge (emergency governance function)
    function updateFeeDistributorForGauge(address _gauge, address _newFeeDistributor) external onlyGovernance {
        VoterGovernanceActions.updateFeeDistributorForGauge(_gauge, _newFeeDistributor);
    }


    /////////////////////////////
    // One-stop Reward Claimer //
    /////////////////////////////

    /// @inheritdoc IVoter
    function claimClGaugeRewards(
        address[] calldata _gauges,
        address[][] calldata _tokens,
        uint256[][] calldata _nfpTokenIds,
        address[] calldata _nfpManagers
    ) external {
        VoterRewardClaimers.claimClGaugeRewards(_gauges, _tokens, _nfpTokenIds, _nfpManagers);
    }

    /// @inheritdoc IVoter
    /// @notice Backwards compatible version using voter's nfpManager
    function claimClGaugeRewards(
        address[] calldata _gauges,
        address[][] calldata _tokens,
        uint256[][] calldata _nfpTokenIds
    ) external {
        VoterRewardClaimers.claimClGaugeRewards(_gauges, _tokens, _nfpTokenIds);
    }

    /// @inheritdoc IVoter
    function claimIncentives(address owner, address[] calldata _feeDistributors, address[][] calldata _tokens)
        external
    {
        VoterRewardClaimers.claimIncentives(owner, _feeDistributors, _tokens);
    }

    /// @inheritdoc IVoter
    function claimLegacyIncentives(address owner, address[] calldata _feeDistributors, address[][] calldata _tokens)
        external
    {
        VoterRewardClaimers.claimLegacyIncentives(owner, _feeDistributors, _tokens);
    }

    /// @inheritdoc IVoter
    function claimRewards(address[] calldata _gauges, address[][] calldata _tokens) external {
        VoterRewardClaimers.claimRewards(_gauges, _tokens);
    }


    //////////////////////////
    // Emission Calculation //
    //////////////////////////

    /// @inheritdoc IVoter
    function notifyRewardAmount(uint256 amount) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev gate to minter which prevents bricking distribution
        require(msg.sender == $.minter, Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev transfer the tokens to the voter
        IERC20($.ram).transferFrom(msg.sender, address(this), amount);
        /// @dev fetch the current period
        uint256 period = getPeriod();
        /// @dev add to the totalReward for the period
        $.totalRewardPerPeriod[period] += amount;
        /// @dev emit an event
        emit NotifyReward(msg.sender, $.ram, amount);
    }

    ///////////////////////////
    // Emission Distribution //
    ///////////////////////////
    /// @inheritdoc IVoter
    function distribute(address _gauge) public nonReentrant {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev update the period if not already done
        IMinter($.minter).updatePeriod();
        /// @dev fetch the last distribution
        uint256 _lastDistro = $.lastDistro[_gauge];
        /// @dev fetch the current period
        uint256 currentPeriod = getPeriod();
        /// @dev fetch the pool address from the gauge
        address pool = $.poolForGauge[_gauge];
        /// @dev loop through _lastDistro + 1 up to and including the currentPeriod
        for (uint256 period = _lastDistro + 1; period <= currentPeriod; ++period) {
            /// @dev fetch the claimable amount
            uint256 claimable = _claimablePerPeriod(pool, period);
            /// @dev distribute for the period
            _distribute(_gauge, claimable, period);
        }
        /// @dev if the last distribution wasn't the current period
        if (_lastDistro != currentPeriod) {
            /// @dev check if a CL gauge
            if ($.isClGauge[_gauge]) {
                if ($.voterOwnsFactory) {
                    if ($.isAlive[_gauge]) {
                        /// @dev set the feeProtocol to 100% (all fees to voters while emissions active)
                        IRamsesV3Factory($.clFactory).gaugeFeeSplitEnable(pool);
                    } else {
                        /// @dev gauge is dead, set fee protocol to 95/5 (95% to LPs, 5% to protocol)
                        /// @dev call AccessHub to set the fee protocol since only it has permission
                        address[] memory pools = new address[](1);
                        pools[0] = pool;
                        uint24[] memory feeProtocols = new uint24[](1);
                        feeProtocols[0] = 50_000; // 5% of 1_000_000 denominator
                        IAccessHub($.accessHub).setFeeSplitCL(pools, feeProtocols);
                    }
                }
                address poolV3 = pool;
                /// @dev collect fees by calling from the FeeCollector
                IFeeCollector(IRamsesV3Factory($.clFactory).feeCollector()).collectProtocolFees(poolV3);
            }
            /// @dev if it's a legacy gauge, fees are handled as LP tokens and thus need to be treated diff
            else if ($.isLegacyGauge[_gauge]) {
                /// @dev review for fresh deployment
                address[] memory pools = new address[](1);
                uint256[] memory feeSplits = new uint256[](1);
                pools[0] = pool;

                if ($.isAlive[_gauge]) {
                    /// @dev set the feeSplit to be 100% going to the feeDistributor
                    feeSplits[0] = BASIS; // 100%
                } else {
                    feeSplits[0] = BASIS / 20; // 5%
                }
                IAccessHub($.accessHub).setFeeSplitLegacy(pools, feeSplits);

                /// @dev mint the fees
                IPair(pool).mintFee();
                /// @dev notify the fees to the FeeDistributor
                IFeeRecipient(IFeeRecipientFactory($.feeRecipientFactory).feeRecipientForPair(pool)).notifyFees();
            }
        }
        /// @dev set the last distribution for the gauge as the currentPeriod
        $.lastDistro[_gauge] = currentPeriod;
    }

    /// @inheritdoc IVoter
    function distributeForPeriod(address _gauge, uint256 _period) public nonReentrant {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev attempt to update the period
        IMinter($.minter).updatePeriod();
        /// @dev fetch the pool address from the gauge
        address pool = $.poolForGauge[_gauge];
        /// @dev fetch the claimable amount for the period
        uint256 claimable = _claimablePerPeriod(pool, _period);

        /// @dev we dont update lastDistro here
        _distribute(_gauge, claimable, _period);
    }

    /// @inheritdoc IVoter
    function distributeAll() external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev grab the length of all gauges in the set
        uint256 gaugesLength = $.gauges.length();
        /// @dev loop through and call distribute for every index
        for (uint256 i; i < gaugesLength; ++i) {
            distribute($.gauges.at(i));
        }
    }

    /// @inheritdoc IVoter
    function batchDistributeByIndex(uint256 startIndex, uint256 endIndex) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        /// @dev grab the length of all gauges in the set
        uint256 gaugesLength = $.gauges.length();
        /// @dev if the end value is too high, set to end
        if (endIndex > gaugesLength) {
            endIndex = gaugesLength;
        }
        /// @dev loop through and distribute
        for (uint256 i = startIndex; i < endIndex; ++i) {
            // distribute($.gauges.at(i));
            // use low-level call to ensure the whole tx doesn't revert if one gauge reverts
            bytes memory data = abi.encodeCall(this.distribute, ($.gauges.at(i)));
            (bool _success,) = address(this).call(data);
            _success; // to suppress unused variable warning
        }
    }

    function updateLastDistro(address _gauge, uint256 period) external onlyGovernance {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        require(period <= getPeriod());
        $.lastDistro[_gauge] = period;
    }

    function syncVoterOwnsFactory() external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        $.voterOwnsFactory = IRamsesV3Factory($.clFactory).voter() == address(this);
    }

    ////////////////////
    // View Functions //
    ////////////////////

    /// @inheritdoc IVoter
    function getAllPools() external view returns (address[] memory _pools) {
        _pools = VoterStorage.getStorage().pools.values();
    }

    /// @inheritdoc IVoter
    function getPoolsLength() external view returns (uint256) {
        return VoterStorage.getStorage().pools.length();
    }

    /// @inheritdoc IVoter
    function getPool(uint256 index) external view returns (address) {
        return VoterStorage.getStorage().pools.at(index);
    }

    /// @inheritdoc IVoter
    function getAllGauges() external view returns (address[] memory _gauges) {
        _gauges = VoterStorage.getStorage().gauges.values();
    }

    /// @inheritdoc IVoter
    function getGaugesLength() external view returns (uint256) {
        return VoterStorage.getStorage().gauges.length();
    }

    /// @inheritdoc IVoter
    function getGauge(uint256 index) external view returns (address) {
        return VoterStorage.getStorage().gauges.at(index);
    }

    /// @inheritdoc IVoter
    function getAllFeeDistributors() external view returns (address[] memory _feeDistributors) {
        return VoterStorage.getStorage().feeDistributors.values();
    }

    /// @inheritdoc IVoter
    function isGauge(address _gauge) external view returns (bool) {
        return VoterStorage.getStorage().gauges.contains(_gauge);
    }

    /// @inheritdoc IVoter
    function isFeeDistributor(address _feeDistributor) external view returns (bool) {
        return VoterStorage.getStorage().feeDistributors.contains(_feeDistributor);
    }

    /// @inheritdoc IVoter
    function tickSpacingsForPair(address tokenA, address tokenB) public view returns (int24[] memory) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        return VoterStorage.getStorage()._tickSpacingsForPair[token0][token1];
    }

    /// @inheritdoc IVoter
    function gaugeRedirect(address gauge) external view returns (address) {
        return VoterStorage.getStorage().gaugeRedirect[gauge];
    }

    /// @inheritdoc IVoter
    function gaugeForClPool(address tokenA, address tokenB, int24 tickSpacing) public view returns (address) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        return VoterStorage.getStorage()._gaugeForClPool[token0][token1][tickSpacing];
    }

    /// @inheritdoc IVoter
    function getAllVotersPerPeriod(uint256 period) external view returns (address[] memory) {
        return VoterStorage.getStorage().votedUsersPerPeriod[period].values();
    }

    /// @inheritdoc IVoter
    function getAllVotersPerPeriodLength(uint256 period) external view returns (uint256) {
        return VoterStorage.getStorage().votedUsersPerPeriod[period].length();
    }

    /// @inheritdoc IVoter
    function getAllVotersPerPeriodAt(uint256 period, uint256 index) external view returns (address) {
        return VoterStorage.getStorage().votedUsersPerPeriod[period].at(index);
    }

    /// @dev shows how much is claimable per period
    function _claimablePerPeriod(address pool, uint256 period) internal view returns (uint256) {
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
    
    /// @dev anti-sybil on rewarder section
    /// @inheritdoc IVoter
    function isAntiSybilEnabled() external view returns (bool) {
        return VoterStorage.getStorage().isAntiSybilEnabled;
    }

    /// @inheritdoc IVoter
    function timeThresholdForRewarder() external view returns (uint256) {
        return VoterStorage.getStorage().timeThresholdForRewarder;
    }

    /// @inheritdoc IVoter
    function rewardValidator() external view returns (address) {
        return VoterStorage.getStorage().rewardValidator;
    }

    /// @inheritdoc IVoter
    function toggleAntiSybil() external onlyGovernance {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();
        $.isAntiSybilEnabled = !$.isAntiSybilEnabled;
    }
}
