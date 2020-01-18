pragma solidity 0.5.13;
pragma experimental ABIEncoderV2;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC777/IERC777Recipient.sol";
import "openzeppelin-solidity/contracts/cryptography/ECDSA.sol";
import "openzeppelin-solidity/contracts/introspection/IERC1820Registry.sol";
import "./Housteca.sol";
import "./Property.sol";


contract Loan is IERC777Recipient, IERC1400TokensRecipient
{
    ///////////// Constants /////////////

    /// Period of time for the investors to send funds to the contract
    uint constant public FUNDING_PERIOD = 90 days;
    /// Period of time for the borrower to deposit the initial stake
    uint constant public INITIAL_STAKE_PERIOD = 15 days;
    /// The number of seconds to make the next payment
    uint constant public PERIODICITY = 1;
    /// The number to multiply ratios for (solidity doesn't store floating point numbers)
    uint constant public RATIO = 10 ** 18;
    /// Total amount of property tokens
    uint constant public TOTAL_PROPERTY_TOKENS = 10 ** 18;


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
    bytes32 constant public ERC1400_TOKENS_RECIPIENT_INTERFACE_HASH = keccak256("ERC1400TokensRecipient");

    /// User that buys a house
    address public _borrower;
    /// Token used to pay and fund
    IERC20 public _token;
    /// Current status of the contract
    Status public _status;
    /// Address of Housteca's main contract
    Housteca public _housteca;
    /// Array of images
    string[] public _images;
    /// Address of the local node
    address public _localNode;
    /// Map to keep track of investor's funding
    mapping(address => uint) public _investments;
    /// Map to keep track of the times each investor collected his earnings
    mapping(address => uint) public _timesCollected;
    /// Map to keep track of the times each investor collected his earnings from the insurance
    mapping(address => uint) public _timesCollectedDefault;
    /// Checks whether the investor collected the property in case of bankrupt or not
    mapping(address => bool) public _propertyCollected;
    /// Amount investors have to reach
    uint public _targetAmount;
    /// Number of payments to be made to return the initial investment
    uint public _totalPayments;
    /// Times the borrower paid
    uint public _timesPaid;
    /// Times the contract is in default State
    uint public _timesDefault;
    /// Timestamp of the next payment
    uint public _nextPayment;
    /// Timestamp that exposes the maximum date available to send the initial stake to this contract
    uint public _stakeDepositDeadline;
    /// Timestamp that exposes the maximum date available to fund this contract
    uint public _fundingDeadline;
    /// Timestamp that exposes the maximum date available to get the signatures
    uint public _signingDeadline;
    /// Number of payments that will be given as insurance
    uint public _insuredPayments;
    /// Percentage of the property already owned by the borrower
    uint public _downpaymentRatio;
    /// Amount paid for every scheduled payment
    uint public _paymentAmount;
    /// Interest paid per payment
    uint public _perPaymentInterestRatio;
    /// Total amount of the property that has been paid by returning the loan
    uint public _amortizedAmount;
    /// Total amount deposited by the investors
    uint public _investedAmount;
    /// Fee for the local node
    uint public _localNodeFeeAmount;
    /// Fee for Housteca
    uint public _houstecaFeeAmount;
    /// Extra amount for the investors taken from the stake in case of unsuccessful events
    uint public _extraAmount;
    /// Signature of the local node
    bytes public _localNodeSignature;
    /// Signature of the borrower;
    bytes public _borrowerSignature;
    /// Hash of the document that proves the actual acquisition of the property
    bytes32 public _documentHash;
    /// Amount of tokens that belong to the borrower
    uint public _transferredTokens;
    /// Checks whether Property tokens are received
    bool public _propertyTokensReceived;


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
        return _paymentAmount.mul(_totalPayments);
    }

    /// Gets the ratio of investment for the called.
    function investmentRatio(
        address addr
    )
      public
      view
      returns (uint)
    {
        return _investments[addr].mul(RATIO).div(_targetAmount);
    }

    /// Checks whether the period for the borrower to pay has expired or not.
    function paymentPeriodExpired()
      public
      view
      returns (bool)
    {
        return (_status == Status.ACTIVE || _status == Status.DEFAULT) && block.timestamp > _nextPayment;
    }

    /// Check whether the period to deposit the initial stake has expired or not.
    function stakeDepositPeriodExpired()
      public
      view
      returns (bool)
    {
        return _status == Status.AWAITING_STAKE && block.timestamp > _stakeDepositDeadline && _stakeDepositDeadline > 0;
    }

    /// Checks if the contract has been signed on time by the borrower and the local node.
    function signingPeriodExpired()
      public
      view
      returns (bool)
    {
        return _status == Status.AWAITING_SIGNATURES && block.timestamp > _signingDeadline && _signingDeadline > 0;
    }

    /// Checks if the funding period has expired.
    function fundingPeriodExpired()
      public
      view
      returns (bool)
    {
        return _status == Status.AWAITING_STAKE && block.timestamp > _fundingDeadline && _fundingDeadline > 0;
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

    /// Gets the Property contract
    function propertyToken()
      public
      view
      returns (Property)
    {
        return _housteca._propertyToken();
    }

    /// Gets the partition of the Property's security token
    function partition()
      public
      view
      returns (bytes32)
    {
        return keccak256(abi.encodePacked(address(this)));
    }

    function images()
      public
      view
      returns (string[] memory)
    {
        return _images;
    }


    /********** Generic functions *********/

    /// Adds the IPFS hash of a new image of the property
    function addImage(
        string calldata hash
    )
      external
    {
        require(isLocalNode(msg.sender) || isBorrower(msg.sender), "Housteca Loan: permission denied");

        _images.push(hash);
    }

    /// Gets details of this investment
    function details()
      external
      view
      returns (address, address, address, uint, uint, uint, uint, uint, uint, uint, uint, Status)
    {
        return (
            _borrower,
            _localNode,
            address(_token),
            _downpaymentRatio,
            _targetAmount,
            _totalPayments,
            _insuredPayments,
            _paymentAmount,
            _perPaymentInterestRatio,
            _localNodeFeeAmount,
            _houstecaFeeAmount,
            _status
        );
    }

    /// Gets the amounts of Property tokens that belong to a given address
    function propertyTokenAmount(
        address addr
    )
      public
      view
      returns (uint)
    {
        if (addr == _borrower) {
            return _transferredTokens;
        }
        uint availableTokens = TOTAL_PROPERTY_TOKENS.sub(_transferredTokens);
        return availableTokens.mul(investmentRatio(addr)).div(RATIO);
    }

    /*********** Status AWAITING_STAKE ************/

    constructor(
        address borrower,
        address localNode,
        address tokenAddress,
        uint downpaymentRatio,
        uint targetAmount,
        uint totalPayments,
        uint insuredPayments,
        uint paymentAmount,
        uint perPaymentInterestRatio,
        uint localNodeFeeAmount,
        uint houstecaFeeAmount
    )
      public
    {
        _borrower = borrower;
        _housteca = Housteca(msg.sender);
        _localNode = localNode;
        _token = IERC20(tokenAddress);
        _downpaymentRatio = downpaymentRatio;
        _targetAmount = targetAmount;
        _totalPayments = totalPayments;
        _insuredPayments = insuredPayments;
        _paymentAmount = paymentAmount;
        _perPaymentInterestRatio = perPaymentInterestRatio;
        _localNodeFeeAmount = localNodeFeeAmount;
        _houstecaFeeAmount = houstecaFeeAmount;
        _stakeDepositDeadline = block.timestamp.add(INITIAL_STAKE_PERIOD);
        _status = Status.AWAITING_STAKE;

        // We are dealing with a ERC777 and ERC1400 tokens, so we must register the interfaces
        ERC1820.setInterfaceImplementer(address(this), ERC777_TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
        ERC1820.setInterfaceImplementer(address(this), ERC1400_TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
    }

    /// Internal function used to handle the received initial stake.
    /// It transitions to the FUNDING status.
    function _sendInitialStake(
        address from,
        uint amount
    )
      internal
      checkStatus(Status.AWAITING_STAKE)
    {
        require(_propertyTokensReceived, "Housteca Loan: Property tokens not received");
        require(isBorrower(from), "Housteca Loan: Only the borrower can deposit the initial stake");
        require(amount == initialStakeAmount(), "Housteca Loan: invalid initial stake amount");

        _fundingDeadline = block.timestamp.add(FUNDING_PERIOD);
        _changeStatus(Status.FUNDING);
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
        if (_investedAmount == _targetAmount) {
            _changeStatus(Status.AWAITING_SIGNATURES);
        }
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

        uint extraAmount = _extraAmount.mul(investmentRatio(msg.sender)).div(RATIO);
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
        require(isLocalNode(msg.sender), "Housteca Loan: Only the local node can perform this operation");
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
        require(_status == Status.AWAITING_SIGNATURES || _status == Status.FUNDING, "Housteca Loan: Invalid status");
        require(isLocalNode(msg.sender), "Housteca Loan: Only the local node can perform this operation");

        _changeStatus(Status.UNCOMPLETED);
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
        propertyToken().transferByPartition(partition(), to, amount, new bytes(0));
    }

    /// The local node takes his funds after all signatures are OK.
    function collectAllFunds()
      external
      checkStatus(Status.AWAITING_SIGNATURES)
    {
        require(_borrowerSignature.length > 0 && _localNodeSignature.length > 0, "Housteca Loan: Signatures not ready");
        require(isLocalNode(msg.sender), "Housteca Locan: Only the local node can perform this operation");

        uint insuranceAmount = _paymentAmount.mul(_insuredPayments);
        uint amountToTransfer = _targetAmount.sub(insuranceAmount).add(_localNodeFeeAmount);
        _nextPayment = block.timestamp.add(PERIODICITY);
        _changeStatus(Status.ACTIVE);
        // This is important: funds are transferred to the local node, not the borrower
        _transfer(_localNode, amountToTransfer);
        // Also transfer funds to Housteca
        _transfer(address(_housteca), _houstecaFeeAmount);
        // transfer the tokens to the borrower
        _transferredTokens = _downpaymentRatio.mul(TOTAL_PROPERTY_TOKENS).div(RATIO);
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
        require(amount == _paymentAmount, "Housteca Loan: Invalid amount to pay");
        require(_nextPayment <= block.timestamp.add(PERIODICITY), "Housteca Loan: It is too soon to pay");

        _timesPaid += 1;
        uint tokensToTransfer = 0;
        if (_timesPaid >= _totalPayments) {
            _amortizedAmount = _targetAmount;
            _changeStatus(Status.FINISHED);
            _nextPayment = 0;
            _transferredTokens = TOTAL_PROPERTY_TOKENS;
        } else {
            // Switch to ACTIVE if it was in DEFAULT
            _changeStatus(Status.ACTIVE);
            _nextPayment = _nextPayment.add(PERIODICITY);
            uint remainingNonAmortizedAmount = _targetAmount.sub(_amortizedAmount);
            uint interestAmount = remainingNonAmortizedAmount.mul(_perPaymentInterestRatio).div(RATIO);
            uint amortization = _paymentAmount.sub(interestAmount);
            _amortizedAmount = _amortizedAmount.add(amortization);
            uint availableTokens = TOTAL_PROPERTY_TOKENS.mul(RATIO.sub(_downpaymentRatio)).div(RATIO);
            tokensToTransfer = amortization.mul(availableTokens).div(_targetAmount);
            _transferredTokens = _transferredTokens.add(tokensToTransfer);
        }
    }

    /// Pure ERC20 function used by the borrower to pay
    function pay()
      external
    {
        require(_token.transferFrom(msg.sender, address(this), _paymentAmount), "Housteca Loan: Token transfer failed");

        _pay(msg.sender, _paymentAmount);
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
        uint amountToCollect = _paymentAmount.mul(investmentRatio(msg.sender)).div(RATIO);
        if (_timesCollected[msg.sender] < _timesPaid) {
            _timesCollected[msg.sender] += 1;
        } else if (_timesCollectedDefault[msg.sender] < _timesDefault) {
            _timesCollectedDefault[msg.sender] += 1;
        } else {
            revert("Housteca Loan: Not enough funds to collect");
        }
        _transfer(msg.sender, amountToCollect);
    }


    ///////////// Status change /////////////

    /// Switches the contract to a new status
    function _changeStatus(Status status)
      internal
    {
        if (status != _status) {
            emit StatusChanged(_status, status);
            _status = status;
        }
    }

    /// Updates the status of this contract.
    /// This function can be called by anyone.
    function update()
      public
    {
        if (stakeDepositPeriodExpired()) {
            _changeStatus(Status.UNCOMPLETED);
        } else if (fundingPeriodExpired()) {
            // the local node should have aborted the contract manually
            // in this scenario the borrower gets all the stake back
            _transferUnsafe(_borrower, initialStakeAmount());
            _changeStatus(Status.UNCOMPLETED);
        } else if (paymentPeriodExpired()) {
            if (_timesDefault >= _insuredPayments) {
                _changeStatus(Status.BANKRUPT);
            } else {
                _changeStatus(Status.DEFAULT);
                _timesDefault += 1;
                _nextPayment = _nextPayment.add(PERIODICITY);
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

    /// Checks whether it can receive ERC1400 tokens
    function canReceive(
        bytes32 partitionParam,
        address /* from */,
        address /* to */,
        uint /* value */,
        bytes calldata /* data */,
        bytes calldata /* operatorData */
    )
      external
      view
      returns(bool)
    {
        return partitionParam == partition();
    }

    /// Hook for receiving ERC1400 tokens
    function tokensReceived(
        bytes32 /* partition */,
        address /* operator */,
        address /* from */,
        address /* to */,
        uint /* value */,
        bytes calldata /* data */,
        bytes calldata /* operatorData */
    )
      external
    {
        _propertyTokensReceived = true;
    }
}
