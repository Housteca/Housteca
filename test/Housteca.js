const Housteca = artifacts.require('Housteca');
const Loan = artifacts.require('Loan');
const TestERC20Token = artifacts.require('TestERC20Token');
const TestERC777Token = artifacts.require('TestERC777Token');
const truffleAssert = require('truffle-assertions');
const { expectEvent, singletons, constants } = require('@openzeppelin/test-helpers');
const { ZERO_ADDRESS } = constants;


contract("Housteca", accounts => {
    beforeEach(async function () {
        this.erc1820 = await singletons.ERC1820Registry(registryFunder);
        this.erc777 = await TestERC777Token.new({ from: accounts[0] });
        this.erc20 = await TestERC20Token.new({ from: accounts[0] });
    });
});
