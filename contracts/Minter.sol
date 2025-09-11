// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20Extended} from "./interfaces/IERC20Extended.sol";
import {IMinter} from "./interfaces/IMinter.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title Minter contract for Etherex
/// @custom:description Immutable minter contract for Etherex that permits codified weekly emissions
/// @custom:info Emissions can be adjusted a max of 25% in either direction per epoch
contract Minter is IMinter {
    /// @notice emissions value
    uint256 public weeklyEmissions;
    /// @notice controls emissions growth or decay
    uint256 public emissionsMultiplier;
    /// @notice unix timestamp of the first period
    uint256 public firstPeriod;
    /// @notice currently active unix timestamp of epoch start
    uint256 public activePeriod;
    /// @notice the last period the emissions multiplier was updated
    uint256 public lastMultiplierUpdate;

    /// @notice basis invariant 10_000 = 100%
    uint256 public constant BASIS = 10_000;
    /// @notice max deviation of 25% per epoch
    uint256 public constant MAX_DEVIATION = 2_500;
    /// @notice initial supply of 350m REX
    uint256 public constant INITIAL_SUPPLY = 350_000_000 * 1e18;
    /// @notice max supply of 1b REX
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice current operator
    address public operator;
    /// @notice the access control center
    address public accessHub;
    /// @notice xREX contract address
    address public xRex;
    /// @notice central voter contract
    address public voter;
    /// @notice the IERC20 version of REX
    IERC20Extended public rex;

    modifier onlyGovernance() {
        require(msg.sender == accessHub, Errors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    constructor(address _accessHub, address _operator) {
        accessHub = _accessHub;
        operator = _operator;
    }

    /// @inheritdoc IMinter
    function kickoff(
        address _rex,
        address _voter,
        uint256 _initialWeeklyEmissions,
        uint256 _initialMultiplier,
        address _xRex
    ) external {
        /// @dev ensure only the operator can kickoff the minter
        require(msg.sender == operator, Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev ensure the emissions token isn't set yet
        require(address(rex) == address(0), Errors.STARTED());
        require(_xRex != address(0), Errors.INVALID_CONTRACT());
        require(_voter != address(0), Errors.INVALID_CONTRACT());
        require(_rex != address(0), Errors.INVALID_CONTRACT());
        rex = IERC20Extended(_rex);
        xRex = _xRex;
        voter = _voter;
        /// @dev starting emissions
        weeklyEmissions = _initialWeeklyEmissions;
        /// @dev init emissionsMultiplier
        emissionsMultiplier = _initialMultiplier;
        emit SetVoter(_voter);
        rex.mint(operator, INITIAL_SUPPLY);
    }

    /// @inheritdoc IMinter
    function updatePeriod() public returns (uint256 period) {
        require(firstPeriod != 0, Errors.EMISSIONS_NOT_STARTED());
        /// @dev set period equal to the current activePeriod
        period = activePeriod;
        /// @dev if >= Thursday 0 UTC
        if (getPeriod() > period) {
            /// @dev fetch the current period
            period = getPeriod();
            /// @dev set the active period to the new period
            activePeriod = period;
            /// @dev calculate the weekly emissions
            uint256 _weeklyEmissions = calculateWeeklyEmissions();
            /// @dev set global value to the above calculated emissions
            weeklyEmissions = _weeklyEmissions;
            /// @dev if supply cap was not already hit
            if (weeklyEmissions > 0) {
                /// @dev mint emissions to the Minter contract
                rex.mint(address(this), _weeklyEmissions);
                /// @dev approvals for rex on voter
                rex.approve(voter, _weeklyEmissions);
                /// @dev notify emissions to the voter contract
                IVoter(voter).notifyRewardAmount(_weeklyEmissions);
                /// @dev emit the weekly emissions minted
                emit Mint(msg.sender, _weeklyEmissions);
            }
        }
    }

    function rebase() public {
        /// @dev fetch the data from encoding
        bytes memory data = abi.encodeWithSignature("rebase()");
        /// @dev call the rebase function
        (bool success,) = xRex.call(data);
        require(success, "REBASE_UNSUCCESSFUL");
    }

    function updatePeriodAndRebase() external {
        updatePeriod();
        rebase();
    }

    /// @inheritdoc IMinter
    function initEpoch0() external {
        /// @dev ensure only the operator can start the emissions
        require(msg.sender == operator, Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev ensure epoch 0 has not started yet
        require(firstPeriod == 0, Errors.STARTED());
        /// @dev set the active period to the current
        activePeriod = getPeriod();
        /// @dev set the last update as the last period so emissions can be updated once if needed
        lastMultiplierUpdate = activePeriod - 1;
        /// @dev set the first period to the active period
        firstPeriod = activePeriod;
        /// @dev mints the epoch 0 emissions for manual distribution
        rex.mint(operator, weeklyEmissions);
    }

    /// @inheritdoc IMinter
    function updateEmissionsMultiplier(uint256 _emissionsMultiplier) external onlyGovernance {
        /// @dev ensure that the last time the multiplier was updated was not the same period
        require(lastMultiplierUpdate != activePeriod, Errors.SAME_PERIOD());

        /// @dev set the last update to the current period
        lastMultiplierUpdate = activePeriod;
        /// @dev ensure the multiplier actually is diff
        require(emissionsMultiplier != _emissionsMultiplier, Errors.NO_CHANGE());
        /// @dev placeholder for deviation
        uint256 deviation;
        /// @dev check which way to subtract
        deviation = emissionsMultiplier > _emissionsMultiplier
            ? (emissionsMultiplier - _emissionsMultiplier)
            : (_emissionsMultiplier - emissionsMultiplier);
        /// @dev require deviation is not above 25% per epoch
        require(deviation <= MAX_DEVIATION, Errors.TOO_HIGH());
        /// @dev set new values
        emissionsMultiplier = _emissionsMultiplier;

        emit EmissionsMultiplierUpdated(_emissionsMultiplier);
    }

    /// @inheritdoc IMinter
    function calculateWeeklyEmissions() public view returns (uint256) {
        /// @dev fetch proposed emissions
        uint256 _weeklyEmissions = (weeklyEmissions * emissionsMultiplier) / BASIS;
        /// @dev if it's zero
        if (_weeklyEmissions == 0) return 0;
        /// @dev if minting goes over the max supply
        if (rex.totalSupply() + _weeklyEmissions > MAX_SUPPLY) {
            /// @dev update value to difference
            _weeklyEmissions = MAX_SUPPLY - rex.totalSupply();
        }
        return _weeklyEmissions;
    }

    /// @inheritdoc IMinter
    function getPeriod() public view returns (uint256 period) {
        period = block.timestamp / 1 weeks;
    }

    /// @inheritdoc IMinter
    function getEpoch() public view returns (uint256 _epoch) {
        return getPeriod() - firstPeriod;
    }
}
