// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";

import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IReceiverCCIP} from "../src/interfaces/IReceiverCCIP.sol";
import {ISenderCCIP} from "../src/interfaces/ISenderCCIP.sol";
import {ISenderHooks} from "../src/interfaces/ISenderHooks.sol";
import {IRestakingConnector} from "../src/interfaces/IRestakingConnector.sol";
import {IAgentFactory} from "../src/6551/IAgentFactory.sol";
import {IEigenAgent6551} from "../src/6551/IEigenAgent6551.sol";

import {BaseSepolia, EthSepolia} from "./Addresses.sol";
import {FileReader} from "./FileReader.sol";
import {ScriptUtils} from "./ScriptUtils.sol";
import {DeployMockEigenlayerContractsScript} from "./1_deployMockEigenlayerContracts.s.sol";

import {ClientSigners} from "./ClientSigners.sol";
import {ClientEncoders} from "./ClientEncoders.sol";


contract CompleteWithdrawalScript is
    Script,
    ScriptUtils,
    FileReader,
    ClientEncoders,
    ClientSigners
{

    DeployMockEigenlayerContractsScript public deployMockEigenlayerContractsScript;

    IReceiverCCIP public receiverProxy;
    ISenderCCIP public senderProxy;
    ISenderHooks public SenderHooksProxy;
    IRestakingConnector public restakingConnector;
    IAgentFactory public agentFactory;

    IStrategyManager public strategyManager;
    IDelegationManager public delegationManager;
    IStrategy public strategy;
    IERC20 public tokenL2;

    uint256 public deployerKey;
    address public deployer;
    address public staker;
    address public withdrawer;
    uint256 public expiry;
    uint256 public middlewareTimesIndex; // not used yet, for slashing
    bool public receiveAsTokens;

    address public TARGET_CONTRACT; // Contract that EigenAgent forwards calls to
    uint256 public execNonce; // EigenAgent execution nonce
    IEigenAgent6551 public eigenAgent;

    function run() public {
        return _run(false);
    }

    function mockrun() public {
        return _run(true);
    }

    function _run(bool isTest) private {

        deployerKey = vm.envUint("DEPLOYER_KEY");
        deployer = vm.addr(deployerKey);

        uint256 l2ForkId = vm.createFork("basesepolia");
        uint256 ethForkId = vm.createSelectFork("ethsepolia");

        deployMockEigenlayerContractsScript = new DeployMockEigenlayerContractsScript();

        (
            strategy,
            strategyManager,
            , // strategyFactory
            , // pauserRegistry
            delegationManager,
            , // _rewardsCoordinator
            // tokenL1
        ) = deployMockEigenlayerContractsScript.readSavedEigenlayerAddresses();

        senderProxy = readSenderContract();
        SenderHooksProxy = readSenderHooks();

        (receiverProxy, restakingConnector) = readReceiverRestakingConnector();
        agentFactory = readAgentFactory();

        tokenL2 = IERC20(address(BaseSepolia.BridgeToken)); // BaseSepolia contract
        TARGET_CONTRACT = address(delegationManager);

        /////////////////////////////////////////////////////////////////
        ////// L1: Get Complete Withdrawals Params
        /////////////////////////////////////////////////////////////////
        vm.selectFork(ethForkId);

        // Get EigenAgent
        eigenAgent = agentFactory.getEigenAgent(deployer);
        if (address(eigenAgent) != address(0)) {
            // if the user already has a EigenAgent, fetch current execution Nonce
            execNonce = eigenAgent.execNonce();
        }
        require(address(eigenAgent) != address(0), "user has no EigenAgent");

        expiry = block.timestamp + 2 hours;
        staker = address(eigenAgent); // this should be EigenAgent (as in StrategyManager)
        withdrawer = address(eigenAgent);
        // staker == withdrawer == msg.sender in StrategyManager, which is EigenAgent
        require(
            (staker == withdrawer) && (address(eigenAgent) == withdrawer),
            "staker == withdrawer == eigenAgent not satisfied"
        );

        IDelegationManager.Withdrawal memory withdrawal = readWithdrawalInfo(
            staker,
            "script/withdrawals-queued/"
        );

        if (isTest) {
            // mock save a queueWithdrawalBlock
            vm.prank(deployer);
            restakingConnector.setQueueWithdrawalBlock(
                withdrawal.staker,
                withdrawal.nonce,
                111
            );
        }

        // Fetch the correct withdrawal.startBlock and withdrawalRoot
        withdrawal.startBlock = uint32(restakingConnector.getQueueWithdrawalBlock(
            withdrawal.staker,
            withdrawal.nonce
        ));

        bytes32 withdrawalRoot = calculateWithdrawalRoot(withdrawal);
        // Create a withdrawalAgentOwnerRoot and commit to it on L2.
        // So that when the withdrawal returns, we can
        // verify which user (AgentOwner) to transfer withdrawals to
        bytes32 withdrawalAgentOwnerRoot = calculateWithdrawalTransferRoot(
            withdrawalRoot,
            withdrawal.shares[0],
            deployer
        );

        IERC20[] memory tokensToWithdraw = new IERC20[](1);
        tokensToWithdraw[0] = withdrawal.strategies[0].underlyingToken();

        /////////////////////////////////////////////////////////////////
        /////// Broadcast to L2
        /////////////////////////////////////////////////////////////////

        vm.selectFork(l2ForkId);

        vm.startBroadcast(deployerKey);

        require(
            senderProxy.allowlistedSenders(address(receiverProxy)),
            "senderCCIP: must allowlistSender(receiverCCIP)"
        );

        middlewareTimesIndex = 0; // not used yet, for slashing
        receiveAsTokens = true;

        bytes memory completeWithdrawalMessage;
        bytes memory messageWithSignature;
        {
            completeWithdrawalMessage = encodeCompleteWithdrawalMsg(
                withdrawal,
                tokensToWithdraw,
                middlewareTimesIndex,
                receiveAsTokens
            );

            // sign the message for EigenAgent to execute Eigenlayer command
            messageWithSignature = signMessageForEigenAgentExecution(
                deployerKey,
                EthSepolia.ChainId, // destination chainid where EigenAgent lives
                TARGET_CONTRACT,
                completeWithdrawalMessage,
                execNonce,
                expiry
            );
        }

        topupSenderEthBalance(address(senderProxy), isTest);

        senderProxy.sendMessagePayNative(
            EthSepolia.ChainSelector, // destination chain
            address(receiverProxy),
            string(messageWithSignature),
            address(tokenL2),
            0, // only sending message, not bridging tokens
            0 // use default gasLimit for this function
        );

        vm.stopBroadcast();


        vm.selectFork(ethForkId);
        string memory filePath = "script/withdrawals-completed/";
        if (isTest) {
           filePath = "test/withdrawals-completed/";
        }

        saveWithdrawalInfo(
            withdrawal.staker,
            withdrawal.delegatedTo,
            withdrawal.withdrawer,
            withdrawal.nonce,
            withdrawal.startBlock,
            withdrawal.strategies,
            withdrawal.shares,
            withdrawalRoot,
            withdrawalAgentOwnerRoot,
            filePath
        );

    }

}
