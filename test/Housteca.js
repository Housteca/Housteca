const Housteca = artifacts.require('Housteca');
const Property = artifacts.require('Property');
const Loan = artifacts.require('Loan');
const TestERC20Token = artifacts.require('TestERC20Token');
const TestERC777Token = artifacts.require('TestERC777Token');
const truffleAssert = require('truffle-assertions');
const { singletons } = require('@openzeppelin/test-helpers');


const BN = web3.utils.toBN;

contract("Housteca", accounts => {
    const manager = accounts[0];
    let erc1820, erc777, erc20, propertyToken, housteca, loan;

    beforeEach(async () => {
        erc1820 = await singletons.ERC1820Registry(manager);
        erc777 = await TestERC777Token.new();
        erc20 = await TestERC20Token.new();
        propertyToken = await Property.new();
        housteca = await Housteca.new(propertyToken.address);
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
            const admin = accounts[5];
            const level = BN(254);
            let isAdmin = await housteca.isAdmin(admin);
            assert.isNotOk(isAdmin);
            let tx = await housteca.addAdmin(admin, level, 0, 0);
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
            const level = BN(253);
            let isLocalNode = await housteca.isLocalNode(localNode);
            assert.isNotOk(isLocalNode);
            let tx = await housteca.addAdmin(localNode, level, BN(500), BN(1e16));
            truffleAssert.eventEmitted(tx, 'AdminAdded', {admin: localNode, level});
            isLocalNode = await housteca.isLocalNode(localNode);
            assert.isOk(isLocalNode);
            tx = await housteca.removeAdmin(localNode);
            truffleAssert.eventEmitted(tx, 'AdminRemoved', {admin: localNode, level});
            isLocalNode = await housteca.isLocalNode(localNode);
            assert.isNotOk(isLocalNode);
        });
    });
});
