// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IVoteModule} from "./interfaces/IVoteModule.sol";
import {Errors} from "./libraries/Errors.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IXRex} from "./interfaces/IXRex.sol";

contract VoteModule is IVoteModule, ReentrancyGuard, Initializable {
    /// @inheritdoc IVoteModule
    address public accessHub;
    /// @inheritdoc IVoteModule
    address public xRex;
    /// @inheritdoc IVoteModule
    address public voter;
    /// @notice xREX token
    IXRex public stakingToken;
    /// @notice underlying REX token
    IERC20 public underlying;

    /// @inheritdoc IVoteModule
    uint256 public cooldown = 12 hours;

    /// @inheritdoc IVoteModule
    uint256 public totalSupply;
    /// @inheritdoc IVoteModule
    uint256 public unlockTime;

    /// @inheritdoc IVoteModule
    mapping(address user => uint256 amount) public balanceOf;
    /// @inheritdoc IVoteModule
    mapping(address delegator => address delegatee) public delegates;
    /// @inheritdoc IVoteModule
    mapping(address owner => address operator) public admins;
    /// @inheritdoc IVoteModule
    mapping(address user => bool exempt) public cooldownExempt;

    /// @inheritdoc IVoteModule
    mapping(uint256 period => uint256 amount) public rewardSupply;

    /// @dev same mapping order as FeeDistributor so the name is a bit odd
    /// @inheritdoc IVoteModule
    mapping(uint256 period => mapping(address owner => uint256 amount)) public userClaimed;

    /// @inheritdoc IVoteModule
    mapping(address owner => uint256 period) public userLastClaimPeriod;

    modifier onlyAccessHub() {
        /// @dev ensure it is the accessHub
        require(msg.sender == accessHub, Errors.NOT_ACCESSHUB());
        _;
    }

    constructor() {
        voter = msg.sender;
    }

    function initialize(address _xRex, address _voter, address _accessHub) external initializer {
        /// @dev making sure who deployed calls initialize
        require(voter == msg.sender, Errors.UNAUTHORIZED());
        require(_accessHub != address(0), Errors.INVALID_ADDRESS());
        require(_xRex != address(0), Errors.INVALID_ADDRESS());
        require(_voter != address(0), Errors.INVALID_ADDRESS());
        xRex = _xRex;
        voter = _voter;
        accessHub = _accessHub;
        stakingToken = IXRex(_xRex);
        underlying = IERC20(IXRex(_xRex).REX());
    }

    /// @inheritdoc IVoteModule
    function depositAll() external {
        deposit(IERC20(xRex).balanceOf(msg.sender));
    }

    /// @inheritdoc IVoteModule
    function deposit(uint256 amount) public nonReentrant {
        /// @dev ensure the amount is > 0
        require(amount != 0, Errors.ZERO_AMOUNT());
        /// @dev if the caller is not exempt
        if (!cooldownExempt[msg.sender]) {
            /// @dev block interactions during the cooldown period
            require(block.timestamp >= unlockTime, Errors.COOLDOWN_ACTIVE());
        }
        /// @dev transfer xREX in
        IERC20(xRex).transferFrom(msg.sender, address(this), amount);
        /// @dev update accounting
        totalSupply += amount;
        balanceOf[msg.sender] += amount;

        /// @dev update data
        IVoter(voter).poke(msg.sender);

        /// @dev initialize userLastClaimPeriod if needed
        if (userLastClaimPeriod[msg.sender] == 0) {
            userLastClaimPeriod[msg.sender] = getPeriod();
        }

        emit Deposit(msg.sender, amount);
    }

    /// @inheritdoc IVoteModule
    function withdrawAll() external {
        /// @dev fetch stored balance
        uint256 _amount = balanceOf[msg.sender];
        /// @dev withdraw the stored balance
        withdraw(_amount);
        /// @dev claim rewards for the user
        _claimAll(msg.sender);
    }

    /// @inheritdoc IVoteModule
    function withdraw(uint256 amount) public nonReentrant {
        /// @dev ensure the amount is > 0
        require(amount != 0, Errors.ZERO_AMOUNT());
        /// @dev if the caller is not exempt
        if (!cooldownExempt[msg.sender]) {
            /// @dev block interactions during the cooldown period
            require(block.timestamp >= unlockTime, Errors.COOLDOWN_ACTIVE());
        }

        /// @dev reduce total "supply"
        totalSupply -= amount;
        /// @dev decrement from balance mapping
        balanceOf[msg.sender] -= amount;
        /// @dev transfer the xREX to the caller
        IERC20(xRex).transfer(msg.sender, amount);

        /// @dev update data via poke
        /// @dev we check in voter that msg.sender is the VoteModule
        IVoter(voter).poke(msg.sender);

        emit Withdraw(msg.sender, amount);
    }

    /// @inheritdoc IVoteModule
    /// @dev this is ONLY callable by xREX, which has important safety checks
    function notifyRewardAmount(uint256 amount) external nonReentrant {
        /// @dev only callable by xRex contract
        require(msg.sender == xRex, Errors.NOT_XRAM());

        /// @dev take the REX from the contract to the voteModule
        underlying.transferFrom(xRex, address(this), amount);

        /// @dev record rewards to the period that just got finalized
        uint256 period = getPeriod();
        rewardSupply[period] += amount;

        /// @dev the timestamp of when people can withdraw next
        /// @dev not DoSable because only xREX can notify
        unlockTime = cooldown + block.timestamp;

        emit NotifyReward(msg.sender, amount);
    }

    /**
     * AccessHub Gated Functions
     */
    /// @inheritdoc IVoteModule
    function setCooldownExemption(address _user, bool _exempt) external onlyAccessHub {
        /// @dev ensure the call is not the same status
        require(cooldownExempt[_user] != _exempt, Errors.NO_CHANGE());
        /// @dev adjust the exemption status
        cooldownExempt[_user] = _exempt;

        emit ExemptedFromCooldown(_user, _exempt);
    }

    /// @inheritdoc IVoteModule
    function setNewCooldown(uint256 _cooldownInSeconds) external onlyAccessHub {
        /// @dev safety check
        require(_cooldownInSeconds <= 7 days);
        uint256 oldCooldown = cooldown;
        cooldown = _cooldownInSeconds;

        emit NewCooldown(oldCooldown, cooldown);
    }

    /**
     * User Management Functions
     */

    /// @inheritdoc IVoteModule
    function delegate(address delegatee) external {
        bool _isAdded = false;
        /// @dev if there exists a delegate, and the chosen delegate is the zero address
        if (delegatee == address(0) && delegates[msg.sender] != address(0)) {
            /// @dev delete the mapping
            delete delegates[msg.sender];
        } else {
            /// @dev else update delegation
            delegates[msg.sender] = delegatee;
            /// @dev flip to true if a delegate is written
            _isAdded = true;
        }
        /// @dev emit event
        emit Delegate(msg.sender, delegatee, _isAdded);
    }

    /// @inheritdoc IVoteModule
    function setAdmin(address admin) external {
        /// @dev visibility setting to false, even though default is false
        bool _isAdded = false;
        /// @dev if there exists an admin and the zero address is chosen
        if (admin == address(0) && admins[msg.sender] != address(0)) {
            /// @dev wipe mapping
            delete admins[msg.sender];
        } else {
            /// @dev else update mapping
            admins[msg.sender] = admin;
            /// @dev flip to true if an admin is written
            _isAdded = true;
        }
        /// @dev emit event
        emit SetAdmin(msg.sender, admin, _isAdded);
    }

    /**
     * View Functions
     */

    /// @inheritdoc IVoteModule
    function getPeriod() public view returns (uint256) {
        return (block.timestamp / 1 weeks);
    }

    /// @inheritdoc IVoteModule
    function earned(address account) public view returns (uint256 _reward) {
        uint256 nextPeriod = getPeriod() + 1;
        /// @dev fetch period to start looping
        uint256 period = userLastClaimPeriod[account];

        if (period == 0) {
            /// @dev return 0 if user is not initialized
            return 0;
        }

        for (period; period < nextPeriod; period++) {
            _reward += periodEarned(period, account);
        }
    }

    /// @inheritdoc IVoteModule
    /// @dev same input orders as GaugeV3
    function periodEarned(uint256 period, address user) public view returns (uint256 amount) {
        uint256 votingPowerUsed = IVoter(voter).userVotingPowerPerPeriod(user, period);
        uint256 totalVotesPerPeriod = IVoter(voter).totalVotesPerPeriod(period);
        if (totalVotesPerPeriod == 0) return 0;
        uint256 periodRewardSupply = rewardSupply[period];

        /// @dev reward amount is rewardSupply times the ratio of user votes vs total votes of the period
        /// then all of it is subtracted by the amount already received
        amount = ((votingPowerUsed * periodRewardSupply) / totalVotesPerPeriod)
            - userClaimed[period][user];

        return amount;
    }

    /// @inheritdoc IVoteModule
    function getReward() external nonReentrant {
        /// @dev claim all the rewards
        _claimAll(msg.sender);
    }

    /// @inheritdoc IVoteModule
    function getPeriodReward(uint256 period) external nonReentrant {
        uint256 amount = _claim(msg.sender, period);

        if (amount > 0) {
            _sendClaims(msg.sender, amount);
            /// @dev don't update userLastClaimPeriod here
        }
    }

    /// @inheritdoc IVoteModule
    function setUserLastClaimPeriod(uint256 period) external {
        if (period == 0) revert Errors.NOT_GT_ZERO(period);
        userLastClaimPeriod[msg.sender] = period;
    }

    /// @notice loops and claims all rebases
    /// @param _user user to claim for
    function _claimAll(address _user) internal {
        uint256 nextPeriod = getPeriod() + 1;

        uint256 amount;
        /// @dev don't need to check if period == 0 for the start of the loop here
        /// because _claimAll wouldn't be called by users without initialization anyway
        for (uint256 period = userLastClaimPeriod[_user]; period < nextPeriod; period++) {
            amount += _claim(_user, period);
        }

        if (amount > 0) {
            userLastClaimPeriod[_user] = nextPeriod - 1;

            _sendClaims(_user, amount);
        }
    }

    /// @notice claims rebase for a specific period
    /// @param _user user to claim for
    /// @param _period period to claim for
    function _claim(address _user, uint256 _period) internal returns (uint256 amount) {
        /// @dev prevent claiming from periods that are not yet finalized
        require(_period < getPeriod() + 1, Errors.NOT_FINALIZED(_period));

        /// @dev fetch earned
        amount = periodEarned(_period, _user);
        if (amount > 0) {
            /// @dev record claimed amount
            userClaimed[_period][_user] += amount;
        }

        return amount;
    }

    /// @notice sends claimed rebase to the user
    /// @dev separated out from _claim() so we don't loop send
    /// @param _user user to claim for
    /// @param _amount amount to send
    function _sendClaims(address _user, uint256 _amount) internal {
        /// @dev approve Etherex to xREX
        underlying.approve(address(stakingToken), _amount);
        /// @dev convert
        stakingToken.convertEmissionsToken(_amount);
        /// @dev transfer xREX to the user
        IERC20(xRex).transfer(_user, _amount);
        emit ClaimRewards(_user, _amount);
    }

    /// @inheritdoc IVoteModule
    function isDelegateFor(address caller, address owner) external view returns (bool approved) {
        /// @dev check the delegate mapping AND admin mapping due to hierarchy (admin > delegate)
        return (
            delegates[owner] == caller || admins[owner] == caller
            /// @dev return true if caller is the owner as well
            || caller == owner
            /// @dev return true if caller is the accessHub as well
            || caller == accessHub
        );
    }

    /// @inheritdoc IVoteModule
    function isAdminFor(address caller, address owner) external view returns (bool approved) {
        /// @dev return whether the caller is the address in the map
        /// @dev return true if caller is the owner as well
        return (admins[owner] == caller || caller == owner);
    }
}
