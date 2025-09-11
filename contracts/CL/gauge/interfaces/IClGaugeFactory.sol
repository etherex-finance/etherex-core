// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title The interface for the CL gauge Factory
/// @notice Deploys CL gauges
interface IClGaugeFactory {
    /// @dev Emitted when the implementation returned by the beacon is changed.
    event Upgraded(address indexed implementation);

    /// @notice Emitted when a gauge is created
    /// @param pool The address of the pool
    /// @param pool The address of the created gauge
    event GaugeCreated(address indexed pool, address gauge);

    /// @notice Emitted when the NFP Manager is changed
    /// @param newNfpManager The address of the new NFP Manager
    /// @param oldNfpManager The address of the old NFP Manager
    event NfpManagerChanged(address indexed newNfpManager, address indexed oldNfpManager);

    /// @notice Emitted when the Fee Collector is changed
    /// @param newFeeCollector The address of the new NFP Manager
    /// @param oldFeeCollector The address of the old NFP Manager
    event FeeCollectorChanged(address indexed newFeeCollector, address indexed oldFeeCollector);

    /// @notice Emitted when the Voter is changed
    /// @param newVoter The address of the new Voter
    /// @param oldVoter The address of the old Voter
    event VoterChanged(address indexed newVoter, address indexed oldVoter);

    /// @notice Returns the NFP Manager address
    function nfpManager() external view returns (address);

    /// @notice Set new NFP Manager
    function setNfpManager(address _nfpManager) external;

    /// @notice Returns Voter
    function voter() external view returns (address);

    /// @notice Returns the gauge address for a given pool, or address 0 if it does not exist
    /// @param pool The pool address
    /// @return gauge The gauge address
    function getGauge(address pool) external view returns (address gauge);

    /// @notice Returns the address of the fee collector contract
    /// @dev Fee collector decides where the protocol fees go (fee distributor, treasury, etc.)
    function feeCollector() external view returns (address);

    /// @notice Creates a gauge for the given pool
    /// @param pool One of the desired gauge
    /// @return gauge The address of the newly created gauge
    function createGauge(address pool) external returns (address gauge);

    /// @notice returns the GaugeV3 implementation
    function implementation() external returns (address);

    /// @notice Sets implementation for all GaugeV3s
    function setImplementation(address _newImplementation) external;
}
