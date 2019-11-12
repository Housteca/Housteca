pragma solidity 0.5.13;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC777/IERC777Recipient.sol";
import "./Housteca.sol";


contract Loan is IERC777Recipient
{
    ///////////// Libraries /////////////

    using SafeMath for uint;


    ///////////// Enums /////////////

    enum Status
    {
        CREATED,        // the loan has just been created and can seek investors
        ACTIVE,         // the loan got enough funding and has to be paid
        FINISHED,       // the load has been successfully paid and no longer supports operations
        UNCOMPLETED,    // the loan did not get enough funding and no longer supports operations
        BANKRUPT        // the loan got enough funding but the borrower did not pay on time
    }


    ///////////// Structs /////////////

    struct Investment {
        uint amount;
        uint timesCollected;
    }


    ///////////// Attributes /////////////

    address public _borrower;
    IERC20 public _token;
    Status public _status;
    Housteca public _housteca;
    mapping(address => Investment) public _investments;
    uint public _target;
    uint public _total;
    uint public _totalPayments;
    uint public _nextPayment;
    uint public _timesPaid;
    uint public _periodicity;
    uint public _startPaymentDelay;


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
        return _token.balanceOf(address(this));
    }

    function paymentAmount()
      public
      view
      returns (uint)
    {
        return _total.div(_totalPayments);
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
        return _total.sub(totalPaid());
    }


    ///////////// Status CREATED /////////////

    constructor(
        Housteca housteca,
        IERC20 token,
        uint target,
        uint total,
        uint totalPayments,
        uint periodicity,
        uint startPaymentDelay
    )
      public
    {
        _status = Status.CREATED;
        _housteca = housteca;
        _target = target;
        _total = total;
        _token = token;
        _totalPayments = totalPayments;
        _periodicity = periodicity;
        _startPaymentDelay = startPaymentDelay;
        _borrower = msg.sender;
    }

    function _invest(
        address investor,
        uint amount
    )
      internal
      checkStatus(Status.CREATED)
    {
        require(isInvestor(investor), "Housteca Loan: An investor is required");
        require(balance() <= _target, "Housteca Loan: Amount sent over required one");

        Investment storage investment = _investments[msg.sender];
        investment.amount = investment.amount.add(amount);
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
      checkStatus(Status.CREATED)
    {
        uint investedAmount = _investments[msg.sender].amount;
        require(investedAmount > 0, "Housteca Loan: Not amount invested");

        delete _investments[msg.sender];
        require(_token.transfer(msg.sender, investedAmount), "Housteca Loan: Token transfer failed");
    }

    function collectAllFunds()
      external
      checkIsBorrower
      checkStatus(Status.CREATED)
    {
        require(balance() == _target, "Housteca Loan: Not enough funds to collect");

        _status = Status.ACTIVE;
        _nextPayment = block.timestamp.add(_startPaymentDelay);
        require(_token.transfer(_borrower, _target), "Housteca Loan: Token transfer failed");
    }


    ///////////// Status ACTIVE /////////////

    function shouldUpdateStatus()
      public
      view
      returns (bool)
    {
        // TODO: check if the contract should update its state
        return false;
    }

    function update()
      public
    {
        // TODO: update the status of this loan
    }

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
            _status = Status.FINISHED;
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
        Investment storage investment = _investments[msg.sender];
        require(investment.timesCollected < _timesPaid, "Housteca Loan: No amount left to collect for now");
        uint amountToCollect = (_timesPaid.sub(investment.timesCollected)).mul(paymentAmount());
        require(_token.transfer(msg.sender, amountToCollect), "Housteca Loan: Token transfer failed");
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

        if (_status == Status.CREATED) {
            _invest(from, amount);
        } else if (_status == Status.ACTIVE) {
            _pay(from, amount);
        } else {
            revert("Housteca Loan: Cannot accept ERC777 funds in the current state");
        }
    }
}
