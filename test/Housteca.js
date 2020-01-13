const Housteca = artifacts.require('Housteca');
const Property = artifacts.require('Property');
const Loan = artifacts.require('Loan');
const TestERC20Token = artifacts.require('TestERC20Token');
const truffleAssert = require('truffle-assertions');
const { singletons, constants } = require('@openzeppelin/test-helpers');
const { ZERO_ADDRESS } = constants;


const toBN = web3.utils.toBN;
const toAmount = (amount, decimals) => toBN(amount).mul(toBN(10).pow(toBN(decimals)));

const ADMIN_LEVEL = 254;
const LOCAL_NODE_LEVEL = 253;
const DOCUMENT_HASH = '0x38d290a6790cc2d5fd9c26aef474521a0f2d01661247bd8ee6d8e836d93d20b4';
const LOCAL_NODE_SIGNATURE = '0x8679bc6fcf639ebb037a8b0935cd37719069c73490d6a448287200abac82d54606ef5085640130235fcc001bd4d75f36079bb9bb459cac2e86839a3466cbb8ae1b';
const BORROWER_SIGNATURE = '0xa4838ae7ad81bb84721a34884f6eae3c7ba690892ae60e304b788b58f2c118780fa8ccb629087ec0d5f67bc0bae4f7c5bf6d34c81d55f89e7ac595cd1961a9571b';
const RATIO = toBN(10).pow(toBN(18));


