// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {INonfungiblePositionManager} from "../CL/periphery/interfaces/INonfungiblePositionManager.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {IGaugeV3} from "../CL/gauge/interfaces/IGaugeV3.sol";
import {IVoteModule} from "../interfaces/IVoteModule.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {IXRex} from "contracts/interfaces/IXRex.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors} from "contracts/libraries/Errors.sol";
import {IPair} from "contracts/interfaces/IPair.sol";
import {IPairFactory} from "contracts/interfaces/IPairFactory.sol";
import {IRouter} from "contracts/interfaces/IRouter.sol";

import {VoterStorage} from "contracts/libraries/VoterStorage.sol";

/// @title VoterRewardClaimers
/// @notice Reward claimers logic for Voter
/// @dev Used to reduce Voter contract size by moving all reward claiming logic to a library
library VoterRewardClaimers {
    /// @dev function for claiming CL rewards with multiple ownership/access checks
    /// @notice Legacy version - uses single nfpManager from VoterStorage
    function claimClGaugeRewards(
        address[] calldata _gauges,
        address[][] calldata _tokens,
        uint256[][] calldata _nfpTokenIds
    ) external {
        INonfungiblePositionManager nfpManagerContract =
            INonfungiblePositionManager(VoterStorage.getStorage().nfpManager);
        for (uint256 i; i < _gauges.length; ++i) {
            for (uint256 j; j < _nfpTokenIds[i].length; ++j) {
                require(
                    msg.sender == nfpManagerContract.ownerOf(_nfpTokenIds[i][j])
                        || msg.sender == nfpManagerContract.getApproved(_nfpTokenIds[i][j])
                        || nfpManagerContract.isApprovedForAll(
                            nfpManagerContract.ownerOf(_nfpTokenIds[i][j]), msg.sender
                        ),
                    Errors.NOT_AUTHORIZED_CLAIMER(address(nfpManagerContract))
                );
                IGaugeV3(_gauges[i]).getRewardForOwnerFromVoter(
                    address(nfpManagerContract),
                    _nfpTokenIds[i][j],
                    _tokens[i]
                );
            }
        }
    }

    /// @dev function for claiming CL rewards with multiple ownership/access checks
    /// @notice New version where caller specifies which NFP manager to use
    function claimClGaugeRewards(
        address[] calldata _gauges,
        address[][] calldata _tokens,
        uint256[][] calldata _nfpTokenIds,
        address[] calldata _nfpManagers
    ) external {
        require(_gauges.length == _nfpManagers.length, "Length mismatch");
        
        for (uint256 i; i < _gauges.length; ++i) {
            INonfungiblePositionManager nfpManagerContract =
                INonfungiblePositionManager(_nfpManagers[i]);
            
            for (uint256 j; j < _nfpTokenIds[i].length; ++j) {
                require(
                    msg.sender == nfpManagerContract.ownerOf(_nfpTokenIds[i][j])
                        || msg.sender == nfpManagerContract.getApproved(_nfpTokenIds[i][j])
                        || nfpManagerContract.isApprovedForAll(
                            nfpManagerContract.ownerOf(_nfpTokenIds[i][j]), msg.sender
                        ),
                    Errors.NOT_AUTHORIZED_CLAIMER(_nfpManagers[i])
                );
                IGaugeV3(_gauges[i]).getRewardForOwnerFromVoter(
                    _nfpManagers[i],
                    _nfpTokenIds[i][j],
                    _tokens[i]
                );
            }
        }
    }


    /// @dev claims voting incentives batched
    function claimIncentives(address owner, address[] calldata _feeDistributors, address[][] calldata _tokens)
        external
    {
        /// @dev restrict to authorized callers/admins
        require(
            IVoteModule(VoterStorage.getStorage().voteModule).isAdminFor(msg.sender, owner),
            Errors.NOT_AUTHORIZED(msg.sender)
        );

        for (uint256 i; i < _feeDistributors.length; ++i) {
            IFeeDistributor(_feeDistributors[i]).getRewardForOwner(owner, _tokens[i]);
        }
    }

    /// @dev for claiming a batch of legacy gauge rewards
    function claimRewards(address[] calldata _gauges, address[][] calldata _tokens) external {
        for (uint256 i; i < _gauges.length; ++i) {
            IGauge(_gauges[i]).getReward(msg.sender, _tokens[i]);
        }
    }


    /// @notice claim legacy incentives and unwrap LP token to token0/1
    /// @param _feeDistributors fee distributor addresses
    /// @param _rewardTokens reward token addresses
    function claimLegacyIncentives(address owner, address[] memory _feeDistributors, address[][] memory _rewardTokens)
        public
    {
        address legacyFactory = VoterStorage.getStorage().legacyFactory;

        /// @dev restrict to authorized callers/admins
        require(
            IVoteModule(VoterStorage.getStorage().voteModule).isAdminFor(msg.sender, owner),
            Errors.NOT_AUTHORIZED(msg.sender)
        );

        for (uint256 i = 0; i < _feeDistributors.length; i++) {
            uint256 length = _rewardTokens[i].length;
            uint256 lpTokensLength;
            uint256 normalTokensLength;
            address[] memory lpTokens = new address[](length);
            address[] memory normalTokens = new address[](length);

            // check if it's an LP token
            for (uint256 j = 0; j < length; j++) {
                if (IPairFactory(legacyFactory).isPair(_rewardTokens[i][j])) {
                    lpTokens[lpTokensLength] = _rewardTokens[i][j];
                    lpTokensLength++;
                } else {
                    normalTokens[normalTokensLength] = _rewardTokens[i][j];
                    normalTokensLength++;
                }
            }

            // truncate arrays
            assembly ("memory-safe") {
                mstore(lpTokens, lpTokensLength)
                mstore(normalTokens, normalTokensLength)
            }

            // fetch LP token balances
            uint256[] memory lpBalancesBefore = new uint256[](lpTokensLength);
            for (uint256 j = 0; j < lpTokensLength; j++) {
                lpBalancesBefore[j] = IERC20(lpTokens[j]).balanceOf(address(this));
            }

            // claim all tokens for this distributor
            IFeeDistributor(_feeDistributors[i]).getRewardForOwnerTo(owner, lpTokens, address(this)); // claim lp tokens to here to automatically exit for the owner
            IFeeDistributor(_feeDistributors[i]).getRewardForOwnerTo(owner, normalTokens, owner); // claim normal tokens to the owner directly

            // process each lp token
            for (uint256 j = 0; j < lpTokensLength; j++) {
                uint256 lpBalanceIncrease = IERC20(lpTokens[j]).balanceOf(address(this)) - lpBalancesBefore[j];
                if (lpBalanceIncrease > 0) {
                    IERC20(lpTokens[j]).transfer(lpTokens[j], lpBalanceIncrease);
                    IPair(lpTokens[j]).burn(owner);
                }
            }
        }
    }
}
