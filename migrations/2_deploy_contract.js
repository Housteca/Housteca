const Housteca = artifacts.require("Housteca");
const TestERC777Token = artifacts.require("TestERC777Token");
const TestERC20Token = artifacts.require("TestERC20Token");
const Property = artifacts.require("Property");
require('@openzeppelin/test-helpers/configure')({ provider: web3.currentProvider, environment: 'truffle' });
const { singletons } = require('@openzeppelin/test-helpers');


module.exports = async (deployer, network, accounts) => {
    if (network === 'development') {
        // In a test environment an ERC777 token requires deploying an ERC1820 registry
        await singletons.ERC1820Registry(accounts[0]);
        await deployer.deploy(TestERC777Token);
        await deployer.deploy(TestERC20Token);
    }

    await deployer.deploy(Property, {gas: 75e5});
    await deployer.deploy(Housteca, Property.address, {gas: 75e5});
    const instance = await Property.deployed();
    await instance.transferOwnership(Housteca.address);
};
