pragma solidity 0.5.13;

import "./Loan.sol";
import "./Property.sol";
import "openzeppelin-solidity/contracts/math/Math.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";


contract Housteca
{
    ///////////// Constants /////////////

    /// Maximum level of administration of Housteca's contract
    uint8 constant public ADMIN_ROOT_LEVEL = 255;
    /// Number of seconds to keep a proposal alive
    uint constant public PROPOSAL_GRACE_PERIOD = 15 days;
    /// The number to multiply ratios for (solidity doesn't store floating point numbers)
    uint constant public RATIO = 10 ** 18;


    ///////////// Libraries /////////////

    using SafeMath for uint;


    ///////////// Structs /////////////

    struct Administrator
    {
        uint8 level;
        uint feeRatio;
    }

    struct InvestmentProposal
    {
        address localNode;
        string symbol;
        uint downpaymentRatio;
        uint targetAmount;
        uint totalPayments;
        uint insuredPayments;
        uint paymentAmount;
        uint perPaymentInterestRatio;
        uint localNodeFeeAmount;
        uint houstecaFeeAmount;
        uint created;
    }


    ///////////// Events /////////////

    event AdminAdded(
        address indexed admin,
        uint8 indexed level
    );
    event AdminRemoved(
        address indexed admin,
        uint8 indexed level
    );
    event InvestorAdded(
        address indexed investor
    );
    event InvestorRemoved(
        address indexed investor
    );
    event TokenAdded(
        string symbol,
        address indexed contractAddress
    );
    event TokenRemoved(
        string symbol,
        address indexed contractAddress
    );
    event InvestmentProposalCreated(
        address indexed borrower,
        string symbol,
        uint targetAmount,
        uint insuredPayments,
        uint totalPayments,
        uint paymentAmount,
        uint perPaymentInterestRatio
    );
    event InvestmentProposalRemoved(
        address indexed borrower
    );
    event InvestmentCreated(
        address contractAddress,
        address borrower,
        address localNode,
        string symbol,
        uint downpaymentRatio,
        uint targetAmount,
        uint totalPayments,
        uint insuredPayments,
        uint paymentAmount,
        uint localNodeFeeAmount,
        uint houstecaFeeAmount
    );


    ///////////// Attributes /////////////

    mapping (address => Administrator) public _admins;
    mapping (address => bool) public _investors;
    mapping (string => address) public _tokens;
    mapping (address => InvestmentProposal) public _proposals;
    uint public _houstecaFeeRatio;
    Property public _propertyToken;
    address[] public _loans;


    ///////////// Modifiers /////////////

    modifier hasPermissions(uint8 level)
    {
        require(_admins[msg.sender].level >= level, "Housteca: Insufficient administrator privileges");
        _;
    }


    ///////////// View functions /////////////

    function getToken(
        string memory symbol
    )
      public
      view
      returns (address)
    {
        address tokenAddress = _tokens[symbol];
        require(tokenAddress != address(0), "Housteca: The token must be valid");

        return tokenAddress;
    }

    function isInvestor(
        address addr
    )
      public
      view
      returns (bool)
    {
        return _investors[addr];
    }

    function isAdmin(
        address addr
    )
      public
      view
      returns (bool)
    {
        return _admins[addr].level >= ADMIN_ROOT_LEVEL - 1;
    }

    function isLocalNode(
        address addr
    )
      public
      view
      returns (bool)
    {
        return _admins[addr].level >= ADMIN_ROOT_LEVEL - 2;
    }

    function loans()
      public
      view
      returns (address[] memory)
    {
        return _loans;
    }


    ///////////// Admin functions /////////////

    constructor(address propertyToken)
      public
    {
        _admins[msg.sender].level = ADMIN_ROOT_LEVEL;
        _propertyToken = Property(propertyToken);
        _houstecaFeeRatio = RATIO;  // 1% fee by default for Housteca
        emit AdminAdded(msg.sender, ADMIN_ROOT_LEVEL);
    }

    function addAdmin(
        address addr,
        uint8 level,
        uint feeRatio
    )
      external
      hasPermissions(ADMIN_ROOT_LEVEL - 1)
    {
        require(level > 0, "Housteca: Must provide a level greater than zero");

        emit AdminAdded(addr, level);
        _admins[addr] = Administrator({
            level: level,
            feeRatio: feeRatio
        });
    }

    function removeAdmin(
        address addr
    )
      external
      hasPermissions(_admins[addr].level + 1)
    {
        emit AdminRemoved(addr, _admins[addr].level);
        delete _admins[addr];
    }

    function setHoustecaFeeRatio(
        uint houstecaFeeRatio
    )
      external
      hasPermissions(ADMIN_ROOT_LEVEL - 1)
    {
        _houstecaFeeRatio = houstecaFeeRatio;
    }

    function addToken(
        string calldata symbol,
        address tokenAddress
    )
      external
      hasPermissions(ADMIN_ROOT_LEVEL - 1)
    {
        emit TokenAdded(symbol, tokenAddress);
        _tokens[symbol] = tokenAddress;
    }

    function removeToken(
        string calldata symbol
    )
      external
      hasPermissions(ADMIN_ROOT_LEVEL - 1)
    {
        emit TokenRemoved(symbol, address(_tokens[symbol]));
        delete _tokens[symbol];
    }

    function addInvestor(
        address investor
    )
      external
      hasPermissions(ADMIN_ROOT_LEVEL - 2)
    {
        emit InvestorAdded(investor);
        _investors[investor] = true;
    }

    function removeInvestor(
        address investor
    )
      external
      hasPermissions(ADMIN_ROOT_LEVEL - 2)
    {
        emit InvestorRemoved(investor);
        delete _investors[investor];
    }

    function _getFee(
        uint feeRatio,
        uint amount
    )
      internal
      pure
      returns (uint)
    {
        return amount.mul(feeRatio).div(RATIO);
    }

    function createInvestmentProposal(
        address borrower,
        string calldata symbol,
        uint downpaymentRatio,
        uint targetAmount,
        uint totalPayments,
        uint insuredPayments,
        uint paymentAmount,
        uint perPaymentInterestRatio
    )
      external
      hasPermissions(ADMIN_ROOT_LEVEL - 2)
    {
        require(targetAmount > 0, "Housteca: Target amount must be greater than zero");
        require(paymentAmount > 0, "Housteca: The payment amount must be greater than zero");
        require(totalPayments > 0, "Housteca: The total number of payments must be greater than zero");
        require(downpaymentRatio < RATIO, "Housteca: The borrower cannot already own 100% of the property");
        require(address(_tokens[symbol]) != address(0), "Housteca: Invalid token symbol");

        Administrator storage admin = _admins[msg.sender];
        _proposals[borrower] = InvestmentProposal({
            localNode: msg.sender,
            symbol: symbol,
            downpaymentRatio: downpaymentRatio,
            targetAmount: targetAmount,
            totalPayments: totalPayments,
            insuredPayments: insuredPayments,
            paymentAmount: paymentAmount,
            perPaymentInterestRatio: perPaymentInterestRatio,
            localNodeFeeAmount: _getFee(admin.feeRatio, targetAmount),
            houstecaFeeAmount: _getFee(_houstecaFeeRatio, targetAmount),
            created: block.timestamp
        });

        emit InvestmentProposalCreated(borrower, symbol, targetAmount, insuredPayments, totalPayments, paymentAmount, perPaymentInterestRatio);
    }

    function removeInvestmentProposal(
        address borrower
    )
      external
      hasPermissions(ADMIN_ROOT_LEVEL - 2)
    {
        emit InvestmentProposalRemoved(borrower);
        delete _proposals[borrower];
    }

    function createInvestment()
      external
    {
        InvestmentProposal storage proposal = _proposals[msg.sender];
        require(proposal.targetAmount > 0, "Housteca: There is no investment proposal for this address");
        require(proposal.created.add(PROPOSAL_GRACE_PERIOD) < block.timestamp, "Housteca: the period to create the investment has expired");

        // first create the contract
        address tokenAddress = getToken(proposal.symbol);
        Loan loan = new Loan(
            this,
            proposal.localNode,
            tokenAddress,
            proposal.downpaymentRatio,
            proposal.targetAmount,
            proposal.totalPayments,
            proposal.insuredPayments,
            proposal.paymentAmount,
            proposal.perPaymentInterestRatio,
            proposal.localNodeFeeAmount,
            proposal.houstecaFeeAmount
        );
        _loans.push(address(loan));

        // once we have the contract's address, create the tokens
        _propertyToken.issueByPartition(
            keccak256(abi.encodePacked(address(loan))),
            address(loan),
            10 ** _propertyToken.granularity(),
            new bytes(0)
        );

        // lastly, emit the event
        emit InvestmentCreated(
            address(loan),
            msg.sender,
            proposal.localNode,
            proposal.symbol,
            proposal.downpaymentRatio,
            proposal.targetAmount,
            proposal.totalPayments,
            proposal.insuredPayments,
            proposal.paymentAmount,
            proposal.localNodeFeeAmount,
            proposal.houstecaFeeAmount
        );
    }
}

