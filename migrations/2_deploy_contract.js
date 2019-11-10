const Housteca = artifacts.require("Housteca");


module.exports = async deployer => {
    await deployer.deploy(Housteca);
};
