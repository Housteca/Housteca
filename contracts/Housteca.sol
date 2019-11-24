pragma solidity 0.5.13;

import "./Loan.sol";
import "openzeppelin-solidity/contracts/math/Math.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";


contract Housteca
{
    ///////////// Constants /////////////

    /// Maximum level of administration of Housteca's contract
    uint8 constant public ADMIN_ROOT_LEVEL = 255;
    /// Number of seconds to keep a proposal alive
    uint constant public PROPOSAL_GRACE_PERIOD = 15 days;
    /// The number to multiply ratios for (solidity doesn't store floating point numbers)
    uint constant public RATIO = 10000;


    ///////////// Libraries /////////////

    using SafeMath for uint;


    ///////////// Structs /////////////

    struct Administrator
    {
        uint8 level;
        uint minimumFeeAmount;
        uint feeRatio;
    }

    struct InvestmentProposal
    {
        address localNode;
        string symbol;
        uint downpaymentRatio;
        uint targetAmount;
        uint totalPayments;
        uint periodicity;
        uint insuredPayments;
        uint interestRatio;
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
        string indexed symbol,
        address indexed contractAddress
    );
    event TokenRemoved(
        string indexed symbol,
        address indexed contractAddress
    );
    event InvestmentProposalCreated(
        address indexed borrower,
        string indexed symbol,
        uint target,
        uint insuredPayments,
        uint totalPayments,
        uint periodicity,
        uint interestRatio
    );
    event InvestmentProposalRemoved(
        address indexed borrower
    );
    event InvestmentCreated(
        address borrower,
        address localNode,
        string symbol,
        uint downpaymentRatio,
        uint targetAmount,
        uint totalPayments,
        uint periodicity,
        uint insuredPayments,
        uint interestRatio,
        uint localNodeFeeAmount,
        uint houstecaFeeAmount
    );


    ///////////// Attributes /////////////

    mapping (address => Administrator) public _admins;
    mapping (address => bool) public _investors;
    mapping (string => IERC20) public _tokens;
    mapping (address => InvestmentProposal) public _proposals;
    uint public _houstecaMinFeeAmount;
    uint public _houstecaFeeRatio;
    Loan[] public _loans;


    ///////////// Modifiers /////////////

    modifier isAdmin(uint8 level)
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
      returns (IERC20)
    {
        IERC20 token = _tokens[symbol];
        require(address(token) != address(0), "Housteca: The token must be valid");
        return token;
    }


    ///////////// Admin functions /////////////

    constructor()
      public
    {
        _admins[msg.sender].level = ADMIN_ROOT_LEVEL;
        emit AdminAdded(msg.sender, ADMIN_ROOT_LEVEL);
    }

    function addAdmin(
        address addr,
        uint8 level,
        uint minimumFeeAmount,
        uint feeRatio
    )
      external
      isAdmin(ADMIN_ROOT_LEVEL - 1)
    {
        require(level > 0, "Housteca: Must provide a level greater than zero");

        emit AdminAdded(addr, level);
        _admins[addr] = Administrator({
            level: level,
            minimumFeeAmount: minimumFeeAmount,
            feeRatio: feeRatio
        });
    }

    function removeAdmin(
        address addr
    )
      external
      isAdmin(_admins[addr].level + 1)
    {
        emit AdminRemoved(addr, _admins[addr].level);
        delete _admins[addr];
    }

    function addToken(
        string calldata symbol,
        address token
    )
      external
      isAdmin(ADMIN_ROOT_LEVEL - 1)
    {
        emit TokenAdded(symbol, token);
        _tokens[symbol] = IERC20(token);
    }

    function removeToken(
        string calldata symbol
    )
      external
      isAdmin(ADMIN_ROOT_LEVEL - 1)
    {
        emit TokenRemoved(symbol, address(_tokens[symbol]));
        delete _tokens[symbol];
    }

    function addInvestor(
        address investor
    )
      external
      isAdmin(ADMIN_ROOT_LEVEL - 2)
    {
        emit InvestorAdded(investor);
        _investors[investor] = true;
    }

    function removeInvestor(
        address investor
    )
      external
      isAdmin(ADMIN_ROOT_LEVEL - 2)
    {
        emit InvestorRemoved(investor);
        delete _investors[investor];
    }

    function _getFee(
        uint minimumFeeAmount,
        uint feeRatio,
        uint amount
    )
      internal
      view
      returns (uint)
    {
        return Math.max(minimumFeeAmount, amount.mul(feeRatio).div(RATIO));
    }

    function createInvestmentProposal(
        address borrower,
        string calldata symbol,
        uint downpaymentRatio,
        uint targetAmount,
        uint totalPayments,
        uint periodicity,
        uint insuredPayments,
        uint interestRatio,
        uint localNodeFeeAmount,
        uint houstecaFeeAmount
    )
      external
      isAdmin(ADMIN_ROOT_LEVEL - 2)
    {
        require(targetAmount > 0, "Housteca: Target amount must be greater than zero");
        require(interestRatio > 0, "Housteca: The interest ratio must be greater than zero");
        require(totalPayments > 0, "Housteca: The total number of payments must be greater than zero");
        require(address(_tokens[symbol]) != address(0), "Housteca: Invalid token symbol");

        Administrator storage admin = _admins[msg.sender];
        _proposals[borrower] = InvestmentProposal({
            localNode: msg.sender,
            symbol: symbol,
            downpaymentRatio: downpaymentRatio,
            targetAmount: targetAmount,
            totalPayments: totalPayments,
            periodicity: periodicity,
            insuredPayments: insuredPayments,
            interestRatio: interestRatio,
            localNodeFeeAmount: _getFee(admin.minimumFeeAmount, admin.feeRatio, targetAmount),
            houstecaFeeAmount: _getFee(_houstecaMinFeeAmount, _houstecaFeeRatio, targetAmount),
            created: block.timestamp
        });

        emit InvestmentProposalCreated(borrower, symbol, targetAmount, insuredPayments, totalPayments, periodicity, interestRatio);
    }

    function removeInvestmentProposal(
        address borrower
    )
      external
      isAdmin(ADMIN_ROOT_LEVEL - 2)
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

        IERC20 token = getToken(proposal.symbol);
        Loan loan = new Loan(
            this,
            proposal.localNode,
            token,
            proposal.downpaymentRatio,
            proposal.targetAmount,
            proposal.totalPayments,
            proposal.periodicity,
            proposal.insuredPayments,
            proposal.interestRatio,
            proposal.localNodeFeeAmount,
            proposal.houstecaFeeAmount
        );
        _loans.push(loan);
        emit InvestmentCreated(
            msg.sender,
            proposal.localNode,
            proposal.symbol,
            proposal.downpaymentRatio,
            proposal.targetAmount,
            proposal.totalPayments,
            proposal.periodicity,
            proposal.insuredPayments,
            proposal.interestRatio,
            proposal.localNodeFeeAmount,
            proposal.houstecaFeeAmount
        );
    }
}

