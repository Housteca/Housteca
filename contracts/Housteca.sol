pragma solidity 0.5.13;

import "./Loan.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";


contract Housteca
{
    ///////////// Constants /////////////

    uint8 constant public ADMIN_ROOT_LEVEL = (2 ** 8) - 1;
    uint constant public GRACE_PERIOD_PROPOSAL = 15 days;


    ///////////// Structs /////////////

    struct InvestmentProposal
    {
        string symbol;
        uint target;
        uint totalPayments;
        uint periodicity;
        uint created;
        uint insurance;
        uint interestRatio;
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
        uint insurance,
        uint totalPayments,
        uint periodicity,
        uint interestRatio
    );
    event InvestmentProposalRemoved(
        address indexed borrower
    );
    event InvestmentCreated(
        address indexed borrower,
        string indexed symbol,
        uint target,
        uint insurance,
        uint totalPayments,
        uint periodicity,
        uint interestRatio
    );


    ///////////// Attributes /////////////

    mapping (address => uint8) public _admins;
    mapping (address => bool) public _investors;
    mapping (string => IERC20) public _tokens;
    mapping (address => InvestmentProposal) public _proposals;
    Loan[] public _loans;


    ///////////// Modifiers /////////////

    modifier isAdmin(uint8 level)
    {
        require(_admins[msg.sender] >= level, "Housteca: Insufficient administrator privileges");
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
        _admins[msg.sender] = ADMIN_ROOT_LEVEL;
        emit AdminAdded(msg.sender, ADMIN_ROOT_LEVEL);
    }

    function addAdmin(
        address addr,
        uint8 level
    )
      external
      isAdmin(level + 1)
    {
        require(level > 0, "Housteca: Must provide a level greater than zero");

        emit AdminAdded(addr, level);
        _admins[addr] = level;
    }

    function removeAdmin(
        address addr
    )
      external
      isAdmin(_admins[addr] + 1)
    {
        emit AdminRemoved(addr, _admins[addr]);
        _admins[addr] = 0;
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

    function createInvestmentProposal(
        address borrower,
        string calldata symbol,
        uint target,
        uint total,
        uint totalPayments,
        uint periodicity,
        uint insurance,
        uint interestRatio
    )
      external
      isAdmin(ADMIN_ROOT_LEVEL - 2)
    {
        require(target > 0, "Housteca: Target amount must be greater than zero");
        require(insurance > 0, "Housteca: The insurance must be greater than zero");
        require(interestRatio > 0, "Housteca: The interest ratio must be greater than zero");
        require(totalPayments > 0, "Housteca: The total number of payments must be greater than zero");
        require(total > target, "Housteca: The total amount must be greater than the target amount");
        require(address(_tokens[symbol]) != address(0), "Housteca: Invalid token symbol");

        _proposals[borrower] = InvestmentProposal({
            symbol: symbol,
            target: target,
            totalPayments: totalPayments,
            periodicity: periodicity,
            created: block.timestamp,
            insurance: insurance,
            interestRatio: interestRatio
        });

        emit InvestmentProposalCreated(borrower, symbol, target, insurance, totalPayments, periodicity, interestRatio);
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
        require(proposal.target > 0, "Housteca: There is no investment proposal for this address");
        require(proposal.created + GRACE_PERIOD_PROPOSAL < block.timestamp, "Housteca: the period to create the investment has expired");

        IERC20 token = getToken(proposal.symbol);
        Loan loan = new Loan(
            this,
            token,
            proposal.target,
            proposal.totalPayments,
            proposal.periodicity,
            proposal.insurance,
            proposal.interestRatio
        );
        _loans.push(loan);
        emit InvestmentCreated(
            msg.sender,
            proposal.symbol,
            proposal.target,
            proposal.totalPayments,
            proposal.periodicity,
            proposal.insurance,
            proposal.interestRatio
        );
    }
}

