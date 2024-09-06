// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20_CCIPBnM} from "../src/interfaces/IERC20_CCIPBnM.sol";
import {IERC20Minter} from "../src/interfaces/IERC20Minter.sol";

import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";

import {IReceiverCCIPMock} from "./mocks/ReceiverCCIPMock.sol";
import {ISenderCCIPMock} from "./mocks/SenderCCIPMock.sol";
import {IRestakingConnector} from "../src/interfaces/IRestakingConnector.sol";
import {ISenderHooks} from "../src/interfaces/ISenderHooks.sol";

import {DeployMockEigenlayerContractsScript} from "../script/1_deployMockEigenlayerContracts.s.sol";
import {DeployReceiverOnL1Script} from "../script/3_deployReceiverOnL1.s.sol";
import {DeploySenderOnL2Script} from "../script/2_deploySenderOnL2.s.sol";
import {ClientSigners} from "../script/ClientSigners.sol";
import {ClientEncoders} from "../script/ClientEncoders.sol";
import {EthSepolia, BaseSepolia} from "../script/Addresses.sol";

import {EigenAgentOwner721} from "../src/6551/EigenAgentOwner721.sol";
import {IEigenAgent6551} from "../src/6551/IEigenAgent6551.sol";
import {IAgentFactory} from "../src/6551/IAgentFactory.sol";
import {AgentFactory} from "../src/6551/AgentFactory.sol";



contract BaseTestEnvironment is Test, ClientSigners, ClientEncoders {

    DeployReceiverOnL1Script public deployReceiverOnL1Script;
    DeploySenderOnL2Script public deploySenderOnL2Script;
    DeployMockEigenlayerContractsScript public deployMockEigenlayerContractsScript;

    ISenderCCIPMock public senderContract;
    ISenderHooks public senderHooks;
    IReceiverCCIPMock public receiverContract;
    IRestakingConnector public restakingConnector;

    IStrategyManager public strategyManager;
    IDelegationManager public delegationManager;
    IStrategy public strategy;
    IERC20 public tokenL1;

    IAgentFactory public agentFactory;
    EigenAgentOwner721 public eigenAgentOwnerNft;
    IEigenAgent6551 public eigenAgent;

    uint256 public deployerKey;
    address public deployer;
    uint256 public bobKey;
    address public bob;
    uint256 public aliceKey;
    address public alice;

    uint256 public l2ForkId;
    uint256 public ethForkId;

    function setUpForkedEnvironment() internal {

		deployerKey = vm.envUint("DEPLOYER_KEY");
        deployer = vm.addr(deployerKey);
        vm.deal(deployer, 1 ether);

        bobKey = uint256(11156789111);
        bob = vm.addr(bobKey);
        vm.deal(bob, 1 ether);

        aliceKey = uint256(22298765222);
        alice = vm.addr(aliceKey);
        vm.deal(alice, 1 ether);

        l2ForkId = vm.createFork("basesepolia"); // 0
        ethForkId = vm.createFork("ethsepolia"); // 1

        // setup L1 forked environment
        _setupL1ForkedEnvironment();

        // setup L2 forked environment
        _setupL2ForkedEnvironment();
    }

    function _setupL1ForkedEnvironment() private {
        /////////////////////////////////////////////
        //// Setup L1 CCIP and Eigenlayer contracts
        /////////////////////////////////////////////
        vm.selectFork(ethForkId);

        deployReceiverOnL1Script = new DeployReceiverOnL1Script();
        deployMockEigenlayerContractsScript = new DeployMockEigenlayerContractsScript();

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
    }

    function _setupL2ForkedEnvironment() private {
        /////////////////////////////////////////
        //// Setup L2 CCIP contracts
        /////////////////////////////////////////
        vm.selectFork(l2ForkId);

        deploySenderOnL2Script = new DeploySenderOnL2Script();

        (
            senderContract,
            senderHooks
        ) = deploySenderOnL2Script.mockrun();

        vm.deal(address(senderContract), 1 ether);

        vm.startBroadcast(deployerKey);
        {
            // allow L2 sender contract to receive tokens back from L1
            senderContract.allowlistSourceChain(EthSepolia.ChainSelector, true);
            senderContract.allowlistSender(address(receiverContract), true);
            senderContract.allowlistSender(deployer, true);
            // fund L2 sender with CCIP-BnM tokens
            IERC20_CCIPBnM(BaseSepolia.BridgeToken).drip(address(senderContract));
        }
        vm.stopBroadcast();
    }

    function setUpLocalEnvironment() internal {

		deployerKey = vm.envUint("DEPLOYER_KEY");
        deployer = vm.addr(deployerKey);
        vm.deal(deployer, 1 ether);

        bobKey = uint256(56789111);
        bob = vm.addr(bobKey);
        vm.deal(bob, 1 ether);

        aliceKey = uint256(98765222);
        alice = vm.addr(aliceKey);
        vm.deal(alice, 1 ether);

        deploySenderOnL2Script = new DeploySenderOnL2Script();
        deployReceiverOnL1Script = new DeployReceiverOnL1Script();
        deployMockEigenlayerContractsScript = new DeployMockEigenlayerContractsScript();

        //////////////////////////////////////////////////////
        //// Setup L1 CCIP and Eigenlayer contracts locally
        //////////////////////////////////////////////////////

        //// Eigenlayer Contracts
        (
            strategy,
            strategyManager,
            , // IStrategyFactory
            , // pauserRegistry
            delegationManager,
            , // rewardsCoordinator
            tokenL1
        ) = deployMockEigenlayerContractsScript.deployEigenlayerContracts(false);

        //// L1 CCIP contracts and 6551 EigenAgent contracts
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

            IERC20Minter(address(tokenL1)).mint(address(receiverContract), 1 ether);
            IERC20Minter(address(tokenL1)).mint(bob, 1 ether);
        }
        vm.stopBroadcast();

        /////////////////////////////////////////
        //// Setup L2 CCIP contracts
        /////////////////////////////////////////
        (
            senderContract,
            senderHooks
        ) = deploySenderOnL2Script.mockrun();

        vm.deal(address(senderContract), 1 ether);

        vm.startBroadcast(deployerKey);
        {
            // allow L2 sender contract to receive tokens back from L1
            senderContract.allowlistSourceChain(EthSepolia.ChainSelector, true);
            senderContract.allowlistSender(address(receiverContract), true);
            senderContract.allowlistSender(deployer, true);
        }
        vm.stopBroadcast();
    }

}