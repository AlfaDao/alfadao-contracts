// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.6;

import '../interfaces/IAlfaAuthority.sol';

error UNAUTHORIZED();
error AUTHORITY_INITIALIZED();

/// @dev Reasoning for this contract = modifiers literaly copy code
/// instead of pointing towards the logic to execute. Over many
/// functions this bloats contract size unnecessarily.
/// imho modifiers are a meme.
abstract contract AlfaAccessControlledV2 {
    /* ========== EVENTS ========== */

    event AuthorityUpdated(IAlfaAuthority authority);

    /* ========== STATE VARIABLES ========== */

    IAlfaAuthority public authority;

    /* ========== Constructor ========== */

    constructor(IAlfaAuthority _authority) {
        authority = _authority;
        emit AuthorityUpdated(_authority);
    }

    /* ========== "MODIFIERS" ========== */

    modifier onlyGovernor() {
        _onlyGovernor();
        _;
    }

    modifier onlyGuardian() {
        _onlyGuardian();
        _;
    }

    modifier onlyPolicy() {
        _onlyPolicy();
        _;
    }

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    /* ========== GOV ONLY ========== */

    function initializeAuthority(IAlfaAuthority _newAuthority) internal {
        if (authority != IAlfaAuthority(address(0))) revert AUTHORITY_INITIALIZED();
        authority = _newAuthority;
        emit AuthorityUpdated(_newAuthority);
    }

    function setAuthority(IAlfaAuthority _newAuthority) external {
        _onlyGovernor();
        authority = _newAuthority;
        emit AuthorityUpdated(_newAuthority);
    }

    /* ========== INTERNAL CHECKS ========== */

    function _onlyGovernor() internal view {
        if (msg.sender != authority.governor()) revert UNAUTHORIZED();
    }

    function _onlyGuardian() internal view {
        if (msg.sender != authority.guardian()) revert UNAUTHORIZED();
    }

    function _onlyPolicy() internal view {
        if (msg.sender != authority.policy()) revert UNAUTHORIZED();
    }

    function _onlyVault() internal view {
        if (msg.sender != authority.vault()) revert UNAUTHORIZED();
    }
}
