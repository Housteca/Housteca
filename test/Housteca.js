const Housteca = artifacts.require('Housteca');
const Property = artifacts.require('Property');
const Loan = artifacts.require('Loan');
const TestERC20Token = artifacts.require('TestERC20Token');
const TestERC777Token = artifacts.require('TestERC777Token');
const truffleAssert = require('truffle-assertions');
const { singletons, constants } = require('@openzeppelin/test-helpers');
const { ZERO_ADDRESS } = constants;


const toBN = web3.utils.toBN;
const toAmount = (amount, decimals) => toBN(amount).mul(toBN(10).pow(toBN(decimals)));

const ADMIN_LEVEL = 254;
const LOCAL_NODE_LEVEL = 253;


contract("Housteca", accounts => {
    const manager = accounts[0];
    const admin = accounts[1];
    const localNode = accounts[2];
    const borrower = accounts[9];
    const downpaymentRatio = toAmount(2, 17);  // 20% of the house belongs to Juan
    const targetAmount = toAmount(96000, 18);  // Juan needs $96000
    const totalPayments = toBN(120);
    const insuredPayments = toBN(6);
    const paymentAmount = toAmount(1058, 18);
    const perPaymentInterestRatio = toAmount(1619, 11);  // 0.01619% daily interest
    let erc1820, erc777, erc20, propertyToken, housteca, loan;

    const createInvestmentProposal = async () => {
        const symbol = await erc777.symbol();
        return housteca.createInvestmentProposal(
            borrower,
            symbol,
            downpaymentRatio,
            targetAmount,
            totalPayments,
            insuredPayments,
            paymentAmount,
            perPaymentInterestRatio,
            {from: localNode}
        );
    };

    beforeEach(async () => {
        erc1820 = await singletons.ERC1820Registry(manager);
        erc777 = await TestERC777Token.new();
        erc20 = await TestERC20Token.new();
        propertyToken = await Property.new();
        housteca = await Housteca.new(propertyToken.address);
        propertyToken.addMinter(housteca.address);
        propertyToken.transferOwnership(housteca.address);
    });

    contract('After contract creation', () => {
        it('should have the correct root administrator', async () => {
            const isAdmin = await housteca.isAdmin(manager);
            assert.isOk(isAdmin);
        });
        it('should have the correct Property token address', async () => {
            const propertyTokenAddress = await housteca._propertyToken();
            assert.equal(propertyTokenAddress, propertyToken.address);
        });
    });

    contract('Manage investors', () => {
        it('should successfully add, check and delete an investor', async () => {
            const investor = accounts[1];
            let isInvestor = await housteca.isInvestor(investor);
            assert.isNotOk(isInvestor);
            let tx = await housteca.addInvestor(investor);
            truffleAssert.eventEmitted(tx, 'InvestorAdded', {investor});
            isInvestor = await housteca.isInvestor(investor);
            assert.isOk(isInvestor);
            tx = await housteca.removeInvestor(investor);
            truffleAssert.eventEmitted(tx, 'InvestorRemoved', {investor});
            isInvestor = await housteca.isInvestor(investor);
            assert.isNotOk(isInvestor);
        });
    });

    contract('Manage admins and local nodes', () => {
        it('should successfully add, check and delete an admin', async () => {
            const level = toBN(ADMIN_LEVEL);
            let isAdmin = await housteca.isAdmin(admin);
            assert.isNotOk(isAdmin);
            let tx = await housteca.addAdmin(admin, level, 0);
            truffleAssert.eventEmitted(tx, 'AdminAdded', {admin, level});
            isAdmin = await housteca.isAdmin(admin);
            assert.isOk(isAdmin);
            tx = await housteca.removeAdmin(admin);
            truffleAssert.eventEmitted(tx, 'AdminRemoved', {admin, level});
            isAdmin = await housteca.isAdmin(admin);
            assert.isNotOk(isAdmin);
        });

        it('should successfully add, check and delete a local node', async () => {
            const localNode = accounts[5];
            const level = toBN(LOCAL_NODE_LEVEL);
            let isLocalNode = await housteca.isLocalNode(localNode);
            assert.isNotOk(isLocalNode);
            let tx = await housteca.addAdmin(localNode, level, toBN(1e16));
            truffleAssert.eventEmitted(tx, 'AdminAdded', {admin: localNode, level});
            isLocalNode = await housteca.isLocalNode(localNode);
            assert.isOk(isLocalNode);
            tx = await housteca.removeAdmin(localNode);
            truffleAssert.eventEmitted(tx, 'AdminRemoved', {admin: localNode, level});
            isLocalNode = await housteca.isLocalNode(localNode);
            assert.isNotOk(isLocalNode);
        });
    });

    contract('Manage Housteca fees', () => {
        it('should be able to set the fee %', async () => {
            let feeRatio = await housteca._houstecaFeeRatio();
            assert.deepEqual(feeRatio, toBN(10).pow(toBN(16)));
            const newFee = toAmount(2, 16);
            await housteca.setHoustecaFeeRatio(newFee);
            feeRatio = await housteca._houstecaFeeRatio();
            assert.deepEqual(feeRatio, newFee);
        });
    });

    contract('Manage tokens', () => {
        it('should be able to add and remove ERC20 tokens', async () => {
            const symbol = await erc20.symbol();
            const contractAddress = erc20.address;
            let tx = await housteca.addToken(symbol, contractAddress);
            truffleAssert.eventEmitted(tx, 'TokenAdded', {symbol, contractAddress});
            let erc20Address = await housteca._tokens(symbol);
            assert.equal(erc20Address, contractAddress);
            tx = await housteca.removeToken(symbol);
            truffleAssert.eventEmitted(tx, 'TokenRemoved', {symbol, contractAddress});
            erc20Address = await housteca._tokens(symbol);
            assert.equal(erc20Address, ZERO_ADDRESS);
        });
    });

    contract('Proposal management', () => {
        beforeEach(async () => {
            await housteca.addAdmin(localNode, LOCAL_NODE_LEVEL, toAmount(2, 16));
            const symbol = await erc777.symbol();
            await housteca.addToken(symbol, erc777.address);
            await housteca.setHoustecaFeeRatio(toAmount(1, 16));
        });

        it('should be able to create and remove investment proposals', async () => {
            let tx = await createInvestmentProposal();
            const symbol = await erc777.symbol();
            truffleAssert.eventEmitted(tx, 'InvestmentProposalCreated',
                {
                    borrower,
                    symbol,
                    targetAmount,
                    insuredPayments,
                    paymentAmount,
                    perPaymentInterestRatio
                });
            let proposal = await housteca._proposals(borrower);
            assert.equal(proposal.localNode, localNode);
            assert.deepEqual(proposal.targetAmount, targetAmount);
            assert.equal(proposal.symbol, symbol);
            assert.deepEqual(proposal.downpaymentRatio, downpaymentRatio);
            assert.deepEqual(proposal.insuredPayments, insuredPayments);
            assert.deepEqual(proposal.paymentAmount, paymentAmount);
            assert.deepEqual(proposal.perPaymentInterestRatio, perPaymentInterestRatio);
            assert.deepEqual(proposal.houstecaFeeAmount, toAmount(960, 18));
            assert.deepEqual(proposal.localNodeFeeAmount, toAmount(1920, 18));
            tx = await housteca.removeInvestmentProposal(borrower);
            truffleAssert.eventEmitted(tx, 'InvestmentProposalRemoved', {borrower});
            proposal = await housteca._proposals(borrower);
            assert.equal(proposal.localNode, ZERO_ADDRESS);
        });

        it('should be able to create Investments from proposals', async () => {
            await createInvestmentProposal();
            let investments = await housteca.loans();
            const symbol = await erc777.symbol();
            const totalInvestments = investments.length;
            let tx = await housteca.createInvestment({from: borrower});
            investments = await housteca.loans();
            assert.equal(totalInvestments + 1, investments.length);
            const contractAddress = investments[investments.length - 1];
            truffleAssert.eventEmitted(tx, 'InvestmentCreated',
                {
                    contractAddress,
                    borrower,
                    localNode,
                    symbol,
                    targetAmount,
                    insuredPayments,
                    paymentAmount,
                });
        });
    });
});
