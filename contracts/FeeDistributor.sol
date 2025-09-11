// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {Errors} from "contracts/libraries/Errors.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IVoteModule} from "./interfaces/IVoteModule.sol";

contract FeeDistributor is IFeeDistributor, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @inheritdoc IFeeDistributor
    IVoter public immutable voter;
    /// @inheritdoc IFeeDistributor
    IVoteModule public immutable voteModule;

    /// @inheritdoc IFeeDistributor
    address public immutable feeRecipient;
    /// @inheritdoc IFeeDistributor
    uint256 public immutable firstPeriod;

    /// @inheritdoc IFeeDistributor
    mapping(address owner => uint256 amount) public balanceOf;

    /// @inheritdoc IFeeDistributor
    mapping(uint256 period => uint256 weight) public votes;

    /// @notice period => user => amount
    mapping(uint256 period => mapping(address owner => uint256 weight)) public userVotes;

    /// @notice period => token => total supply
    mapping(uint256 period => mapping(address token => uint256 amount)) public rewardSupply;

    /// @notice period => user => token => amount
    mapping(uint256 period => mapping(address owner => mapping(address token => uint256 amount))) public userClaimed;

    /// @notice token => user => period
    mapping(address token => mapping(address owner => uint256 period)) public lastClaimByToken;

    EnumerableSet.AddressSet rewards;

    constructor(address _voter, address _feeRecipient) {
        /// @dev initialize voter
        voter = IVoter(_voter);
        /// @dev fetch and initialize voteModule via voter
        voteModule = IVoteModule(voter.voteModule());
        /// @dev set the firstPeriod as the current
        firstPeriod = getPeriod();
        /// @dev initialize the feeRecipient
        feeRecipient = _feeRecipient;
    }

    /// @inheritdoc IFeeDistributor
    function _deposit(uint256 amount, address owner) external {
        /// @dev gate to the voter
        require(msg.sender == address(voter), Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev fetch the next period (voting power slot)
        uint256 nextPeriod = getPeriod() + 1;
        /// @dev fetch the voting "balance" of the owner
        balanceOf[owner] += amount;
        /// @dev add the vote power to the cumulative
        votes[nextPeriod] += amount;
        /// @dev add to the owner's vote mapping
        userVotes[nextPeriod][owner] += amount;

        emit Deposit(owner, amount);
    }

    /// @inheritdoc IFeeDistributor
    function _withdraw(uint256 amount, address owner) external {
        /// @dev gate to the voter
        require(msg.sender == address(voter), Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev fetch the next period (voting power slot)
        uint256 nextPeriod = getPeriod() + 1;
        /// @dev decrement the mapping by withdrawal amount
        balanceOf[owner] -= amount;
        /// @dev check if the owner has any votes cast
        if (userVotes[nextPeriod][owner] > 0) {
            /// @dev if so -- decrement vote by amount
            userVotes[nextPeriod][owner] -= amount;
            /// @dev and decrement cumulative votes
            votes[nextPeriod] -= amount;
        }

        emit Withdraw(owner, amount);
    }

    /// @inheritdoc IFeeDistributor
    /// @dev specific to periods rather than all
    function getPeriodReward(uint256 period, address owner, address token) external nonReentrant {
        /// @dev check that msg.sender is privileged
        require(voteModule.isAdminFor(msg.sender, owner), Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev claim to msg.sender
        _getReward(period, owner, token, msg.sender);
    }

    /// @inheritdoc IFeeDistributor
    function getReward(address owner, address[] memory tokens) external nonReentrant {
        /// @dev check that msg.sender is privileged
        require(voteModule.isAdminFor(msg.sender, owner), Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev send to msg.sender (IMPORTANT: ensure these privileges are handled appropriately)
        _getAllRewards(owner, tokens, msg.sender);
    }

    /// @inheritdoc IFeeDistributor
    /// @dev used by Voter to allow batched reward claims
    function getRewardForOwner(address owner, address[] memory tokens) external {
        getRewardForOwnerTo(owner, tokens, owner);
    }

    /// @inheritdoc IFeeDistributor
    /// @dev used by Voter to allow batched reward claims
    function getRewardForOwnerTo(address owner, address[] memory tokens, address destination) public nonReentrant {
        /// @dev gate to voter
        require(msg.sender == address(voter), Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev call on behalf of owner
        _getAllRewards(owner, tokens, destination);
    }

    /// @inheritdoc IFeeDistributor
    function notifyRewardAmount(address token, uint256 amount) external nonReentrant {
        /// @dev limit to feeRecipient (feeCollector in CL)
        require(msg.sender == feeRecipient, Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev prevent spam
        require(amount != 0, Errors.ZERO_AMOUNT());
        /// @dev declare the next period (epoch)
        uint256 rewardedPeriod = getPeriod() + 1;
        /// @dev if all the prior checks pass, we can add the token to the rewards set
        if (!rewards.contains(token)) {
            rewards.add(token);
        }

        /// @dev logic for handling tax tokens via legacy
        /// @dev V3 (CL) does not support tax or atypical ERC20 implementations so this is null in those cases
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        /// @dev only count the amount actually within the contract
        amount = balanceAfter - balanceBefore;
        /// @dev increase rewards for "nextPeriod"
        rewardSupply[rewardedPeriod][token] += amount;
        /// @dev emit event for fees notified to feeDist
        emit NotifyReward(msg.sender, token, amount, rewardedPeriod);
    }

    /// @inheritdoc IFeeDistributor
    /// @dev submit voting incentives to the FeeDistributor
    function incentivize(address token, uint256 amount) external nonReentrant {
        /// @dev prevent spam
        require(amount != 0, Errors.ZERO_AMOUNT());
        /// @dev ensure whitelisted to prevent garbage from stuffing the arrays
        require(voter.isWhitelisted(token), Errors.NOT_WHITELISTED(token));
        /// @dev declare the reward period
        uint256 nextPeriod = getPeriod() + 1;
        /// @dev add to the rewards set
        rewards.add(token);

        /// @dev logic for handling tax tokens as bribes
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        /// @dev only count the amount actually within the contract
        amount = balanceAfter - balanceBefore;
        /// @dev increase rewards for "nextPeriod"
        rewardSupply[nextPeriod][token] += amount;
        /// @dev emit event for incentives "bribed" to feeDist
        emit VotesIncentivized(msg.sender, token, amount, nextPeriod);
    }

    /// @inheritdoc IFeeDistributor
    /// @dev voter can just clawback rewards
    function clawbackRewards(address token, address destination) external {
        /// @dev limit to accessHub only
        require(msg.sender == voter.accessHub(), Errors.NOT_AUTHORIZED(msg.sender));

        uint256 nextPeriod = getPeriod() + 1;

        uint256 amount = rewardSupply[nextPeriod][token];
        rewardSupply[nextPeriod][token] = 0;

        emit RewardsRedirected(destination, token, amount);

        _safeTransfer(token, destination, amount);
    }

    /// @inheritdoc IFeeDistributor
    /// @dev for the voter to remove spam rewards
    function removeReward(address _token) external {
        /// @dev limit to voter only
        require(msg.sender == address(voter), Errors.NOT_AUTHORIZED(msg.sender));
        if (rewards.contains(_token)) {
            /// @dev remove the token from the rewards set
            rewards.remove(_token);
            /// @dev emit the address of the token removed
            emit RewardsRemoved(_token);
        }
    }

    /// @inheritdoc IFeeDistributor
    function getRewardTokens() external view returns (address[] memory _rewards) {
        /// @dev return the values from the set
        /// @dev to prevent unbound expansion removeReward() is to be used when necessary
        _rewards = rewards.values();
    }

    /// @inheritdoc IFeeDistributor
    function earned(address token, address owner) external view returns (uint256 reward) {
        /// @dev fetch the current period
        uint256 currentPeriod = getPeriod();
        /// @dev gather the last claim timestamp or the firstPeriod if no claim yet
        uint256 lastClaim = Math.max(lastClaimByToken[token][owner], firstPeriod);
        /// @dev loop from the lastClaim up to and including the current period
        for (uint256 period = lastClaim; period <= currentPeriod; ++period) {
            /// @dev if there are votes for the period
            if (votes[period] != 0) {
                /// @dev fetch rewardSupply scaled to weight
                uint256 votesWeight = (userVotes[period][owner] * 1e18) / votes[period];
                reward += (rewardSupply[period][token] * votesWeight) / 1e18;
                /// @dev remove already claimed rewards to prevent shortfalls and over-rewarding
                reward -= userClaimed[period][owner][token];
            }
        }
    }

    /// @notice general read function for grabbing the current period (epoch)
    function getPeriod() public view returns (uint256) {
        return (block.timestamp / 1 weeks);
    }

    /// @dev a core internal function for claiming rewards
    function _getReward(uint256 period, address owner, address token, address receiver) internal {
        /// @dev prevent claiming from periods that are not yet finalized
        require(period <= getPeriod(), Errors.NOT_FINALIZED(period));

        /// @dev if there are any votes in the period
        if (votes[period] != 0) {
            uint256 votesWeight = (userVotes[period][owner] * 1e18) / votes[period];

            uint256 _reward = (rewardSupply[period][token] * votesWeight) / 1e18;
            /// @dev remove previous claims
            _reward -= userClaimed[period][owner][token];
            /// @dev add the upcoming claim to the mapping preemptively
            userClaimed[period][owner][token] += _reward;
            /// @dev if there exists some rewards after removing previous claims
            if (_reward > 0) {
                _safeTransfer(token, receiver, _reward);
                emit ClaimRewards(period, owner, receiver, token, _reward);
            }
        }
    }

    function _getAllRewards(address owner, address[] memory tokens, address receiver) internal {
        /// @dev fetch the current period
        uint256 currentPeriod = getPeriod();
        /// @dev placeholder
        uint256 lastClaim;
        /// @dev loop through all tokens in the array
        for (uint256 i = 0; i < tokens.length; ++i) {
            /// @dev fetch lastClaim
            lastClaim = Math.max(lastClaimByToken[tokens[i]][owner], firstPeriod);
            /// @dev nested loop starting from the lastClaim to up to and including the current period
            for (uint256 period = lastClaim; period <= currentPeriod; ++period) {
                /// @dev call _getReward per each token
                _getReward(period, owner, tokens[i], receiver);
            }
            /// @dev we set the previous period as the last claim to follow the for-loop scheme
            lastClaimByToken[tokens[i]][owner] = currentPeriod - 1;
        }
    }


    /**
     * internal safe transfer functions
     */
    function _safeTransfer(address token, address to, uint256 value) internal {
        require(
            token.code.length > 0,
            Errors.TOKEN_ERROR(token) /* throw address of the token as a custom error to help with debugging */
        );
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            Errors.TOKEN_ERROR(token) /* throw address of the token as a custom error to help with debugging */
        );
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(
            token.code.length > 0,
            Errors.TOKEN_ERROR(token) /* throw address of the token as a custom error to help with debugging */
        );
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));

        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            Errors.TOKEN_ERROR(token) /* throw address of the token as a custom error to help with debugging */
        );
    }

    function _safeApprove(address token, address spender, uint256 value) internal {
        require(
            token.code.length > 0,
            Errors.TOKEN_ERROR(token) /* throw address of the token as a custom error to help with debugging */
        );
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, value));

        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            Errors.TOKEN_ERROR(token) /* throw address of the token as a custom error to help with debugging */
        );
    }
}