contract("Housteca", accounts => {
    const manager = accounts[0];
    const localNode = accounts[1];
    const admin = accounts[2];
    const investor = accounts[7];
    const borrower = accounts[8];
    const totalTokens = toBN(10).pow(toBN(18));
    const downpaymentRatio = toAmount(2, 17);  // 20% of the house belongs to Juan
    const targetAmount = toAmount(96000, 18);  // Juan needs $96000
    const totalPayments = toBN(120);
    const insuredPayments = toBN(6);
    const paymentAmount = toAmount(1058, 18);
    const perPaymentInterestRatio = toAmount(1619, 11);  // 0.01619% daily interest
    let erc1820, erc20, propertyToken, housteca, loan;

    const createInvestmentProposal = async () => {
        const symbol = await erc20.symbol();
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

    const createInvestment = async () => {
        let investments = await housteca.loans();
        const symbol = await erc20.symbol();
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
        return Loan.at(contractAddress);
    };

    beforeEach(async () => {
        erc1820 = await singletons.ERC1820Registry(manager);
        erc20 = await TestERC20Token.new();
        propertyToken = await Property.new();
        housteca = await Housteca.new(propertyToken.address);
        propertyToken.addMinter(housteca.address);
        propertyToken.transferOwnership(housteca.address);
        await erc20.transfer(borrower, '1000000000000000000000000', {from: accounts[0]});
        await erc20.transfer(investor, '1000000000000000000000000', {from: accounts[0]});
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
            const symbol = await erc20.symbol();
            await housteca.addToken(symbol, erc20.address);
            await housteca.setHoustecaFeeRatio(toAmount(1, 16));
        });

        it('should be able to create and remove investment proposals', async () => {
            let tx = await createInvestmentProposal();
            const symbol = await erc20.symbol();
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
            await createInvestment();
        });

        contract('Loan', () => {
            const sendInitialStake = async () => {
                const amount = await loan.initialStakeAmount();
                await erc20.approve(loan.address, amount, {from: borrower});
                const tx = await loan.sendInitialStake({from: borrower});
                truffleAssert.eventEmitted(tx, 'StatusChanged',
                    {
                        from: toBN(0),
                        to: toBN(1)
                    });
            };

            const sendInvestorFunds = async () => {
                const amount = await loan._targetAmount();
                await erc20.approve(loan.address, amount, {from: investor});
                const tx = await loan.invest(amount, {from: investor});
                truffleAssert.eventEmitted(tx, 'StatusChanged',
                    {
                        from: toBN(1),
                        to: toBN(2)
                    });
            };

            const uploadAndSignDocument = async () => {
                let hash = await loan._documentHash();
                assert.equal(hash, '0x0000000000000000000000000000000000000000000000000000000000000000');
                await loan.submitDocumentHash(DOCUMENT_HASH, {from: localNode});
                hash = await loan._documentHash();
                assert.equal(hash, DOCUMENT_HASH);
                await loan.signDocument(LOCAL_NODE_SIGNATURE, {from: localNode});
                await loan.signDocument(BORROWER_SIGNATURE, {from: borrower});
                let localNodeBalance = await erc20.balanceOf(localNode);
                let houstecaBalance = await erc20.balanceOf(housteca.address);
                assert.deepEqual(localNodeBalance, toBN(0));
                assert.deepEqual(houstecaBalance, toBN(0));
                const tx = await loan.collectAllFunds({from: localNode});
                localNodeBalance = await erc20.balanceOf(localNode);
                houstecaBalance = await erc20.balanceOf(housteca.address);
                const localNodeFee = await loan._localNodeFeeAmount();
                const houstecaFee = await loan._houstecaFeeAmount();
                const insuranceAmount = paymentAmount.mul(insuredPayments);
                const amount = targetAmount.add(localNodeFee).sub(insuranceAmount);
                assert.equal(localNodeBalance.toString(), amount.toString());
                assert.deepEqual(houstecaBalance, houstecaFee);
                truffleAssert.eventEmitted(tx, 'StatusChanged',
                    {
                        from: toBN(2),
                        to: toBN(3)
                    });
            };

            beforeEach(async () => {
                await createInvestmentProposal();
                loan = await createInvestment();
                await housteca.addInvestor(investor);
            });

            contract('Status AWAITING_STAKE', () => {
                it('should have the correct status', async () => {
                    const status = await loan._status();
                    assert.deepEqual(status, toBN(0));
                });

                it('should be able to let the borrower send the initial stake', async () => {
                    await sendInitialStake();
                });

                contract('Status FUNDING', () => {
                    beforeEach(async () => {
                        await sendInitialStake();
                    });

                    it('should have the correct status', async () => {
                        const status = await loan._status();
                        assert.deepEqual(status, toBN(1));
                    });

                    it('should switch to UNCOMPLETED after aborting', async () => {
                        await loan.abortLoan({from: localNode});
                        const status = await loan._status();
                        assert.deepEqual(status, toBN(5));
                    });

                    it('should be able to let the investor to send all the funds', async () => {
                        await sendInvestorFunds();
                    });

                    contract('Status AWAITING_SIGNATURES', () => {
                        beforeEach(async () => {
                            await sendInvestorFunds();
                        });

                        it('should not let anyone to sign if no document hash is present', async () => {
                            const hash = await loan._documentHash();
                            const msg = web3.eth.accounts.hashMessage(hash);
                            const signature = web3.eth.sign(msg, localNode);
                            await truffleAssert.fails(loan.signDocument(signature, {from: localNode}));
                        });

                        it('should be able to let the local node to upload a document and sign it', async () => {
                            await uploadAndSignDocument();
                        });

                        it('should have the correct status', async () => {
                            const status = await loan._status();
                            assert.deepEqual(status, toBN(2));
                        });

                        contract('Status ACTIVE', () => {
                            const pay = async () => {
                                const oldNextPayment = await loan._nextPayment();
                                const oldBalance = await erc20.balanceOf(borrower);
                                await erc20.approve(loan.address, paymentAmount, {from: borrower});
                                await loan.pay({from: borrower});
                                const newBalance = await erc20.balanceOf(borrower);
                                assert.equal(newBalance.toString(), oldBalance.sub(paymentAmount).toString());
                                const newNextPayment = await loan._nextPayment();
                                assert.equal(newNextPayment.toString(), oldNextPayment.add(toBN(30 * 24 * 60 * 60)).toString());
                                const transferredTokens = await loan._transferredTokens();
                                const amortizedAmount = await loan._amortizedAmount();
                                const downpaymentTokens = totalTokens.mul(downpaymentRatio).div(RATIO);
                                const amortizedTokens = totalTokens.mul(RATIO.sub(downpaymentRatio)).mul(amortizedAmount).div(targetAmount).div(RATIO);
                                const tokens = downpaymentTokens.add(amortizedTokens);
                                assert.equal(transferredTokens.toString(), tokens.toString());
                            };

                            beforeEach(async () => {
                                await uploadAndSignDocument();
                            });

                            it('should have the correct status', async () => {
                                const status = await loan._status();
                                assert.deepEqual(status, toBN(3));
                            });

                            it('should let the borrower pay the rent', async () => {
                                await pay();
                            });

                            contract('Status FINISHED', () => {
                                beforeEach(async () => {

                                });

                                it('should have the correct status', async () => {
                                    const status = await loan._status();
                                    assert.deepEqual(status, toBN(4));
                                });
                            });

                            contract('Status BANKRUPT', () => {
                                beforeEach(async () => {

                                });

                                it('should have the correct status', async () => {
                                    const status = await loan._status();
                                    assert.deepEqual(status, toBN(7));
                                });
                            });
                        });
                    });
                });
            });
        });
    });
});
