// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVoter} from "../interfaces/IVoter.sol";
import {IXRex} from "../interfaces/IXRex.sol";
import {Errors} from "contracts/libraries/Errors.sol";
import {IVoteModule} from "../interfaces/IVoteModule.sol";

/// @title xREX contract for Etherex
/// @dev Staked version of REX that allows for PvP rebase and voting
contract XRex is ERC20, IXRex, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * Addresses
     */

    /// @inheritdoc IXRex
    address public operator;

    /// @inheritdoc IXRex
    address public immutable MINTER;
    /// @inheritdoc IXRex
    address public immutable ACCESS_HUB;

    /// @inheritdoc IXRex
    address public immutable VOTE_MODULE;

    /// @dev IERC20 declaration of REX
    IERC20 public immutable REX;
    /// @dev declare IVoter
    IVoter public immutable VOTER;

    /// @inheritdoc IXRex
    uint256 public constant BASIS = 1_000_000;
    /// @inheritdoc IXRex
    uint256 public constant SLASHING_PENALTY = 500_000;

    /// @dev stores the addresses that are exempt from transfer limitations when transferring out
    EnumerableSet.AddressSet exempt;
    /// @dev stores the addresses that are exempt from transfer limitations when transferring to them
    EnumerableSet.AddressSet exemptTo;

    /// @inheritdoc IXRex
    uint256 public lastDistributedPeriod;
    /// @inheritdoc IXRex
    uint256 public pendingRebase;
    /// @inheritdoc IXRex
    uint256 public rebaseThreshold;

    modifier onlyGovernance() {
        require(msg.sender == ACCESS_HUB, Errors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    constructor(
        address _rex,
        address _voter,
        address _operator,
        address _accessHub,
        address _voteModule,
        address _minter
    ) ERC20("xREX", "xREX") {
        REX = IERC20(_rex);
        VOTER = IVoter(_voter);
        MINTER = _minter;
        operator = _operator;
        ACCESS_HUB = _accessHub;
        VOTE_MODULE = _voteModule;

        /// @dev exempt voter, operator, and the vote module
        exempt.add(_voter);
        exempt.add(operator);
        exempt.add(VOTE_MODULE);

        exemptTo.add(VOTE_MODULE);

        /// @dev grab current period from voter
        lastDistributedPeriod = IVoter(_voter).getPeriod();
    }

    /// @inheritdoc IXRex
    function pause() external onlyGovernance {
        _pause();
    }
    /// @inheritdoc IXRex

    function unpause() external onlyGovernance {
        _unpause();
    }

    /**
     *
     */
    // ERC20 Overrides and Helpers
    /**
     *
     */
    function _update(address from, address to, uint256 value) internal override {
        /* cases we account for:
         *
         * minting and burning
         * if the "to" is part of the special exemptions
         * withdraw and deposit calls
         * if "from" is a gauge or feeDist
         *
         */

        uint8 _u;
        if (_isExempted(from, to)) {
            _u = 1;
        } else if (VOTER.isGauge(from) || VOTER.isFeeDistributor(from)) {
            /// @dev add to the exempt set
            exempt.add(from);
            _u = 1;
        }
        /// @dev if all previous checks are passed
        require(_u == 1, Errors.NOT_WHITELISTED(from));
        /// @dev call parent function
        super._update(from, to, value);
    }

    /// @dev internal check for the transfer whitelist
    function _isExempted(address _from, address _to) internal view returns (bool) {
        return (exempt.contains(_from) || _from == address(0) || _to == address(0) || exemptTo.contains(_to));
    }

    /**
     *
     */
    // General use functions
    /**
     *
     */

    /// @inheritdoc IXRex
    function convertEmissionsToken(uint256 _amount) external whenNotPaused {
        /// @dev ensure the _amount is > 0
        require(_amount != 0, Errors.ZERO());
        /// @dev transfer from the caller to this address
        REX.transferFrom(msg.sender, address(this), _amount);
        /// @dev mint the xREX to the caller
        _mint(msg.sender, _amount);
        /// @dev emit an event for conversion
        emit Converted(msg.sender, _amount);
    }

    /// @inheritdoc IXRex
    function rebase() external whenNotPaused {
        /// @dev gate to minter and call it on epoch flips
        require(msg.sender == MINTER, Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev fetch the current period
        uint256 period = VOTER.getPeriod();
        /// @dev if it's a new period (epoch)
        if (
            /// @dev if the rebase is greater than the rebaseThreshold
            period > lastDistributedPeriod && pendingRebase >= rebaseThreshold
        ) {
            /// @dev PvP rebase notified to the voteModule staking contract to stream to xREX after epoch flips
            /// @dev fetch the current period from voter
            lastDistributedPeriod = period;
            /// @dev store the rebase
            uint256 _temp = pendingRebase;
            /// @dev zero it out before sending
            pendingRebase = 0;
            /// @dev approve REX transferring to voteModule
            REX.approve(VOTE_MODULE, _temp);
            /// @dev notify the REX rebase
            IVoteModule(VOTE_MODULE).notifyRewardAmount(_temp);
            emit Rebase(msg.sender, _temp);
        }
    }

    /// @inheritdoc IXRex
    function exit(uint256 _amount) external whenNotPaused returns (uint256 _exitedAmount) {
        /// @dev cannot exit a 0 amount
        require(_amount != 0, Errors.ZERO());
        /// @dev if it's at least 2 wei it will give a penalty
        uint256 penalty = ((_amount * SLASHING_PENALTY) / BASIS);
        uint256 exitAmount = _amount - penalty;

        /// @dev burn the xREX from the caller's address
        _burn(msg.sender, _amount);

        /// @dev store the rebase earned from the penalty
        pendingRebase += penalty;

        /// @dev transfer the exitAmount to the caller
        REX.transfer(msg.sender, exitAmount);
        /// @dev emit actual exited amount
        emit InstantExit(msg.sender, exitAmount);
        return exitAmount;
    }

    /**
     *
     */
    // Permissioned functions, timelock/operator gated
    /**
     *
     */

    /// @inheritdoc IXRex
    function operatorRedeem(uint256 _amount) external onlyGovernance {
        _burn(operator, _amount);
        REX.transfer(operator, _amount);
        emit XRamRedeemed(address(this), _amount);
    }

    /// @inheritdoc IXRex
    function rescueTrappedTokens(address[] calldata _tokens, uint256[] calldata _amounts) external onlyGovernance {
        for (uint256 i = 0; i < _tokens.length; ++i) {
            /// @dev cant fetch the underlying
            require(_tokens[i] != address(REX), Errors.CANT_RESCUE());
            IERC20(_tokens[i]).transfer(operator, _amounts[i]);
        }
    }

    /// @inheritdoc IXRex
    function migrateOperator(address _operator) external onlyGovernance {
        /// @dev ensure operator is different
        require(operator != _operator, Errors.NO_CHANGE());
        emit NewOperator(operator, _operator);
        operator = _operator;
    }

    /// @inheritdoc IXRex
    function setExemption(address[] calldata _exemptee, bool[] calldata _exempt) external onlyGovernance {
        /// @dev ensure arrays of same length
        require(_exemptee.length == _exempt.length, Errors.ARRAY_LENGTHS());
        /// @dev loop through all and attempt add/remove based on status
        for (uint256 i = 0; i < _exempt.length; ++i) {
            bool success = _exempt[i] ? exempt.add(_exemptee[i]) : exempt.remove(_exemptee[i]);
            /// @dev emit : (who, status, success)
            emit Exemption(_exemptee[i], _exempt[i], success);
        }
    }

    /// @inheritdoc IXRex
    function setExemptionTo(address[] calldata _exemptee, bool[] calldata _exempt) external onlyGovernance {
        /// @dev ensure arrays of same length
        require(_exemptee.length == _exempt.length, Errors.ARRAY_LENGTHS());
        /// @dev loop through all and attempt add/remove based on status
        for (uint256 i = 0; i < _exempt.length; ++i) {
            bool success = _exempt[i] ? exemptTo.add(_exemptee[i]) : exemptTo.remove(_exemptee[i]);
            /// @dev emit : (who, status, success)
            emit Exemption(_exemptee[i], _exempt[i], success);
        }
    }

    /// @inheritdoc IXRex
    function setRebaseThreshold(uint256 _newThreshold) external onlyGovernance {
        if (rebaseThreshold != _newThreshold) {
            rebaseThreshold = _newThreshold;

            emit NewRebaseThreshold(_newThreshold);
        }
    }

    /**
     *
     */
    // Getter functions
    /**
     *
     */

    /// @inheritdoc IXRex
    function getBalanceResiding() public view returns (uint256 _amount) {
        /// @dev simply returns the balance of the underlying
        return REX.balanceOf(address(this));
    }

    /// @inheritdoc IXRex
    function isExempt(address _who) external view returns (bool _exempt) {
        return exempt.contains(_who);
    }

    /// @inheritdoc IXRex
    function isExemptTo(address _who) external view returns (bool _exempt) {
        return exemptTo.contains(_who);
    }

    /// @inheritdoc IXRex
    function rex() external view returns (address) {
        return address(REX);
    }
}
