// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IERC20Extended} from "../interfaces/IERC20Extended.sol";

library MinterStorage {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev keccak256(abi.encode(uint256(keccak256("minter.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 public constant MINTER_STORAGE_LOCATION = 0xe6b9c2ebce602e282d13679d7c45261a3c7ffe195da42522e8e70e8587836000;

    /// @custom꞉storage‑location erc7201꞉voter.storage
    struct MinterState {
        uint256 weeklyEmissions;
        /// @notice controls emissions growth or decay
        uint256 emissionsMultiplier;
        /// @notice unix timestamp of the first period
        uint256 firstPeriod;
        /// @notice currently active unix timestamp of epoch start
        uint256 activePeriod;
        /// @notice the last period the emissions multiplier was updated
        uint256 lastMultiplierUpdate;
        /// @notice current operator
        address operator;
        /// @notice the access control center
        address accessHub;
        /// @notice xRam contract address
        address xRam;
        /// @notice central voter contract
        address voter;
        /// @notice the IERC20 version of ram
        IERC20Extended ram;
    }

    /// @dev Return state storage struct for reading and writing
    function getStorage() internal pure returns (MinterState storage $) {
        assembly {
            $.slot := MINTER_STORAGE_LOCATION
        }
    }
}
