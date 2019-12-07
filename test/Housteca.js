const Housteca = artifacts.require('Housteca');
const Property = artifacts.require('Property');
const Loan = artifacts.require('Loan');
const TestERC20Token = artifacts.require('TestERC20Token');
const TestERC777Token = artifacts.require('TestERC777Token');
const truffleAssert = require('truffle-assertions');
const { expectEvent, singletons, constants } = require('@openzeppelin/test-helpers');
const { ZERO_ADDRESS } = constants;


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
            let tx = await housteca.addInvestor(accounts[1]);
            isInvestor = await housteca.isInvestor(investor);
            assert.isOk(isInvestor);
            truffleAssert.eventEmitted(tx, 'InvestorAdded', event => {
                return event.investor === investor;
            });
            tx = await housteca.removeInvestor(investor);
            isInvestor = await housteca.isInvestor(investor);
            assert.isNotOk(isInvestor);
            truffleAssert.eventEmitted(tx, 'InvestorRemoved', event => {
                return event.investor === investor;
            });
        });
    });
});
