// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FeeDistributor} from "./../FeeDistributor.sol";

contract FeeDistributorFactory {
    address public lastFeeDistributor;

    function createFeeDistributor(address feeRecipient) external returns (address) {
        lastFeeDistributor = address(new FeeDistributor(msg.sender, feeRecipient));

        return lastFeeDistributor;
    }
}
