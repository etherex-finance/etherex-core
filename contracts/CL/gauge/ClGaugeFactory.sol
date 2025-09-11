// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {Errors} from "contracts/libraries/Errors.sol";

import {IVoter} from "contracts/interfaces/IVoter.sol";
import {IClGaugeFactory} from "contracts/CL/gauge/interfaces/IClGaugeFactory.sol";
import {GaugeV3} from "contracts/CL/gauge/GaugeV3.sol";

/// @title Canonical CL gauge factory
/// @notice Deploys CL gauges
contract ClGaugeFactory is IClGaugeFactory {
    /// @inheritdoc IClGaugeFactory
    address public voter;

    /// @inheritdoc IClGaugeFactory
    address public feeCollector;

    /// @inheritdoc IClGaugeFactory
    address public nfpManager;

    address public implementation;

    /// @inheritdoc IClGaugeFactory
    mapping(address => address) public override getGauge;

    constructor(address _nfpManager, address _voter, address _feeCollector) {
        nfpManager = _nfpManager;
        voter = _voter;
        feeCollector = _feeCollector;
    }

    /// @inheritdoc IClGaugeFactory
    function createGauge(address pool) external override returns (address gauge) {
        require(msg.sender == voter, Errors.NOT_AUTHORIZED(msg.sender));
        require(getGauge[pool] == address(0), Errors.GAUGE_EXISTS(pool));

        if (implementation == address(0)) {
            require(IVoter(voter).ram() != address(0), Errors.NOT_INIT());
            implementation = address(new GaugeV3());
            emit Upgraded(implementation);
        }

        gauge = address(
            new BeaconProxy(address(this), abi.encodeWithSelector(GaugeV3.initialize.selector, voter, nfpManager, feeCollector, pool))
        );

        getGauge[pool] = gauge;
        emit GaugeCreated(pool, gauge);
    }

    function setNfpManager(address _nfpManager) external {
        /// @dev authorize voter instead of accessHub since this is handled as part of voter.setNfpManager
        require(msg.sender == voter, Errors.NOT_AUTHORIZED(msg.sender));

        emit NfpManagerChanged(_nfpManager, nfpManager);

        nfpManager = _nfpManager;
    }

    function setVoter(address _voter) external {
        require(msg.sender == IVoter(voter).accessHub(), Errors.NOT_AUTHORIZED(msg.sender));

        emit VoterChanged(_voter, voter);

        voter = _voter;
    }

    function setFeeCollector(address _feeCollector) external {
        require(msg.sender == IVoter(voter).accessHub(), Errors.NOT_AUTHORIZED(msg.sender));

        emit FeeCollectorChanged(_feeCollector, feeCollector);

        feeCollector = _feeCollector;
    }

    function setImplementation(address _newImplementation) external {
        require(msg.sender == IVoter(voter).accessHub(), Errors.NOT_AUTHORIZED(msg.sender));
        if (_newImplementation != implementation) {
            implementation = _newImplementation;
            emit Upgraded(_newImplementation);
        }
    }
}
