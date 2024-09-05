// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test, console} from "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20_CCIPBnM} from "../src/interfaces/IERC20_CCIPBnM.sol";

import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";

import {IReceiverCCIP} from "../src/interfaces/IReceiverCCIP.sol";
import {IReceiverCCIPMock} from "./mocks/ReceiverCCIPMock.sol";
import {ISenderCCIP} from "../src/interfaces/ISenderCCIP.sol";
import {ISenderCCIPMock} from "./mocks/SenderCCIPMock.sol";
import {IRestakingConnector} from "../src/interfaces/IRestakingConnector.sol";
import {ReceiverCCIP} from "../src/ReceiverCCIP.sol";
import {ISenderHooks} from "../src/interfaces/ISenderHooks.sol";

import {DeployMockEigenlayerContractsScript} from "../script/1_deployMockEigenlayerContracts.s.sol";
import {DeployReceiverOnL1Script} from "../script/3_deployReceiverOnL1.s.sol";
import {DeploySenderOnL2Script} from "../script/2_deploySenderOnL2.s.sol";
import {ClientSigners} from "../script/ClientSigners.sol";
import {EthSepolia, BaseSepolia} from "../script/Addresses.sol";

import {EigenlayerMsgEncoders} from "../src/utils/EigenlayerMsgEncoders.sol";

// 6551 accounts
import {EigenAgent6551} from "../src/6551/EigenAgent6551.sol";
import {EigenAgentOwner721} from "../src/6551/EigenAgentOwner721.sol";
import {IEigenAgent6551} from "../src/6551/IEigenAgent6551.sol";
import {IAgentFactory} from "../src/6551/IAgentFactory.sol";
import {AgentFactory} from "../src/6551/AgentFactory.sol";



