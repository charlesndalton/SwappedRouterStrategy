// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20Extended} from "./interfaces/ERC20/IERC20Extended.sol";
import {IVault} from "./interfaces/Vault.sol";

/**
 * Takes want, swaps it for targetToken, and then deposits targetToken in the yVault.
 */
abstract contract CrossAssetRouterStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    IVault public yVault; // vault that we're depositing into
    IERC20 public targetToken;
    uint256 public maxLoss;
    bool internal isOriginal = true;

    event Cloned(address indexed clone);

    constructor(
        address _vault,
        address _yVault
    ) public BaseStrategy(_vault) {
        _initializeStrategy(_yVault);
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _yVault
    ) external virtual returns (address newStrategy) {
        require(isOriginal);
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        CrossAssetRouterStrategy(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _yVault
        );

        emit Cloned(newStrategy);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _yVault
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        require(address(yVault) == address(0));
        _initializeStrategy(_yVault);
    }

    function _initializeStrategy(address _yVault)
        internal
    {
        yVault = IVault(_yVault);
        targetToken = IERC20(yVault.token());

        want.safeApprove(address(yVault), type(uint256).max);

    }

    function name() external view override returns (string memory) {
        string memory _assetSymbols = string(
            abi.encodePacked(
                IERC20Extended(address(want)).symbol(),
                "->",
                IERC20Extended(address(targetToken)).symbol()
            )
        );

        return string(abi.encodePacked("CrossAssetRouterStrategy(", _assetSymbols, ")"));
    }

    function estimatedTotalAssets()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return balanceOfWant().add(valueOfInvestment());
    }

    function delegatedAssets() external view override returns (uint256) {
        return vault.strategies(address(this)).totalDebt;
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        virtual
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAsset = estimatedTotalAssets();

        // Estimate the profit we have so far
        if (_totalDebt <= _totalAsset) {
            _profit = _totalAsset - _totalDebt;
        }

        // We take profit and debt
        uint256 _amountFreed;
        (_amountFreed, _loss) = liquidatePosition(
            _debtOutstanding + _profit
        );
        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            // Example:
            // debtOutstanding 100, profit 40, _amountFreed 100, _loss 50
            // loss should be 10, (50-40)
            // profit should endup in 0
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 140, _loss 10
            // _profit should be 40, (50 profit - 10 loss)
            // loss should end up in be 0
            _profit = _profit.sub(_loss);
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding)
        internal
        virtual
        override
    {
        if (emergencyExit) {
            return;
        }

        uint256 _freeBalance = balanceOfWant();
        if (_freeBalance > _debtOutstanding) {
            uint256 _amountToInvest = _freeBalance - _debtOutstanding;
            yVault.deposit();
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        virtual
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _looseWant = balanceOfWant();
        if (_looseWant >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        uint256 _toWithdraw = _amountNeeded.sub(_looseWant);
        _withdrawFromYVault(_toWithdraw);

        _looseWant = balanceOfWant();
        if (_amountNeeded > _looseWant) {
            _liquidatedAmount = _looseWant;
            _loss = _amountNeeded - _looseWant;
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function _withdrawFromYVault(uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        uint256 _balanceOfYShares = yVault.balanceOf(address(this));
        uint256 _sharesToWithdraw =
            Math.min(_investmentTokenToYShares(_amount), _balanceOfYShares);

        if (_sharesToWithdraw == 0) {
            return;
        }

        yVault.withdraw(_sharesToWithdraw, address(this), maxLoss);
    }

    function liquidateAllPositions()
        internal
        virtual
        override
        returns (uint256 _amountFreed)
    {
        return
            yVault.withdraw(
                yVault.balanceOf(address(this)),
                address(this),
                maxLoss
            );
    }

    function prepareMigration(address _newStrategy) internal virtual override {
        yVault.safeTransfer(
            _newStrategy,
            yVault.balanceOf(address(this))
        );
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory ret)
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei;
    }

    function setMaxLoss(uint256 _maxLoss) public onlyVaultManagers {
        maxLoss = _maxLoss;
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, type(uint256).max);
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function _investmentTokenToYShares(uint256 amount)
        internal
        view
        returns (uint256)
    {
        return amount.mul(10**yVault.decimals()).div(yVault.pricePerShare());
    }

    function valueOfInvestment() public view virtual returns (uint256) {
        return
            yVault.balanceOf(address(this)).mul(yVault.pricePerShare()).div(
                10**yVault.decimals()
            );
    }
}
