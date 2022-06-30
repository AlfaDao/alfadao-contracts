// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.6;

import './libraries/SafeMath.sol';
import './libraries/SafeERC20.sol';

import './interfaces/IOwnable.sol';
import './interfaces/IERC20.sol';
import './interfaces/IERC20Metadata.sol';
import './interfaces/IAFA.sol';
import './interfaces/IsAFA.sol';
import './interfaces/IBondingCalculator.sol';
import './interfaces/ITreasury.sol';

import './types/AlfaAccessControlled.sol';

contract AlfaTreasury is AlfaAccessControlled, ITreasury {
    /* ========== DEPENDENCIES ========== */

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== EVENTS ========== */

    event Deposit(address indexed token, uint256 amount, uint256 value);
    event Withdrawal(address indexed token, uint256 amount, uint256 value);
    event CreateDebt(address indexed debtor, address indexed token, uint256 amount, uint256 value);
    event RepayDebt(address indexed debtor, address indexed token, uint256 amount, uint256 value);
    event Managed(address indexed token, uint256 amount, bool withdraw);
    event ReservesAudited(uint256 indexed totalReserves);
    event Minted(address indexed caller, address indexed recipient, uint256 amount);
    event PermissionQueued(STATUS indexed status, address queued);
    event Permissioned(address addr, STATUS indexed status, bool result);

    /* ========== DATA STRUCTURES ========== */

    enum STATUS {
        RESERVEDEPOSITOR,
        RESERVESPENDER,
        RESERVETOKEN,
        RESERVEMANAGER,
        LIQUIDITYDEPOSITOR,
        LIQUIDITYTOKEN,
        LIQUIDITYMANAGER,
        RESERVEDEBTOR,
        REWARDMANAGER,
        SAFA,
        AFADEBTOR
    }

    struct Queue {
        STATUS managing;
        address toPermit;
        address calculator;
        uint256 timelockEnd;
        bool nullify;
        bool executed;
    }

    /* ========== STATE VARIABLES ========== */

    IAFA public immutable AFA;
    IsAFA public sAFA;

    mapping(STATUS => address[]) public registry;
    mapping(STATUS => mapping(address => bool)) public permissions;
    mapping(address => address) public bondCalculator;

    mapping(address => uint256) public debtLimit;

    uint256 public totalReserves;
    uint256 public totalDebt;
    uint256 public afaDebt;

    Queue[] public permissionQueue;
    uint256 public immutable blocksNeededForQueue;

    bool public timelockEnabled;
    bool public initialized;

    uint256 public onChainGovernanceTimelock;

    string internal constant notAccepted = 'Treasury: not accepted';
    string internal constant notApproved = 'Treasury: not approved';
    string internal constant invalidToken = 'Treasury: invalid token';
    string internal constant insufficientReserves = 'Treasury: insufficient reserves';

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _afa,
        uint256 _timelock,
        address _authority
    ) AlfaAccessControlled(IAlfaAuthority(_authority)) {
        require(_afa != address(0), 'Zero address: AFA');
        AFA = IAFA(_afa);

        timelockEnabled = false;
        initialized = false;
        blocksNeededForQueue = _timelock;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice allow approved address to deposit an asset for AFA
     * @param _amount uint256
     * @param _token address
     * @param _profit uint256
     * @return send_ uint256
     */
    function deposit(
        uint256 _amount,
        address _token,
        uint256 _profit
    ) external override returns (uint256 send_) {
        if (permissions[STATUS.RESERVETOKEN][_token]) {
            require(permissions[STATUS.RESERVEDEPOSITOR][msg.sender], notApproved);
        } else if (permissions[STATUS.LIQUIDITYTOKEN][_token]) {
            require(permissions[STATUS.LIQUIDITYDEPOSITOR][msg.sender], notApproved);
        } else {
            revert(invalidToken);
        }

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 value = tokenValue(_token, _amount);
        // mint AFA needed and store amount of rewards for distribution
        send_ = value.sub(_profit);
        AFA.mint(msg.sender, send_);

        totalReserves = totalReserves.add(value);

        emit Deposit(_token, _amount, value);
    }

    /**
     * @notice allow approved address to burn AFA for reserves
     * @param _amount uint256
     * @param _token address
     */
    function withdraw(uint256 _amount, address _token) external override {
        require(permissions[STATUS.RESERVETOKEN][_token], notAccepted); // Only reserves can be used for redemptions
        require(permissions[STATUS.RESERVESPENDER][msg.sender], notApproved);

        uint256 value = tokenValue(_token, _amount);
        AFA.burnFrom(msg.sender, value);

        totalReserves = totalReserves.sub(value);

        IERC20(_token).safeTransfer(msg.sender, _amount);

        emit Withdrawal(_token, _amount, value);
    }

    /**
     * @notice allow approved address to withdraw assets or deposit assets
     * @param _token address
     * @param _amount uint256
     * @param _withdraw bool, deposit or withdraw assets
     */
    function manage(
        address _token,
        uint256 _amount,
        bool _withdraw
    ) external override {
        if (permissions[STATUS.LIQUIDITYTOKEN][_token]) {
            require(permissions[STATUS.LIQUIDITYMANAGER][msg.sender], notApproved);
        } else if (permissions[STATUS.RESERVETOKEN][_token]) {
            require(permissions[STATUS.RESERVEMANAGER][msg.sender], notApproved);
        } else {
            // TODO, for NFT?
            revert(invalidToken);
        }
        if (permissions[STATUS.RESERVETOKEN][_token] || permissions[STATUS.LIQUIDITYTOKEN][_token]) {
            uint256 value = tokenValue(_token, _amount);
            if (_withdraw) {
                require(value <= excessReserves(), insufficientReserves);
                totalReserves = totalReserves.sub(value);
            } else {
                totalReserves = totalReserves.add(value);
            }
        } // May be other token accidental deposit

        if (_withdraw) {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        } else {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }

        emit Managed(_token, _amount, _withdraw);
    }

    /**
     * @notice mint new AFA using excess reserves
     * @param _recipient address
     * @param _amount uint256
     */
    function mint(address _recipient, uint256 _amount) external override {
        require(permissions[STATUS.REWARDMANAGER][msg.sender], notApproved);
        require(_amount <= excessReserves(), insufficientReserves);
        AFA.mint(_recipient, _amount);
        emit Minted(msg.sender, _recipient, _amount);
    }

    /**
     * DEBT: The debt functions allow approved addresses to borrow treasury assets
     * or AFA from the treasury, using sAFA as collateral. This might allow an
     * sAFA holder to provide AFA liquidity without taking on the opportunity cost
     * of unstaking, or alter their backing without imposing risk onto the treasury.
     * Many of these use cases are yet to be defined, but they appear promising.
     * However, we urge the community to think critically and move slowly upon
     * proposals to acquire these permissions.
     */

    /**
     * @notice allow approved address to borrow reserves
     * @param _amount uint256
     * @param _token address
     */
    function incurDebt(uint256 _amount, address _token) external override {
        uint256 value;
        if (_token == address(AFA)) {
            require(permissions[STATUS.AFADEBTOR][msg.sender], notApproved);
            value = _amount;
        } else {
            require(permissions[STATUS.RESERVEDEBTOR][msg.sender], notApproved);
            require(permissions[STATUS.RESERVETOKEN][_token], notAccepted);
            value = tokenValue(_token, _amount);
        }
        require(value != 0, invalidToken);

        sAFA.changeDebt(value, msg.sender, true);
        require(sAFA.debtBalances(msg.sender) <= debtLimit[msg.sender], 'Treasury: exceeds limit');
        totalDebt = totalDebt.add(value);

        if (_token == address(AFA)) {
            AFA.mint(msg.sender, value);
            afaDebt = afaDebt.add(value);
        } else {
            totalReserves = totalReserves.sub(value);
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
        emit CreateDebt(msg.sender, _token, _amount, value);
    }

    /**
     * @notice allow approved address to repay borrowed reserves with reserves
     * @param _amount uint256
     * @param _token address
     */
    function repayDebtWithReserve(uint256 _amount, address _token) external override {
        require(permissions[STATUS.RESERVEDEBTOR][msg.sender], notApproved);
        require(permissions[STATUS.RESERVETOKEN][_token], notAccepted);
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 value = tokenValue(_token, _amount);
        sAFA.changeDebt(value, msg.sender, false);
        totalDebt = totalDebt.sub(value);
        totalReserves = totalReserves.add(value);
        emit RepayDebt(msg.sender, _token, _amount, value);
    }

    /**
     * @notice allow approved address to repay borrowed reserves with AFA
     * @param _amount uint256
     */
    function repayDebtWithAFA(uint256 _amount) external {
        require(permissions[STATUS.RESERVEDEBTOR][msg.sender] || permissions[STATUS.AFADEBTOR][msg.sender], notApproved);
        AFA.burnFrom(msg.sender, _amount);
        sAFA.changeDebt(_amount, msg.sender, false);
        totalDebt = totalDebt.sub(_amount);
        afaDebt = afaDebt.sub(_amount);
        emit RepayDebt(msg.sender, address(AFA), _amount, _amount);
    }

    /* ========== MANAGERIAL FUNCTIONS ========== */

    /**
     * @notice takes inventory of all tracked assets
     * @notice always consolidate to recognized reserves before audit
     */
    function auditReserves() external onlyGovernor {
        uint256 reserves;
        address[] memory reserveToken = registry[STATUS.RESERVETOKEN];
        for (uint256 i = 0; i < reserveToken.length; i++) {
            if (permissions[STATUS.RESERVETOKEN][reserveToken[i]]) {
                reserves = reserves.add(tokenValue(reserveToken[i], IERC20(reserveToken[i]).balanceOf(address(this))));
            }
        }
        address[] memory liquidityToken = registry[STATUS.LIQUIDITYTOKEN];
        for (uint256 i = 0; i < liquidityToken.length; i++) {
            if (permissions[STATUS.LIQUIDITYTOKEN][liquidityToken[i]]) {
                reserves = reserves.add(tokenValue(liquidityToken[i], IERC20(liquidityToken[i]).balanceOf(address(this))));
            }
        }
        totalReserves = reserves;
        emit ReservesAudited(reserves);
    }

    /**
     * @notice set max debt for address
     * @param _address address
     * @param _limit uint256
     */
    function setDebtLimit(address _address, uint256 _limit) external onlyGovernor {
        debtLimit[_address] = _limit;
    }

    /**
     * @notice enable permission from queue
     * @param _status STATUS
     * @param _address address
     * @param _calculator address
     */
    function enable(
        STATUS _status,
        address _address,
        address _calculator
    ) external onlyGovernor {
        require(timelockEnabled == false, 'Use queueTimelock');
        if (_status == STATUS.SAFA) {
            sAFA = IsAFA(_address);
        } else {
            permissions[_status][_address] = true;

            if (_status == STATUS.LIQUIDITYTOKEN) {
                bondCalculator[_address] = _calculator;
            }

            (bool registered, ) = indexInRegistry(_address, _status);
            if (!registered) {
                registry[_status].push(_address);

                if (_status == STATUS.LIQUIDITYTOKEN || _status == STATUS.RESERVETOKEN) {
                    (bool reg, uint256 index) = indexInRegistry(_address, _status);
                    if (reg) {
                        delete registry[_status][index];
                    }
                }
            }
        }
        emit Permissioned(_address, _status, true);
    }

    /**
     *  @notice disable permission from address
     *  @param _status STATUS
     *  @param _toDisable address
     */
    function disable(STATUS _status, address _toDisable) external {
        require(msg.sender == authority.governor() || msg.sender == authority.guardian(), 'Only governor or guardian');
        permissions[_status][_toDisable] = false;
        emit Permissioned(_toDisable, _status, false);
    }

    /**
     * @notice check if registry contains address
     * @return (bool, uint256)
     */
    function indexInRegistry(address _address, STATUS _status) public view returns (bool, uint256) {
        address[] memory entries = registry[_status];
        for (uint256 i = 0; i < entries.length; i++) {
            if (_address == entries[i]) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    /* ========== TIMELOCKED FUNCTIONS ========== */

    // functions are used prior to enabling on-chain governance

    /**
     * @notice queue address to receive permission
     * @param _status STATUS
     * @param _address address
     * @param _calculator address
     */
    function queueTimelock(
        STATUS _status,
        address _address,
        address _calculator
    ) external onlyGovernor {
        require(_address != address(0), '_address is 0 ');
        require(timelockEnabled == true, 'Timelock is disabled, use enable');

        uint256 timelock = block.number.add(blocksNeededForQueue);
        if (_status == STATUS.RESERVEMANAGER || _status == STATUS.LIQUIDITYMANAGER) {
            timelock = block.number.add(blocksNeededForQueue.mul(2));
        }
        permissionQueue.push(Queue({managing: _status, toPermit: _address, calculator: _calculator, timelockEnd: timelock, nullify: false, executed: false}));
        emit PermissionQueued(_status, _address);
    }

    /**
     *  @notice enable queued permission
     *  @param _index uint256
     */
    function execute(uint256 _index) external {
        require(timelockEnabled == true, 'Timelock is disabled, use enable');

        Queue memory info = permissionQueue[_index];

        require(!info.nullify, 'Action has been nullified');
        require(!info.executed, 'Action has already been executed');
        require(block.number >= info.timelockEnd, 'Timelock not complete');

        if (info.managing == STATUS.SAFA) {
            // 9
            sAFA = IsAFA(info.toPermit);
        } else {
            permissions[info.managing][info.toPermit] = true;

            if (info.managing == STATUS.LIQUIDITYTOKEN) {
                bondCalculator[info.toPermit] = info.calculator;
            }
            (bool registered, ) = indexInRegistry(info.toPermit, info.managing);
            if (!registered) {
                registry[info.managing].push(info.toPermit);

                if (info.managing == STATUS.LIQUIDITYTOKEN) {
                    (bool reg, uint256 index) = indexInRegistry(info.toPermit, STATUS.RESERVETOKEN);
                    if (reg) {
                        delete registry[STATUS.RESERVETOKEN][index];
                    }
                } else if (info.managing == STATUS.RESERVETOKEN) {
                    (bool reg, uint256 index) = indexInRegistry(info.toPermit, STATUS.LIQUIDITYTOKEN);
                    if (reg) {
                        delete registry[STATUS.LIQUIDITYTOKEN][index];
                    }
                }
            }
        }
        permissionQueue[_index].executed = true;
        emit Permissioned(info.toPermit, info.managing, true);
    }

    /**
     * @notice cancel timelocked action
     * @param _index uint256
     */
    function nullify(uint256 _index) external onlyGovernor {
        permissionQueue[_index].nullify = true;
    }

    /**
     * @notice disables timelocked functions
     */
    function disableTimelock() external onlyGovernor {
        require(timelockEnabled == true, 'timelock already disabled');
        if (onChainGovernanceTimelock != 0 && onChainGovernanceTimelock <= block.number) {
            timelockEnabled = false;
        } else {
            onChainGovernanceTimelock = block.number.add(blocksNeededForQueue.mul(7)); // 7-day timelock
        }
    }

    /**
     * @notice enabled timelocked functions
     */
    function enabledTimelock() external onlyGovernor {
        require(timelockEnabled == false, 'timelock already enabled');
        timelockEnabled = true;
    }

    /**
     * @notice enables timelocks after initilization
     */
    function initialize() external onlyGovernor {
        require(initialized == false, 'Already initialized');
        timelockEnabled = true;
        initialized = true;
    }

    /**
     * @notice  enables ex cafa and usdt bond after initilization
     * @param _cAFAex address
     * @param _initBond address
     */
    function initcBase(address _cAFAex, address _initBond) external onlyGovernor {
        require(initialized == false, 'Already initialized');
        require(_cAFAex != address(0), 'Zero address: cAFA');
        require(_initBond != address(0), 'Zero address: Bond');
        permissions[STATUS.RESERVEDEPOSITOR][_cAFAex] = true;
        permissions[STATUS.RESERVEMANAGER][_initBond] = true;
        permissions[STATUS.REWARDMANAGER][_initBond] = true;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice returns excess reserves not backing tokens
     * @return uint
     */
    function excessReserves() public view override returns (uint256) {
        return totalReserves.sub(AFA.totalSupply().sub(totalDebt));
    }

    /**
     * @notice returns AFA valuation of asset
     * @param _token address
     * @param _amount uint256
     * @return value_ uint256
     */
    function tokenValue(address _token, uint256 _amount) public view override returns (uint256 value_) {
        value_ = _amount.mul(10**IERC20Metadata(address(AFA)).decimals()).div(10**IERC20Metadata(_token).decimals());

        if (permissions[STATUS.LIQUIDITYTOKEN][_token]) {
            value_ = IBondingCalculator(bondCalculator[_token]).valuation(_token, _amount);
        }
    }

    /**
     * @notice returns supply metric that cannot be manipulated by debt
     * @dev use this any time you need to query supply
     * @return uint256
     */
    function baseSupply() external view override returns (uint256) {
        return AFA.totalSupply() - afaDebt;
    }
}
