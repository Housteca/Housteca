pragma solidity 0.5.13;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC777/IERC777Recipient.sol";
import "./Housteca.sol";


contract Loan is IERC777Recipient
{
    ///////////// Constants /////////////

    uint constant public FUNDING_PERIOD = 90 days;
    uint constant public INITIAL_STAKE_PERIOD = 15 days;


    ///////////// Libraries /////////////

    using SafeMath for uint;


    ///////////// Enums /////////////

    enum Status
    {
        AWAITING_STAKE,     // the loan is waiting for the borrower to deposit the stake
        FUNDING,                // the loan is expecting to receive funds
        ACTIVE,                 // the loan got enough funding and has to be paid
        FINISHED,               // the load has been successfully paid and no longer supports operations
        UNCOMPLETED,            // the loan did not get enough funding and no longer supports operations
        BANKRUPT                // the loan got enough funding but the borrower did not pay on time
    }


    ///////////// Events /////////////

    event StatusChanged(Status indexed from, Status indexed to);


    ///////////// Attributes /////////////

    /// user that buys a house
    address public _borrower;
    /// token used to pay and fund
    IERC20 public _token;
    /// current status of the contract
    Status public _status;
    /// address of Housteca's main contract
    Housteca public _housteca;
    /// map to keep track of investor's funding
    mapping(address => uint) public _balances;
    /// map to keep track of the times each investor collected
    mapping(address => uint) public _timesCollected;
    /// amount investors have to reach
    uint public _target;
    /// number of payments to be made to return the initial investment
    uint public _totalPayments;
    /// timestamp of the next payment
    uint public _nextPayment;
    /// number of times the borrower paid the debt
    uint public _timesPaid;
    /// maximum number of seconds between consecutive payments
    uint public _periodicity;
    /// timestamp that exposes the maximum date available to fund this contract
    uint public _fundingDeadline;
    /// timestamp that exposes the maximum date available to send the initial stake to this contract
    uint public _initialStakeDeadline;
    /// amount of tokens available as unpaid insurance
    uint public _insurance;
    /// percentage of interests for investors
    uint public _interestRatio;


    ///////////// Modifiers /////////////

    modifier checkIsInvestor()
    {
        require(isInvestor(msg.sender), "Housteca Loan: Only an investor can perform this operation");
        _;
    }

    modifier checkStatus(Status status)
    {
        require(_status == status, "Housteca Loan: Invalid status for this operation");
        _;
    }

    modifier checkIsBorrower()
    {
        require(isBorrower(msg.sender), "Housteca Loan: Only the borrower can perform this operation");
        _;
    }


    ///////////// View functions /////////////

    function isBorrower(
        address addr
    )
      public
      view
      returns (bool)
    {
        return addr == _borrower;
    }

    function isInvestor(
        address addr
    )
      public
      view
      returns (bool)
    {
        return _housteca._investors(addr);
    }

    function balance()
      public
      view
      returns (uint)
    {
        return _token.balanceOf(address(this)).sub(_balances[_borrower]);
    }

    function initialStake()
      public
      view
      returns (uint)
    {
        return _target.div(10);
    }

    function total()
      public
      view
      returns (uint)
    {
        return _target.mul(_interestRatio).div(100);
    }

    function paymentAmount()
      public
      view
      returns (uint)
    {
        return total().div(_totalPayments);
    }

    function paymentsLeft()
      public
      view
      returns (uint)
    {
        return _totalPayments.sub(_timesPaid);
    }

    function totalPaid()
      public
      view
      returns (uint)
    {
        return paymentAmount().mul(_timesPaid);
    }

    function remainingAmountToPay()
      public
      view
      returns (uint)
    {
        return total().sub(totalPaid());
    }

    function paymentPeriodExpired()
      public
      view
      returns (bool)
    {
        return _status == Status.ACTIVE && block.timestamp > _nextPayment;
    }

    function initialStakePeriodExpired()
      public
      view
      returns (bool)
    {
        return _status == Status.AWAITING_STAKE && block.timestamp > _initialStakeDeadline;
    }

    function fundingPeriodExpired()
      public
      view
      returns (bool)
    {
        return _status == Status.AWAITING_STAKE && block.timestamp > _fundingDeadline;
    }

    function shouldUpdate()
      public
      view
      returns (bool)
    {
        return fundingPeriodExpired() || paymentPeriodExpired();
    }


    ///////////// Status AWAITING_STAKE /////////////

    constructor(
        Housteca housteca,
        IERC20 token,
        uint target,
        uint totalPayments,
        uint periodicity,
        uint insurance,
        uint interestRatio
    )
      public
    {
        _housteca = housteca;
        _target = target;
        _token = token;
        _totalPayments = totalPayments;
        _periodicity = periodicity;
        _insurance = insurance;
        _interestRatio = interestRatio;
        _borrower = msg.sender;
        _initialStakeDeadline = block.timestamp.add(INITIAL_STAKE_PERIOD);
        _status = Status.AWAITING_STAKE;
    }

    function _sendInitialStake(address from, uint amount)
      internal
      checkStatus(Status.AWAITING_STAKE)
    {
        require(isBorrower(from), "Housteca Loan: Only the borrower can deposit the initial stake");
        require(amount == initialStake(), "Housteca Loan: invalid initial stake amount");
        _fundingDeadline = block.timestamp.add(FUNDING_PERIOD);
        changeStatus(Status.ACTIVE);
    }

    function sendInitialStake()
      external
    {
        uint amount = initialStake();
        require(_token.transferFrom(_borrower, address(this), amount), "Housteca Loan: Token transfer failed");
        _sendInitialStake(msg.sender, amount);
    }


    ///////////// Status FUNDING /////////////

    function _invest(
        address investor,
        uint amount
    )
      internal
      checkStatus(Status.FUNDING)
    {
        require(isInvestor(investor), "Housteca Loan: An investor is required");
        require(balance() <= _target, "Housteca Loan: Amount sent over required one");

        _balances[msg.sender] = _balances[msg.sender].add(amount);
    }

    function invest(
        uint amount
    )
      external
    {
        require(_token.transferFrom(msg.sender, address(this), amount), "Housteca Loan: Token transfer failed");

        _invest(msg.sender, amount);
    }

    function collectInvestment()
      external
    {
        require(_status == Status.FUNDING || _status == Status.UNCOMPLETED, "Housteca Loan: Invalid status");

        uint investedAmount = _balances[msg.sender];
        require(investedAmount > 0, "Housteca Loan: Not amount invested");

        _balances[msg.sender] = 0;
        require(_token.transfer(msg.sender, investedAmount), "Housteca Loan: Token transfer failed");
    }

    function collectAllFunds()
      external
      checkIsBorrower
      checkStatus(Status.FUNDING)
    {
        require(balance() == _target, "Housteca Loan: Not enough funds to collect");

        changeStatus(Status.ACTIVE);
        _nextPayment = block.timestamp.add(_periodicity);
        require(_token.transfer(_borrower, _target), "Housteca Loan: Token transfer failed");
    }


    ///////////// Status ACTIVE /////////////

    function _pay(
        address addr,
        uint amount
    )
      internal
      checkStatus(Status.ACTIVE)
    {
        require(addr == _borrower, "Housteca Loan: Only the borrower can pay");
        require(amount == paymentAmount(), "Housteca Loan: Invalid amount to pay");
        require(_nextPayment < block.timestamp.add(_periodicity), "Housteca Loan: it is too soon to pay");

        _timesPaid += 1;
        if (_timesPaid >= _totalPayments) {
            changeStatus(Status.FINISHED);
            _nextPayment = 0;
        } else {
            _nextPayment = _nextPayment.add(_periodicity);
        }
    }

    function pay(
        uint amount
    )
      external
    {
        require(_token.transferFrom(_borrower, address(this), amount), "Housteca Loan: Token transfer failed");

        _pay(msg.sender, amount);
    }

    function collectEarnings()
      external
      checkIsInvestor
    {
        uint timesCollected = _timesCollected[msg.sender];
        require(timesCollected < _timesPaid, "Housteca Loan: No amount left to collect for now");

        uint amountToCollect = (_timesPaid.sub(timesCollected)).mul(paymentAmount());
        _timesCollected[msg.sender] = timesCollected.add(1);
        require(_token.transfer(msg.sender, amountToCollect), "Housteca Loan: Token transfer failed");
    }


    ///////////// Status change /////////////

    function changeStatus(Status status)
      internal
    {
        emit StatusChanged(_status, status);
        _status = status;
    }

    function update()
      public
    {
        if (initialStakePeriodExpired() || fundingPeriodExpired()) {
            changeStatus(Status.UNCOMPLETED);
        } else if (paymentPeriodExpired()) {
            changeStatus(Status.BANKRUPT);
        }
    }


    ///////////// ERC777 token reception /////////////

    function tokensReceived(
        address,
        address from,
        address to,
        uint256 amount,
        bytes calldata,
        bytes calldata
    )
      external
    {
        require(to == address(this), "Housteca Loan: Invalid ERC777 token receiver");
        if (_status == Status.AWAITING_STAKE) {
            _sendInitialStake(from, amount);
        } else if (_status == Status.AWAITING_STAKE) {
            _invest(from, amount);
        } else if (_status == Status.ACTIVE) {
            _pay(from, amount);
        } else {
            revert("Housteca Loan: Cannot accept ERC777 funds in the current state");
        }
    }
}
