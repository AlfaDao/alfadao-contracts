// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.6;

import '../types/AlfaAccessControlled.sol';

contract AccessControlledMock is AlfaAccessControlled {
    constructor(address _auth) AlfaAccessControlled(IAlfaAuthority(_auth)) {}

    bool public governorOnlyTest;

    bool public guardianOnlyTest;

    bool public policyOnlyTest;

    bool public vaultOnlyTest;

    function governorTest() external onlyGovernor returns (bool) {
        governorOnlyTest = true;
        return governorOnlyTest;
    }

    function guardianTest() external onlyGuardian returns (bool) {
        guardianOnlyTest = true;
        return guardianOnlyTest;
    }

    function policyTest() external onlyPolicy returns (bool) {
        policyOnlyTest = true;
        return policyOnlyTest;
    }

    function vaultTest() external onlyVault returns (bool) {
        governorOnlyTest = true;
        return governorOnlyTest;
    }
}
