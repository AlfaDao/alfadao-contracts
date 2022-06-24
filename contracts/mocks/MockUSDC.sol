// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.6;

import '../libraries/SafeMath.sol';
import '../libraries/Address.sol';
import '../types/ERC20.sol';

contract MockUSDC is ERC20 {
    /* ========== DEPENDENCIES ========== */

    using Address for address;
    using SafeMath for uint256;

    /* ========== MODIFIERS ========== */

    modifier onlyMinter() {
        require(msg.sender == minter, 'Only Minter');
        _;
    }

    /* ========== STATE VARIABLES ========== */
    address public minter; // minter, Staking

    /* ========== CONSTRUCTOR ========== */
    constructor() ERC20('Mock USDC', 'mUSDC', 18) {
        minter = msg.sender;
    }

    /**
        @notice mint mUSDC
        @param _to address
        @param _amount uint
     */
    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    /**
        @notice burn mUSDC
        @param _amount uint
     */
    function burn(uint256 _amount) external {
        _burn(msg.sender, _amount);
    }
}
