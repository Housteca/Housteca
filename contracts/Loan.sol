pragma solidity 0.5.13;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC777/IERC777Recipient.sol";
import "openzeppelin-solidity/contracts/cryptography/ECDSA.sol";
import "openzeppelin-solidity/contracts/introspection/IERC1820Registry.sol";
import "./Housteca.sol";
import "./Property.sol";


contract Loan is IERC777Recipient
{
    ///////////// Constants /////////////

    /// Period of time for the investors to send funds to the contract
    uint constant public FUNDING_PERIOD = 90 days;
    /// Period of time for the borrower to deposit the initial stake
    uint constant public INITIAL_STAKE_PERIOD = 15 days;
    /// The number of seconds to make the next payment
    uint constant public PERIODICITY = 30 days;
    /// The number to multiply ratios for (solidity doesn't store floating point numbers)
    uint constant public RATIO = 10000;


    ///////////// Libraries /////////////

    using SafeMath for uint;


    ///////////// Enums /////////////

    enum Status
    {
        AWAITING_STAKE,         // the loan is waiting for the borrower to deposit the stake
        FUNDING,                // the loan is expecting to receive funds
        AWAITING_SIGNATURES,    // the loan got enough funding and now requires the signatures
        ACTIVE,                 // the loan got the signatures and has to be paid
        FINISHED,               // the load has been successfully paid and no longer supports operations
        UNCOMPLETED,            // the loan did not get enough funding and no longer supports operations
        DEFAULT,                // the borrower did not pay on time, but there is still insurance left
        BANKRUPT                // the loan got enough funding but the borrower did not pay on time
    }


    ///////////// Events /////////////

    event StatusChanged(Status indexed from, Status indexed to);


    ///////////// Attributes /////////////

    /// Registry for ERC777 tokens
    IERC1820Registry constant public ERC1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 constant public ERC777_TOKENS_RECIPIENT_INTERFACE_HASH = keccak256("ERC777TokensRecipient");

    /// User that buys a house
    address public _borrower;
    /// Token used to pay and fund
    IERC20 public _token;
    /// Current status of the contract
    Status public _status;
    /// Address of Housteca's main contract
    Housteca public _housteca;
    /// Address of the local node
    address _localNode;
    /// Map to keep track of investor's funding
    mapping(address => uint) public _investments;
    /// Map to keep track of the timestamp when each investor collected his earnings
    mapping(address => uint) public _lastCollected;
    /// Checks whether the investor collected the property in case of bankrupt or not
    mapping(address => bool) public _propertyCollected;
    /// Amount investors have to reach
    uint public _targetAmount;
    /// Number of payments to be made to return the initial investment
    uint public _totalPayments;
    /// Timestamp of the next payment
    uint public _nextPayment;
    /// Amount the borrower already paid
    uint public _paidAmount;
    /// Timestamp that exposes the maximum date available to send the initial stake to this contract
    uint public _stakeDepositDeadline;
    /// Timestamp that exposes the maximum date available to fund this contract
    uint public _fundingDeadline;
    /// Timestamp that exposes the maximum date available to get the signatures
    uint public _signingDeadline;
    /// Number of payments that will be given as insurance
    uint public _insuredPayments;
    /// Total price of the property
    uint public _downpaymentRatio;
    /// Total amount of interest for this loan
    uint public _interestAmount;
    /// Total invested amount
    uint public _investedAmount;
    /// Fee for the local node
    uint public _localNodeFeeAmount;
    /// Fee for Housteca
    uint public _houstecaFeeAmount;
    /// Extra amount for the investors taken from the stake in case of unsuccessful events
    uint public _extraAmount;
    /// Amount of insurance left
    uint public _insuranceAmount;
    /// Signature of the local node
    bytes public _localNodeSignature;
    /// Signature of the borrower;
    bytes public _borrowerSignature;
    /// Hash of the document that proves the actual acquisition of the property
    bytes32 public _documentHash;


    ///////////// Modifiers /////////////

    /// Checks if the contract is in the given status.
    modifier checkStatus(Status status)
    {
        require(_status == status, "Housteca Loan: Invalid status for this operation");
        _;
    }


    ///////////// View functions /////////////

    /// Checks if msg.sender is the borrower of this loan.
    function isBorrower(
        address addr
    )
      public
      view
      returns (bool)
    {
        return addr == _borrower;
    }

    /// Checks if msg.sender is the local node.
    function isLocalNode(
        address addr
    )
      public
      view
      returns (bool)
    {
        return addr == _localNode;
    }

    /// Checks if the address is a Housteca's verified investor.
    function isVerifiedInvestor(
        address addr
    )
      public
      view
      returns (bool)
    {
        return _housteca.isInvestor(addr);
    }

    /// Checks if the address has invested in this contract.
    function hasInvested(
        address addr
    )
      public
      view
      returns (bool)
    {
        return _investments[addr] > 0;
    }

    /// Gets the initial amount the borrower will have to transfer to this contract as stake.
    function initialStakeAmount()
      public
      view
      returns (uint)
    {
        return _houstecaFeeAmount.add(_localNodeFeeAmount);
    }

    /// Gets the total amount the borrower will have to pay
    function totalAmount()
      public
      view
      returns (uint)
    {
        return _targetAmount.add(_interestAmount);
    }

    /// Gets the amount to pay for each month.
    function paymentAmount()
      public
      view
      returns (uint)
    {
        return totalAmount().div(_totalPayments);
    }

    /// Gets the ratio of investment for the called.
    function investmentRatio()
      public
      view
      returns (uint)
    {
        return _investments[msg.sender].mul(RATIO).div(_targetAmount);
    }

    /// Checks whether the period for the borrower to pay has expired or not.
    function paymentPeriodExpired()
      public
      view
      returns (bool)
    {
        return _status == Status.ACTIVE && block.timestamp > _nextPayment;
    }

    /// Check whether the period to deposit the initial stake has expired or not.
    function stakeDepositPeriodExpired()
      public
      view
      returns (bool)
    {
        return _status == Status.AWAITING_STAKE && block.timestamp > _stakeDepositDeadline;
    }

    /// Checks if the contract has been signed on time by the borrower and the local node.
    function signingPeriodExpired()
      public
      view
      returns (bool)
    {
        return _status == Status.AWAITING_SIGNATURES && block.timestamp > _signingDeadline;
    }

    /// Checks if the funding period has expired.
    function fundingPeriodExpired()
      public
      view
      returns (bool)
    {
        return _status == Status.AWAITING_STAKE && block.timestamp > _fundingDeadline;
    }

    /// Checks if this contract should be updated.
    function shouldUpdate()
      public
      view
      returns (bool)
    {
        return (
            stakeDepositPeriodExpired() ||
            signingPeriodExpired()      ||
            fundingPeriodExpired()      ||
            paymentPeriodExpired()
        );
    }

    // Gets the Property contract
    function propertyToken()
      public
      view
      returns (Property)
    {
        return _housteca._propertyToken();
    }


    ///////////// Status AWAITING_STAKE /////////////

    constructor(
        Housteca housteca,
        address localNode,
        address tokenAddress,
        uint downpaymentRatio,
        uint targetAmount,
        uint totalPayments,
        uint insuredPayments,
        uint interestAmount,
        uint localNodeFeeAmount,
        uint houstecaFeeAmount
    )
      public
    {
        _housteca = housteca;
        _localNode = localNode;
        _token = IERC20(tokenAddress);
        _downpaymentRatio = downpaymentRatio;
        _targetAmount = targetAmount;
        _totalPayments = totalPayments;
        _insuredPayments = insuredPayments;
        _interestAmount = interestAmount;
        _localNodeFeeAmount = localNodeFeeAmount;
        _houstecaFeeAmount = houstecaFeeAmount;
        _borrower = msg.sender;
        _stakeDepositDeadline = block.timestamp.add(INITIAL_STAKE_PERIOD);
        _status = Status.AWAITING_STAKE;

        // We are dealing with an ERC777 tokens, so we must register the interface
        ERC1820.setInterfaceImplementer(address(this), ERC777_TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
    }

    /// Internal function used to handle the received initial stake.
    /// It transitions to the ACTIVE status.
    function _sendInitialStake(
        address from,
        uint amount
    )
      internal
      checkStatus(Status.AWAITING_STAKE)
    {
        require(isBorrower(from), "Housteca Loan: Only the borrower can deposit the initial stake");
        require(amount == initialStakeAmount(), "Housteca Loan: invalid initial stake amount");

        _fundingDeadline = block.timestamp.add(FUNDING_PERIOD);
        changeStatus(Status.ACTIVE);
    }

    /// Sends the initial stake.
    /// Only the borrower can perform this operation.
    /// This function is only used for pure ERC20 tokens.
    function sendInitialStake()
      external
    {
        require(isBorrower(msg.sender), "Housteca Loan: Only the borrower can perform this operation");
        uint amount = initialStakeAmount();
        require(_token.transferFrom(_borrower, address(this), amount), "Housteca Loan: Token transfer failed");

        _sendInitialStake(msg.sender, amount);
    }


    ///////////// Status FUNDING /////////////

    /// Internal function used to handle an investment to this loan.
    function _invest(
        address investor,
        uint amount
    )
      internal
      checkStatus(Status.FUNDING)
    {
        require(isVerifiedInvestor(investor), "Housteca Loan: An investor is required");

        _investedAmount = _investedAmount.add(amount);
        require(_investedAmount <= _targetAmount, "Housteca Loan: Amount sent over required one");

        _investments[msg.sender] = _investments[msg.sender].add(amount);
    }

    /// A Housteca's validated investor invest in this loan.
    /// This function is only used for pure ERC20 tokens.
    function invest(
        uint amount
    )
      external
    {
        require(_token.transferFrom(msg.sender, address(this), amount), "Housteca Loan: Token transfer failed");

        _invest(msg.sender, amount);
    }

    /// The investor takes his investment back.
    /// This can happen for two reasons:
    ///     1. He changed his mind during the FUNDING period.
    ///     2. The loan is in the UNCOMPLETED status.
    ///
    /// The investor might take extra amount in the second case.
    function collectInvestment()
      external
    {
        require(_status == Status.FUNDING || _status == Status.UNCOMPLETED, "Housteca Loan: Invalid status");
        require(hasInvested(msg.sender), "Housteca Loan: No amount invested");

        uint extraAmount = _extraAmount.mul(investmentRatio()).div(RATIO);
        uint amount = _investedAmount.add(extraAmount);
        _investments[msg.sender] = 0;
        _investedAmount = _investedAmount.sub(amount);
        _transfer(msg.sender, amount);
    }


    ///////////// Status AWAITING_SIGNATURES /////////////

    /// Submits the hash of the document that proofs the acquisition of the property
    function submitDocumentHash(
        bytes32 documentHash
    )
      external
      checkStatus(Status.AWAITING_SIGNATURES)
    {
        require(_borrowerSignature.length == 0 || _localNodeSignature.length == 0, "Housteca Loan: The document is already signed");
        _documentHash = documentHash;
        _localNodeSignature.length = 0;
        _borrowerSignature.length = 0;
    }

    /// The local node decided to abort the process.
    /// The borrower looses the stake, and Housteca's fee goes to the investors.
    function abortLoan()
      external
    {
        require(isLocalNode(msg.sender), "Housteca Loan: Only the local node can perform this operation");

        changeStatus(Status.UNCOMPLETED);
        _transferUnsafe(_localNode, _localNodeFeeAmount);
        _extraAmount = _extraAmount.add(_houstecaFeeAmount);
    }

    /// Check the document has been actually signed
    function checkDocumentSignature(
        bytes memory signature,
        address addr
    )
      public
      view
      returns (bool)
    {
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 prefixedHash = keccak256(abi.encodePacked(prefix, _documentHash));
        return ECDSA.recover(prefixedHash, signature) == addr;
    }

    /// Submits the signature of the document using the private key
    function signDocument(
        bytes calldata signature
    )
      external
      checkStatus(Status.AWAITING_SIGNATURES)
    {
        require(checkDocumentSignature(signature, msg.sender), "Housteca Loan: Invalid signature");

        if (isBorrower(msg.sender)) {
            _borrowerSignature = signature;
        } else if (isLocalNode(msg.sender)) {
            _localNodeSignature = signature;
        } else {
            revert("Housteca Loan: You cannot perform this operation");
        }
    }

    /// Transfers property tokens
    function _transferProperty(
        address to,
        uint amount
    )
      internal
    {
        bytes32 partition = keccak256(abi.encodePacked(address(this)));
        propertyToken().transferByPartition(partition, to, amount, new bytes(0));
    }

    /// The local node takes his funds after all signatures are OK.
    function collectAllFunds()
      external
      checkStatus(Status.AWAITING_SIGNATURES)
    {
        require(_borrowerSignature.length > 0 && _localNodeSignature.length > 0, "Housteca Locan: Signatures not ready");
        require(isLocalNode(msg.sender), "Housteca Locan: Only the local node can perform this operation");

        _insuranceAmount = paymentAmount().mul(_insuredPayments);
        uint amountToTransfer = _targetAmount.sub(_insuranceAmount);
        _nextPayment = block.timestamp.add(PERIODICITY);
        changeStatus(Status.ACTIVE);
        // This is important: funds are transferred to the local node, not the borrower
        _transfer(_localNode, amountToTransfer);
        // transfer the tokens to the borrower
        uint propertyAmount = _downpaymentRatio.mul(10 ** propertyToken().granularity()).div(RATIO);
        _transferProperty(_borrower, propertyAmount);
    }


    ///////////// Status ACTIVE - DEFAULT - FINISHED /////////////

    /// Generic function used by the borrower to pay
    function _pay(
        address addr,
        uint amount
    )
      internal
    {
        require(_status == Status.ACTIVE || _status == Status.DEFAULT, "Housteca Loan: Cannot perform this operation in the current status");
        require(addr == _borrower, "Housteca Loan: Only the borrower can pay");
        require(amount == paymentAmount(), "Housteca Loan: Invalid amount to pay");
        require(_nextPayment < block.timestamp.add(PERIODICITY), "Housteca Loan: it is too soon to pay");

        if (_status != Status.ACTIVE) {
            changeStatus(Status.ACTIVE);
        }

        _paidAmount = _paidAmount.add(amount);
        uint paidAmountPlusInsurance = _paidAmount.add(_insuranceAmount);
        uint total = totalAmount();
        if (paidAmountPlusInsurance >= total) {
            changeStatus(Status.FINISHED);
            _nextPayment = 0;
            _insuranceAmount = 0;
            if (paidAmountPlusInsurance > total) {
                // If for whatever reason the total amount actually paid is greater than the one
                // it should have paid, we transfer it to the borrower
                uint diff = paidAmountPlusInsurance.sub(total);
                _transferUnsafe(_borrower, diff);
            }
        } else {
            _nextPayment = _nextPayment.add(PERIODICITY);
        }
    }

    /// Pure ERC20 function used by the borrower to pay
    function pay(
        uint amount
    )
      external
    {
        require(_token.transferFrom(msg.sender, address(this), amount), "Housteca Loan: Token transfer failed");

        _pay(msg.sender, amount);
    }

    /// Function used by the investors to collect the earnings
    /// It only collect one payment, so it will have to be called
    /// several times to collect all of them, if needed
    function collectEarnings()
      external
    {
        require(hasInvested(msg.sender), "Housteca Loan: Only an investor can perform this operation");
        require(
            _status == Status.FINISHED  ||
            _status == Status.BANKRUPT  ||
            _status == Status.ACTIVE    ||
            _status == Status.DEFAULT,
            "Housteca Loan: Invalid status for this operation"
        );
        require(_lastCollected[msg.sender] < _nextPayment.sub(PERIODICITY), "Housteca Loan: No amount left to collect for now");

        uint amountToCollect = paymentAmount().mul(investmentRatio()).div(RATIO);
        if (_paidAmount >= amountToCollect) {
            _paidAmount = _paidAmount.sub(amountToCollect);
            // TODO calculate the tokens to transfer to the borrower dynamically with compound interest
        } else if (_status == Status.DEFAULT && _insuranceAmount >= amountToCollect) {
            _insuranceAmount = _insuranceAmount.sub(amountToCollect);
        } else {
            revert("Housteca Loan: Not enough funds to collect");
        }
        _lastCollected[msg.sender] = block.timestamp;
        _transfer(msg.sender, amountToCollect);
    }


    ///////////// Status BANKRUPT /////////////

    function collectProperty()
      external
    {
        require(hasInvested(msg.sender), "Housteca Loan: Only investors can perform this operation");
        require(!_propertyCollected[msg.sender], "Housteca Loan: You have already collected the property tokens");

        uint totalTokens = 10 ** propertyToken().granularity();
        uint availableTokens = totalTokens.sub(_downpaymentRatio.mul(totalTokens).div(RATIO));
        uint propertyAmount = availableTokens.mul(investmentRatio());
        _propertyCollected[msg.sender] = true;
        _transferProperty(msg.sender, propertyAmount);
    }

    ///////////// Status change /////////////

    /// Switches the contract to a new status
    function changeStatus(Status status)
      internal
    {
        emit StatusChanged(_status, status);
        _status = status;
    }

    /// Updates the status of this contract.
    /// This function can be called by anyone.
    function update()
      public
    {
        if (stakeDepositPeriodExpired()) {
            changeStatus(Status.UNCOMPLETED);
        } else if (fundingPeriodExpired()) {
            // the local node should have aborted the contract manually
            // in this scenario the borrower gets all the stake back
            _transferUnsafe(_borrower, initialStakeAmount());
            changeStatus(Status.UNCOMPLETED);
        } else if (paymentPeriodExpired()) {
            if (_insuranceAmount < paymentAmount()) {
                changeStatus(Status.BANKRUPT);
            } else {
                changeStatus(Status.DEFAULT);
                _nextPayment = block.timestamp.add(PERIODICITY);
            }
        }
    }


    ///////////// Token functions /////////////

    /// Transfer tokens to the desired address. It does not check if the tokens
    /// were successfully transferred
    function _transferUnsafe(
        address receiver,
        uint amount
    )
      internal
      returns (bool)
    {
        return _token.transfer(receiver, amount);
    }

    /// Transfer tokens to the desired address.
    /// Reverts if tokens could not be successfully transferred.
    function _transfer(
        address receiver,
        uint amount
    )
      internal
    {
        require(_transferUnsafe(receiver, amount), "Housteca Loan: Token transfer failed");
    }

    /// Function used as a hook when transferring ERC777 tokens
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
        require(msg.sender == address(_token), "Housteca Loan: This contract does not accept such token");
        require(to == address(this), "Housteca Loan: Invalid ERC777 token receiver");
        if (_status == Status.AWAITING_STAKE) {
            _sendInitialStake(from, amount);
        } else if (_status == Status.FUNDING) {
            _invest(from, amount);
        } else if (_status == Status.ACTIVE || _status == Status.DEFAULT) {
            _pay(from, amount);
        } else {
            revert("Housteca Loan: Cannot accept ERC777 funds in the current state");
        }
    }
}
