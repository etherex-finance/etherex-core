// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library VoterStorage {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev keccak256(abi.encode(uint256(keccak256("voter.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 public constant VOTER_STORAGE_LOCATION = 0x1756ff67afd71ca1c6aec4fe909f6cf0de32bed30949be9d2e1860a94e6e9500;

    /// @custom꞉storage‑location erc7201꞉voter.storage
    struct VoterState {
        /// @inheritdoc IVoter
        address legacyFactory;
        /// @inheritdoc IVoter
        address ram;
        /// @inheritdoc IVoter
        address gaugeFactory;
        /// @inheritdoc IVoter
        address feeDistributorFactory;
        /// @inheritdoc IVoter
        address minter;
        /// @inheritdoc IVoter
        address accessHub;
        /// @inheritdoc IVoter
        address governor;
        /// @inheritdoc IVoter
        address clFactory;
        /// @inheritdoc IVoter
        address clGaugeFactory;
        /// @inheritdoc IVoter
        address nfpManager;
        /// @inheritdoc IVoter
        address feeRecipientFactory;
        /// @inheritdoc IVoter
        address xRam;
        /// @inheritdoc IVoter
        address voteModule;
        /// @inheritdoc IVoter
        uint256 xRatio;
        bool voterOwnsFactory;
        EnumerableSet.AddressSet pools;
        EnumerableSet.AddressSet gauges;
        EnumerableSet.AddressSet feeDistributors;
        mapping(address pool => address gauge) gaugeForPool;
        mapping(address gauge => address pool) poolForGauge;
        mapping(address gauge => address feeDistributor) feeDistributorForGauge;
        mapping(address token0 => mapping(address token1 => address feeDistributor)) feeDistributorForClPair;
        mapping(address token0 => mapping(address token1 => EnumerableSet.AddressSet gauges)) gaugesForClPair;
        mapping(address sourceGauge => address destinationGauge) gaugeRedirect;
        mapping(address pool => mapping(uint256 period => uint256 totalVotes)) poolTotalVotesPerPeriod;
        mapping(address user => mapping(uint256 period => mapping(address pool => uint256 totalVote)))
            userVotesForPoolPerPeriod;
        mapping(address user => mapping(uint256 period => address[] pools)) userVotedPoolsPerPeriod;
        mapping(address user => mapping(uint256 period => uint256 votingPower)) userVotingPowerPerPeriod;
        mapping(address user => uint256 period) lastVoted;
        mapping(uint256 period => uint256 rewards) totalRewardPerPeriod;
        mapping(uint256 period => uint256 weight) totalVotesPerPeriod;
        mapping(address gauge => mapping(uint256 period => uint256 reward)) gaugeRewardsPerPeriod;
        mapping(address gauge => mapping(uint256 period => bool distributed)) gaugePeriodDistributed;
        mapping(address gauge => uint256 period) lastDistro;
        mapping(address gauge => bool legacyGauge) isLegacyGauge;
        mapping(address gauge => bool clGauge) isClGauge;
        mapping(address => bool) isWhitelisted;
        mapping(address => bool) isAlive;
        /// @dev How many different CL pools there are for the same token pair
        mapping(address token0 => mapping(address token1 => int24[])) _tickSpacingsForPair;
        /// @dev specific gauge based on tickspacing
        mapping(address token0 => mapping(address token1 => mapping(int24 tickSpacing => address gauge)))
            _gaugeForClPool;
        mapping(address clGauge => address feeDist) originalFeeDistributorForGauge;
        mapping(address feeDist => address pool) poolForFeeDistributor;
        mapping(uint256 period => EnumerableSet.AddressSet) votedUsersPerPeriod;
        /// @dev for anti-sybil on rewarder
        uint256 timeThresholdForRewarder;
        bool isAntiSybilEnabled;
        /// @dev reward validator contract for anti-sybil validation
        address rewardValidator;
        /// @dev Multiple nfpManagers support
        EnumerableSet.AddressSet authorizedClaimers;
    }

    /// @dev Return state storage struct for reading and writing
    function getStorage() internal pure returns (VoterState storage $) {
        assembly {
            $.slot := VOTER_STORAGE_LOCATION
        }
    }
}
