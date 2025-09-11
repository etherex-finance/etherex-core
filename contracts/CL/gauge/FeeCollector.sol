// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {Errors} from "contracts/libraries/Errors.sol";

import {IAccessHub} from "contracts/interfaces/IAccessHub.sol";
import {IFeeDistributor} from "../../interfaces/IFeeDistributor.sol";
import {IVoter} from "../../interfaces/IVoter.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRamsesV3Pool} from "../core/interfaces/IRamsesV3Pool.sol";

contract FeeCollector is IFeeCollector {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS = 1_000_000;
    uint256 public treasuryFees;

    address public override treasury;
    address public voter;
    IAccessHub public accessHub;

    constructor(IAccessHub _accessHub) {
        accessHub = _accessHub;
        treasury = _accessHub.treasury();
        voter = address(_accessHub.voter());
    }

    /// @dev Prevents calling a function from anyone except the treasury
    modifier onlyTreasury() {
        require(msg.sender == treasury, Errors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    /// @inheritdoc IFeeCollector
    function setTreasury(address _treasury) external override onlyTreasury {
        emit TreasuryChanged(treasury, _treasury);

        treasury = _treasury;
    }

    /// @inheritdoc IFeeCollector
    function setTreasuryFees(uint256 _treasuryFees) external override onlyTreasury {
        require(_treasuryFees <= BASIS, Errors.FEE_TOO_LARGE());
        emit TreasuryFeesChanged(treasuryFees, _treasuryFees);

        treasuryFees = _treasuryFees;
    }

    /// @inheritdoc IFeeCollector
    function collectProtocolFees(address pool) external override {
        /// @dev get tokens
        IERC20 token0 = IERC20(IRamsesV3Pool(pool).token0());
        IERC20 token1 = IERC20(IRamsesV3Pool(pool).token1());

        /// @dev fetch pending fees
        (uint128 pushable0, uint128 pushable1) = IRamsesV3Pool(pool).protocolFees();
        /// @dev return early if zero pending fees (sometimes 1 is the default value)
        if (!(pushable0 > 1 || pushable1 > 1)) return;

        /// @dev if voter is not set, just collect to treasury
        if (voter == address(0)) {
            (uint128 collected0, uint128 collected1) = IRamsesV3Pool(pool).collectProtocol(treasury, type(uint128).max, type(uint128).max);
            emit FeesCollected(address(pool), 0, 0, collected0, collected1);
            return;
        }

        /// @dev check if there's a gauge
        IVoter _voter = IVoter(voter);
        address gauge = _voter.gaugeForPool(address(pool));
        bool isAlive = _voter.isAlive(gauge);

        /// @dev check if it's a cl gauge redirected to another gauge
        if (gauge != address(0) && !isAlive) {
            address gaugeRedirect = _voter.gaugeRedirect(gauge);
            isAlive = _voter.isAlive(gaugeRedirect);
        }

        /// @dev if there's no gauge, there's no fee distributor, send everything to the treasury directly
        if (gauge == address(0) || !isAlive) {
            (uint128 collected0, uint128 collected1) = IRamsesV3Pool(pool).collectProtocol(treasury, type(uint128).max, type(uint128).max);

            emit FeesCollected(address(pool), 0, 0, collected0, collected1);
            return;
        }

        /// @dev using uint128.max here since the pool automatically determines the owed amount
        IRamsesV3Pool(pool).collectProtocol(address(this), type(uint128).max, type(uint128).max);

        /// @dev get balances, not using the return values in case of transfer fees
        uint256 amount0 = token0.balanceOf(address(this));
        uint256 amount1 = token1.balanceOf(address(this));

        uint256 amount0Treasury;
        uint256 amount1Treasury;

        /// @dev put into memory to save gas
        uint256 _treasuryFees = treasuryFees;
        if (_treasuryFees != 0) {
            amount0Treasury = (amount0 * _treasuryFees) / BASIS;
            amount1Treasury = (amount1 * _treasuryFees) / BASIS;

            amount0 = amount0 - amount0Treasury;
            amount1 = amount1 - amount1Treasury;

            address _treasury = treasury;
            /// @dev only send fees if > 0, prevents reverting on distribution
            if (amount0Treasury > 0) {
                token0.safeTransfer(_treasury, amount0Treasury);
            }
            if (amount1Treasury > 0) {
                token1.safeTransfer(_treasury, amount1Treasury);
            }
        }

        /// @dev get the fee distributor
        IFeeDistributor feeDist = IFeeDistributor(_voter.feeDistributorForGauge(gauge));

        /// @dev approve then notify the fee distributor
        if (amount0 > 0) {
            token0.approve(address(feeDist), amount0);
            feeDist.notifyRewardAmount(address(token0), amount0);
        }
        if (amount1 > 0) {
            token1.approve(address(feeDist), amount1);
            feeDist.notifyRewardAmount(address(token1), amount1);
        }

        emit FeesCollected(address(pool), amount0, amount1, amount0Treasury, amount1Treasury);
    }
}
