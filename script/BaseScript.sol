// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
// CCIP interfaces
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// Eigenlayer interfaecs
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
// interfaces
import {ISenderCCIP} from "../src/interfaces/ISenderCCIP.sol";
import {ISenderHooks} from "../src/interfaces/ISenderHooks.sol";
import {IReceiverCCIP} from "../src/interfaces/IReceiverCCIP.sol";
import {IRestakingConnector} from "../src/interfaces/IRestakingConnector.sol";
import {IAgentFactory} from "../src/6551/IAgentFactory.sol";
import {IEigenAgent6551} from "../src/6551/IEigenAgent6551.sol";
// Script utils
import {DeployMockEigenlayerContractsScript} from "./1_deployMockEigenlayerContracts.s.sol";
import {DeployReceiverOnL1Script} from "../script/3_deployReceiverOnL1.s.sol";
import {DeploySenderOnL2Script} from "../script/2_deploySenderOnL2.s.sol";
import {EthSepolia, BaseSepolia} from "./Addresses.sol";
import {FileReader} from "./FileReader.sol";
import {ClientEncoders} from "./ClientEncoders.sol";
import {ClientSigners} from "./ClientSigners.sol";
import {RouterFees} from "./RouterFees.sol";



contract BaseScript is
    Script,
    FileReader,
    RouterFees,
    ClientEncoders,
    ClientSigners
{

    DeployMockEigenlayerContractsScript public deployMockEigenlayerContractsScript;
    DeployReceiverOnL1Script public deployReceiverOnL1Script;
    DeploySenderOnL2Script public deploySenderOnL2Script;

    IReceiverCCIP public receiverContract;
    ISenderCCIP public senderContract;
    ISenderHooks public senderHooks;
    IRestakingConnector public restakingConnector;
    IRouterClient public routerL2;

    IAgentFactory public agentFactory;

    IStrategyManager public strategyManager;
    IDelegationManager public delegationManager;
    IStrategy public strategy;

    IERC20 public tokenL1;
    IERC20 public tokenL2;

    uint256 public deployerKey;
    address public deployer;

    uint256 public l2ForkId;
    uint256 public ethForkId;

    function readContractsFromDisk() public {

        deployerKey = vm.envUint("DEPLOYER_KEY");
        deployer = vm.addr(deployerKey);

        ethForkId = vm.createFork("ethsepolia");
        l2ForkId = vm.createFork("basesepolia");

        ///////////////////////////////////////
        // L1 contracts
        ///////////////////////////////////////
        vm.selectFork(ethForkId);

        deployMockEigenlayerContractsScript = new DeployMockEigenlayerContractsScript();
        deployReceiverOnL1Script = new DeployReceiverOnL1Script();

        (
            strategy,
            strategyManager,
            , // strategyFactory
            , // pauserRegistry
            delegationManager,
            , // _rewardsCoordinator
            // tokenL1
        ) = deployMockEigenlayerContractsScript.readSavedEigenlayerAddresses();

        (
            receiverContract,
            restakingConnector
        ) = readReceiverRestakingConnector();

        agentFactory = readAgentFactory();
        tokenL1 = IERC20(address(EthSepolia.BridgeToken)); // CCIP-BnM on L1

        vm.deal(deployer, 1 ether); // fund L1 balance
        ///////////////////////////////////////
        // L2 contracts
        ///////////////////////////////////////
        vm.selectFork(l2ForkId);

        senderContract = readSenderContract();
        senderHooks = readSenderHooks();
        routerL2 = IRouterClient(BaseSepolia.Router);
        tokenL2 = IERC20(address(BaseSepolia.BridgeToken)); // CCIP-BnM on L2

        vm.deal(deployer, 1 ether); // fund L2 balance
    }

    function getEigenAgentAndExecNonce(address user) public view returns (IEigenAgent6551, uint256) {

        uint256 execNonce = 0;
        IEigenAgent6551 eigenAgent = agentFactory.getEigenAgent(user);
        if (address(eigenAgent) != address(0)) {
            // if the user already has a EigenAgent, fetch current execution Nonce
            execNonce = eigenAgent.execNonce();
        }

        return (eigenAgent, execNonce);
    }

    function topupEthBalance(address _account) public {

        uint256 amountToTopup = 0.20 ether;

        if (_account.balance < 0.05 ether) {
            (bool sent, ) = payable(address(_account)).call{value: amountToTopup}("");
            require(sent, "Failed to send Ether");
        }
    }

    // tells forge coverage to ignore
    function test_ignore() private {}
}