contract CCIP_Eigen_CompleteWithdrawal_6551Tests is Test {

    DeployReceiverOnL1Script public deployReceiverOnL1Script;
    DeploySenderOnL2Script public deployOnL2Script;
    DeployMockEigenlayerContractsScript public deployMockEigenlayerContractsScript;
    ClientSigners public clientSigners;

    IReceiverCCIPMock public receiverContract;
    ISenderCCIPMock public senderContract;
    ISenderHooks public senderHooks;
    IRestakingConnector public restakingConnector;

    IStrategyManager public strategyManager;
    IDelegationManager public delegationManager;
    IStrategy public strategy;
    IERC20 public tokenL1;

    IAgentFactory public agentFactory;
    EigenAgentOwner721 public eigenAgentOwnerNft;
    IEigenAgent6551 public eigenAgent;

    uint256 deployerKey;
    address deployer;
    uint256 bobKey;
    address bob;

    uint256 l2ForkId;
    uint256 ethForkId;
    // call params
    uint256 expiry;
    uint256 balanceOfReceiverBefore;
    uint256 balanceOfEigenAgent;

    // SenderHooks.WithdrawalAgentOwnerRootCommitted
    event WithdrawalAgentOwnerRootCommitted(
        bytes32 indexed, // withdrawalAgentOwnerRoot
        address indexed, //  withdrawer (eigenAgent)
        uint256, // amount
        address  // signer (agentOwner)
    );

    function setUp() public {

		deployerKey = vm.envUint("DEPLOYER_KEY");
        deployer = vm.addr(deployerKey);
        vm.deal(deployer, 1 ether);

        bobKey = uint256(56789);
        bob = vm.addr(bobKey);
        vm.deal(bob, 1 ether);

        deployOnL2Script = new DeploySenderOnL2Script();
        deployReceiverOnL1Script = new DeployReceiverOnL1Script();
        deployMockEigenlayerContractsScript = new DeployMockEigenlayerContractsScript();
        clientSigners = new ClientSigners();

        l2ForkId = vm.createFork("basesepolia");        // 0
        ethForkId = vm.createSelectFork("ethsepolia"); // 1

        //////////////////////////////////////////////////////
        //// Setup L1 CCIP and Eigenlayer contracts
        //////////////////////////////////////////////////////
        (
            strategy,
            strategyManager,
            , // IStrategyFactory
            , // pauserRegistry
            delegationManager,
            , // rewardsCoordinator
            tokenL1
        ) = deployMockEigenlayerContractsScript.deployEigenlayerContracts(false);

        //// Setup L1 CCIP contracts and 6551 EigenAgent
        (
            receiverContract,
            restakingConnector,
            agentFactory
        ) = deployReceiverOnL1Script.mockrun();

        vm.deal(address(receiverContract), 1 ether);

        vm.startBroadcast(deployerKey);
        {
            //// allowlist deployer and mint initial balances
            receiverContract.allowlistSender(deployer, true);
            restakingConnector.setEigenlayerContracts(delegationManager, strategyManager, strategy);

            IERC20_CCIPBnM(address(tokenL1)).drip(address(receiverContract));
            IERC20_CCIPBnM(address(tokenL1)).drip(bob);
        }
        vm.stopBroadcast();


        /////////////////////////////////////////
        //// Setup L2 CCIP contracts
        /////////////////////////////////////////
        vm.selectFork(l2ForkId);
        (
            senderContract,
            senderHooks
        ) = deployOnL2Script.mockrun();
        vm.deal(address(senderContract), 1 ether);

        vm.startBroadcast(deployerKey);
        {
            // allow L2 sender contract to receive tokens back from L1
            senderContract.allowlistSourceChain(EthSepolia.ChainSelector, true);
            senderContract.allowlistSender(address(receiverContract), true);
            senderContract.allowlistSender(deployer, true);
            // fund L2 sender with CCIP-BnM tokens
            if (block.chainid == BaseSepolia.ChainId) {
                // drip() using CCIP's BnM faucet if forking from L2 Sepolia
                for (uint256 i = 0; i < 3; ++i) {
                    IERC20_CCIPBnM(BaseSepolia.BridgeToken).drip(address(senderContract));
                }
            }

        }
        vm.stopBroadcast();
    }

    /*
     *
     *
     *             Prepare Eigenlayer State for CompleteWithdrawals
     *
     *
     */

    function handler_DepositAndQueueWithdrawal(uint256 amount) public {

        vm.assume(amount <= 1 ether);
        vm.assume(amount > 0);

        //////////////////////////////////////////////////////
        /// L1: ReceiverCCIP -> EigenAgent -> Eigenlayer
        //////////////////////////////////////////////////////
        vm.selectFork(ethForkId);

        vm.startBroadcast(bobKey);
        eigenAgent = agentFactory.getEigenAgent(bob); // should not exist yet
        require(address(eigenAgent) == address(0), "test assumes no EigenAgent yet");
        vm.stopBroadcast();

        console.log("bob address:", bob);
        console.log("eigenAgent:", address(eigenAgent));
        console.log("---------------------------------------------");
        balanceOfEigenAgent = tokenL1.balanceOf(address(eigenAgent));
        balanceOfReceiverBefore = tokenL1.balanceOf(address(receiverContract));
        console.log("balanceOf(receiverContract):", balanceOfReceiverBefore);
        console.log("balanceOf(eigenAgent):", balanceOfEigenAgent);

        /////////////////////////////////////
        //// Deposit with EigenAgent
        /////////////////////////////////////

        expiry = block.timestamp + 1 days;
        uint256 execNonce0 = 0; // no eigenAgent yet, execNonce is 0

        bytes memory depositMessage;
        bytes memory messageWithSignature_D;
        {
            depositMessage = EigenlayerMsgEncoders.encodeDepositIntoStrategyMsg(
                address(strategy),
                address(tokenL1),
                amount
            );

            // sign the message for EigenAgent to execute Eigenlayer command
            messageWithSignature_D = clientSigners.signMessageForEigenAgentExecution(
                bobKey,
                block.chainid, // destination chainid where EigenAgent lives
                address(strategyManager),
                depositMessage,
                execNonce0,
                expiry
            );
        }

        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](1);
        destTokenAmounts[0] = Client.EVMTokenAmount({
            token: address(tokenL1), // CCIP-BnM token address on Eth Sepolia.
            amount: amount
        });
        Client.Any2EVMMessage memory any2EvmMessage = Client.Any2EVMMessage({
            messageId: bytes32(0x0),
            sourceChainSelector: BaseSepolia.ChainSelector, // Arb Sepolia source chain selector
            sender: abi.encode(deployer), // bytes: abi.decode(sender) if coming from an EVM chain.
            destTokenAmounts: destTokenAmounts, // Tokens and their amounts in their destination chain representation.
            data: abi.encode(string(
                messageWithSignature_D
            )) // CCIP abi.encodes a string message when sending
        });

        vm.startBroadcast(deployerKey);

        vm.expectEmit(true, false, true, false); // don't check topic[2] EigenAgent address
        emit AgentFactory.AgentCreated(bob, vm.addr(1111), 1);
        receiverContract.mockCCIPReceive(any2EvmMessage);

        console.log("--------------- After Deposit -----------------");
        eigenAgent = agentFactory.getEigenAgent(bob);
        console.log("spawned eigenAgent: ", address(eigenAgent));

        vm.stopBroadcast();

        require(
            tokenL1.balanceOf(address(receiverContract)) == (balanceOfReceiverBefore - amount),
            "receiverContract did not send tokens to EigenAgent after depositing"
        );
        console.log("balanceOf(receiverContract) after deposit:", tokenL1.balanceOf(address(receiverContract)));
        console.log("balanceOf(eigenAgent) after deposit:", tokenL1.balanceOf(address(eigenAgent)));
        uint256 eigenAgentShares = strategyManager.stakerStrategyShares(address(eigenAgent), strategy);
        console.log("eigenAgent shares after deposit:", eigenAgentShares);
        require(eigenAgentShares > 0, "eigenAgent should have >0 shares after deposit");

        /////////////////////////////////////
        //// [L1] Queue Withdrawal with EigenAgent
        /////////////////////////////////////

        vm.selectFork(ethForkId);
        vm.startBroadcast(bobKey);

        IStrategy[] memory strategiesToWithdraw = new IStrategy[](1);
        uint256[] memory sharesToWithdraw = new uint256[](1);
        IDelegationManager.QueuedWithdrawalParams[] memory QWPArray;

        uint256 execNonce1 = eigenAgent.execNonce();

        bytes memory withdrawalMessage;
        bytes memory messageWithSignature_QW;
        {
            strategiesToWithdraw[0] = strategy;
            sharesToWithdraw[0] = amount;

            QWPArray = new IDelegationManager.QueuedWithdrawalParams[](1);
            QWPArray[0] = IDelegationManager.QueuedWithdrawalParams({
                strategies: strategiesToWithdraw,
                shares: sharesToWithdraw,
                withdrawer: address(eigenAgent)
            });

            // create the queueWithdrawal message for Eigenlayer
            withdrawalMessage = EigenlayerMsgEncoders.encodeQueueWithdrawalsMsg(
                QWPArray
            );

            // sign the message for EigenAgent to execute Eigenlayer command
            messageWithSignature_QW = clientSigners.signMessageForEigenAgentExecution(
                bobKey,
                EthSepolia.ChainId, // destination chainid where EigenAgent lives
                address(delegationManager),
                withdrawalMessage,
                execNonce1,
                expiry
            );
        }

        receiverContract.mockCCIPReceive(
            Client.Any2EVMMessage({
                messageId: bytes32(uint256(9999)),
                sourceChainSelector: BaseSepolia.ChainSelector, // Arb Sepolia source chain selector
                sender: abi.encode(address(deployer)), // bytes: abi.decode(sender) if coming from an EVM chain.
                destTokenAmounts: new Client.EVMTokenAmount[](0), // not bridging coins, just sending msg
                data: abi.encode(string(
                    messageWithSignature_QW
                ))
            })
        );
        console.log("--------------- After Queue Withdrawal -----------------");

        uint256 numWithdrawals = delegationManager.cumulativeWithdrawalsQueued(address(eigenAgent));
        require(numWithdrawals > 0, "must queueWithdrawals first before completeWithdrawals");

        console.log("balanceOf(receiver):", tokenL1.balanceOf(address(receiverContract)));
        console.log("balanceOf(eigenAgent):", tokenL1.balanceOf(address(eigenAgent)));

        uint256 eigenAgentSharesQW = strategyManager.stakerStrategyShares(address(eigenAgent), strategy);
        console.log("eigenAgent shares after queueWithdrawal:", eigenAgentSharesQW);
        require(eigenAgentSharesQW == 0, "eigenAgent should have 0 shares after queueWithdrawal");

        vm.stopBroadcast();
    }

    /*
     *
     *
     *             Tests
     *
     *
     */

    function test_CCIP_Eigenlayer_CompleteWithdrawal() public {

        uint256 amount = 0.003 ether;

        handler_DepositAndQueueWithdrawal(amount);

        /////////////////////////////////////////////////////////////////
        //// [L1] Complete Queued Withdrawals
        /////////////////////////////////////////////////////////////////

        vm.selectFork(ethForkId);
        vm.startBroadcast(bob);

        uint32 startBlock = uint32(block.number);
        uint256 execNonce2 = eigenAgent.execNonce();
        uint256 withdrawalNonce = delegationManager.cumulativeWithdrawalsQueued(bob);

        IStrategy[] memory strategiesToWithdraw = new IStrategy[](1);
        uint256[] memory sharesToWithdraw = new uint256[](1);
        strategiesToWithdraw[0] = strategy;
        sharesToWithdraw[0] = amount;

        IDelegationManager.Withdrawal memory withdrawal = IDelegationManager.Withdrawal({
            staker: address(eigenAgent),
            delegatedTo: delegationManager.delegatedTo(address(eigenAgent)),
            withdrawer: address(eigenAgent),
            nonce: withdrawalNonce,
            startBlock: startBlock,
            strategies: strategiesToWithdraw,
            shares: sharesToWithdraw
        });

        bytes32 withdrawalRoot = delegationManager.calculateWithdrawalRoot(withdrawal);
        require(withdrawalRoot != 0, "withdrawal root missing, queueWithdrawal first");

        vm.stopBroadcast();

        /////////////////////////////////////////////////////////////////
        //// 1. [L2] Send CompleteWithdrawals message to L2 Bridge
        /////////////////////////////////////////////////////////////////
        vm.selectFork(l2ForkId);
        vm.startBroadcast(bob);

        uint256 stakerBalanceOnL2Before = IERC20(BaseSepolia.BridgeToken).balanceOf(bob);

        bytes memory completeWithdrawalMessage;
        bytes memory messageWithSignature_CW;
        {
            // create the completeWithdrawal message for Eigenlayer
            IERC20[] memory tokensToWithdraw = new IERC20[](1);
            tokensToWithdraw[0] = tokenL1;

            completeWithdrawalMessage = EigenlayerMsgEncoders.encodeCompleteWithdrawalMsg(
                withdrawal,
                tokensToWithdraw,
                0, //middlewareTimesIndex,
                true // receiveAsTokens
            );

            // sign the message for EigenAgent to execute Eigenlayer command
            messageWithSignature_CW = clientSigners.signMessageForEigenAgentExecution(
                bobKey,
                EthSepolia.ChainId, // destination chainid where EigenAgent lives
                address(delegationManager),
                completeWithdrawalMessage,
                execNonce2,
                expiry
            );
        }

        bytes32 withdrawalAgentOwnerRoot = EigenlayerMsgEncoders.calculateWithdrawalAgentOwnerRoot(
            withdrawalRoot,
            bob
        );
        vm.expectEmit(true, false, true, false);
        emit WithdrawalAgentOwnerRootCommitted(
            withdrawalAgentOwnerRoot,
            address(eigenAgent), // withdrawer
            amount,
            bob // signer
        );
        senderContract.sendMessagePayNative(
            EthSepolia.ChainSelector, // destination chain
            address(receiverContract),
            string(messageWithSignature_CW),
            address(BaseSepolia.BridgeToken), // destination token
            0, // not sending tokens, just message
            0 // use default gasLimit for this function
        );

        vm.stopBroadcast();

        /////////////////////////////////////////////////////////////////
        //// [Offchain] CCIP relays tokens and message to L1 bridge
        /////////////////////////////////////////////////////////////////

        /////////////////////////////////////////////////////////////////
        //// 2. [L1] Mock receiving CompleteWithdrawals message on L1 Bridge
        /////////////////////////////////////////////////////////////////

        // fork ethsepolia so ReceiverCCIP -> Router calls work
        vm.selectFork(ethForkId);
        vm.startBroadcast(address(receiverContract));

        vm.warp(block.timestamp + 120); // 120 seconds = 10 blocks (12second per block)
        vm.roll((block.timestamp + 120) / 12);


        // sender contract is forked from testnet, addr will differ
        vm.expectEmit(false, true, true, false);
        emit ReceiverCCIP.BridgingWithdrawalToL2(
            address(senderContract),
            withdrawalAgentOwnerRoot,
            amount
        );
        // Mock L1 bridge receiving CCIP message and calling CompleteWithdrawal on Eigenlayer
        receiverContract.mockCCIPReceive(
            Client.Any2EVMMessage({
                messageId: bytes32(uint256(9999)),
                sourceChainSelector: EthSepolia.ChainSelector,
                sender: abi.encode(deployer),
                data: abi.encode(string(
                    messageWithSignature_CW
                )),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
        console.log("--------------- After Complete Withdrawal -----------------");

        // tokens in the ReceiverCCIP bridge contract
        console.log("balanceOf(receiverContract) after:", tokenL1.balanceOf(address(receiverContract)));
        console.log("balanceOf(eigenAgent) after:", tokenL1.balanceOf(address(eigenAgent)));
        console.log("balanceOf(restakingConnector) after:", tokenL1.balanceOf(address(restakingConnector)));
        console.log("balanceOf(router) after:", tokenL1.balanceOf(address(EthSepolia.Router)));
        require(
            tokenL1.balanceOf(address(receiverContract)) == (balanceOfReceiverBefore - amount),
            "receiverContract did not send tokens to L1 completeWithdrawal"
        );
        require(
            tokenL1.balanceOf(address(eigenAgent)) == 0,
            "EigenAgent did not send tokens to ReceiverCCIP after completeWithdrawal"
        );
        vm.stopBroadcast();

        /////////////////////////////////////////////////////////////////
        //// [Offchain] CCIP relays tokens and message to L2 bridge
        /////////////////////////////////////////////////////////////////

        /////////////////////////////////////////////////////////////////
        //// 3. [L2] Mock receiving CompleteWithdrawals message from L1
        /////////////////////////////////////////////////////////////////
        vm.selectFork(l2ForkId);
        vm.startBroadcast(bobKey);

        // Mock SenderContract on L2 receiving the tokens and TransferToAgentOwner CCIP message from L1
        senderContract.mockCCIPReceive(
            Client.Any2EVMMessage({
                messageId: bytes32(uint256(9999)),
                sourceChainSelector: EthSepolia.ChainSelector,
                sender: abi.encode(address(receiverContract)),
                data: abi.encode(string(
                    EigenlayerMsgEncoders.encodeHandleTransferToAgentOwnerMsg(
                        withdrawalAgentOwnerRoot
                        // EigenlayerMsgEncoders.calculateWithdrawalAgentOwnerRoot(
                        //     withdrawalRoot,
                        //     bob
                        // )
                    )
                )), // CCIP abi.encodes a string message when sending
                destTokenAmounts: new Client.EVMTokenAmount[](0)
                // Not bridging tokens, just sending message to withdraw
            })
        );

        uint256 stakerBalanceOnL2After = IERC20(BaseSepolia.BridgeToken).balanceOf(address(bob));
        console.log("--------------- L2 After Bridge back -----------------");
        console.log("balanceOf(bob) on L2 before:", stakerBalanceOnL2Before);
        console.log("balanceOf(bob) on L2 after:", stakerBalanceOnL2After);

        require(
            (stakerBalanceOnL2Before + amount) == stakerBalanceOnL2After,
            "balanceOf(bob) on L2 should increase by amount after L2 -> L2 withdrawal"
        );

        /////////////////////////////////////////////////////////////////
        //// Test Attempts to re-use WithdrawalAgentOwnerRoots
        /////////////////////////////////////////////////////////////////

        // attempting to commit a spent withdrawalAgentOwnerRoot should fail on L2
        vm.expectRevert("SenderHooks._commitWithdrawalAgentOwnerRootInfo: withdrawalAgentOwnerRoot already used");
        senderContract.sendMessagePayNative(
            EthSepolia.ChainSelector, // destination chain
            address(receiverContract),
            string(messageWithSignature_CW),
            address(BaseSepolia.BridgeToken), // destination token
            0, // not sending tokens, just message
            0 // use default gasLimit for this function
        );

        // attempting to re-use withdrawalAgentOwnerRoot from L1 should fail
        bytes memory messageWithdrawalReuse = EigenlayerMsgEncoders.encodeHandleTransferToAgentOwnerMsg(
            EigenlayerMsgEncoders.calculateWithdrawalAgentOwnerRoot(
                withdrawalRoot,
                bob
            )
        );
        vm.expectRevert("SenderHooks.handleTransferToAgentOwner: withdrawalAgentOwnerRoot already used");
        senderContract.mockCCIPReceive(
            Client.Any2EVMMessage({
                messageId: bytes32(uint256(9999)),
                sourceChainSelector: EthSepolia.ChainSelector,
                sender: abi.encode(address(receiverContract)),
                data: abi.encode(string(
                    messageWithdrawalReuse
                )),
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );

        // withdrawalAgentOwnerRoot should be spent now
        vm.assertEq(senderHooks.isWithdrawalAgentOwnerRootSpent(withdrawalAgentOwnerRoot), true);

        vm.stopBroadcast();
    }

}