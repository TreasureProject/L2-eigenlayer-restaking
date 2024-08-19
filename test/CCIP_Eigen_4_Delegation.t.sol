// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test, console} from "forge-std/Test.sol";

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20_CCIPBnM} from "../src/interfaces/IERC20_CCIPBnM.sol";

import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IPauserRegistry} from "eigenlayer-contracts/src/contracts/interfaces/IPauserRegistry.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";

import {IERC20Minter} from "../src/interfaces/IERC20Minter.sol";
import {ReceiverCCIP} from "../src/ReceiverCCIP.sol";
import {IReceiverCCIP} from "../src/interfaces/IReceiverCCIP.sol";
import {RestakingConnector} from "../src/RestakingConnector.sol";
import {IRestakingConnector, EigenlayerDepositWithSignatureParams} from "../src/interfaces/IRestakingConnector.sol";
import {ISenderCCIP} from "../src/interfaces/ISenderCCIP.sol";

import {DeployMockEigenlayerContractsScript} from "../script/1_deployMockEigenlayerContracts.s.sol";
import {DeployOnEthScript} from "../script/3_deployOnEth.s.sol";
import {DeployOnArbScript} from "../script/2_deployOnArb.s.sol";

import {SignatureUtilsEIP1271} from "../src/utils/SignatureUtilsEIP1271.sol";
import {EigenlayerMsgEncoders} from "../src/utils/EigenlayerMsgEncoders.sol";
import {EthSepolia, ArbSepolia} from "../script/Addresses.sol";


contract CCIP_Eigen_DelegationTests is Test {

    DeployOnEthScript public deployOnEthScript;
    DeployOnArbScript public deployOnArbScript;
    DeployMockEigenlayerContractsScript public deployMockEigenlayerContractsScript;
    SignatureUtilsEIP1271 public signatureUtils;
    EigenlayerMsgEncoders public eigenlayerMsgEncoders;

    uint256 public deployerKey;
    address public deployer;

    IReceiverCCIP public receiverContract;
    ISenderCCIP public senderContract;
    IRestakingConnector public restakingConnector;
    IERC20 public token;

    IStrategyManager public strategyManager;
    IPauserRegistry public _pauserRegistry;
    IRewardsCoordinator public _rewardsCoordinator;
    IDelegationManager public delegationManager;
    IStrategy public strategy;

    uint256 public stakerShares;
    uint256 public initialReceiverBalance = 5 ether;
    uint256 public amountToStake = 0.0091 ether;
    address public staker;

    uint256 arbForkId;
    uint256 ethForkId;

    function setUp() public {

		deployerKey = vm.envUint("DEPLOYER_KEY");
        deployer = vm.addr(deployerKey);

        deployOnEthScript = new DeployOnEthScript();
        deployOnArbScript = new DeployOnArbScript();
        deployMockEigenlayerContractsScript = new DeployMockEigenlayerContractsScript();
        eigenlayerMsgEncoders = new EigenlayerMsgEncoders();
        signatureUtils = new SignatureUtilsEIP1271();

        // uint256 arbForkId = vm.createSelectFork("arbsepolia");
        // vm.rollFork(71584765); // roll back before CCIP network entered "cursed" state
        arbForkId = vm.createFork("arbsepolia");        // 0
        ethForkId = vm.createSelectFork("ethsepolia"); // 1
        console.log("arbForkId:", arbForkId);
        console.log("ethForkId:", ethForkId);

        //// Configure Eigenlayer contracts
        (
            strategy,
            strategyManager,
            , //IStrategyFactory
            _pauserRegistry,
            delegationManager,
            _rewardsCoordinator,
            token
        ) = deployMockEigenlayerContractsScript.deployEigenlayerContracts(false);

        staker = deployer;

        //////////// Arb Sepolia ////////////
        vm.selectFork(arbForkId);
        senderContract = deployOnArbScript.run();
        /////////////////////////////////////


        //////////// Eth Sepolia ////////////
        vm.selectFork(ethForkId);
        (receiverContract, restakingConnector) = deployOnEthScript.run();
        /////////////////////////////////////


        //////////// Arb Sepolia ////////////
        vm.selectFork(arbForkId);
        vm.startBroadcast(deployerKey);
        // allow L2 sender contract to receive tokens back from L1
        senderContract.allowlistSourceChain(EthSepolia.ChainSelector, true);
        senderContract.allowlistSender(address(receiverContract), true);
        senderContract.allowlistSender(deployer, true);
        // fund L2 sender with gas and CCIP-BnM tokens
        vm.deal(address(senderContract), 1.333 ether); // fund for gas
        if (block.chainid == 421614) {
            // drip() using CCIP's BnM faucet if forking from Arb Sepolia
            for (uint256 i = 0; i < 5; ++i) {
                IERC20_CCIPBnM(ArbSepolia.CcipBnM).drip(address(senderContract));
                // each drip() gives you 1e18 coin
            }
        } else {
            // mint() if we deployed our own Mock ERC20
            IERC20Minter(ArbSepolia.CcipBnM).mint(address(senderContract), 5 ether);
        }
        vm.stopBroadcast();
        /////////////////////////////////////


        //////////// Eth Sepolia ////////////
        vm.selectFork(ethForkId);
        vm.startBroadcast(deployerKey);
        receiverContract.allowlistSender(deployer, true);
        restakingConnector.setEigenlayerContracts(delegationManager, strategyManager, strategy);
        console.log("block.chainid", block.chainid);

        // fund L1 receiver with gas and CCIP-BnM tokens
        vm.deal(address(receiverContract), 1.111 ether); // fund for gas
        if (block.chainid == 11155111) {
            // drip() using CCIP's BnM faucet if forking from Eth Sepolia
            for (uint256 i = 0; i < 5; ++i) {
                IERC20_CCIPBnM(address(token)).drip(address(receiverContract));
                // each drip() gives you 1e18 coin
            }
            initialReceiverBalance = IERC20_CCIPBnM(address(token)).balanceOf(address(receiverContract));
            // set initialReceiverBalancer for tests
        } else {
            // mint() if we deployed our own Mock ERC20
            IERC20Minter(address(token)).mint(address(receiverContract), initialReceiverBalance);
        }

        vm.stopBroadcast();
        /////////////////////////////////////

        /////////////////////////////////////
        //// ETH: Mock deposits on Eigenlayer
        vm.selectFork(ethForkId);
        /////////////////////////////////////
        vm.startBroadcast(address(receiverContract)); // simulate router sending receiver message on L1
        Client.Any2EVMMessage memory any2EvmMessage = makeCCIPEigenlayerMsg_DepositWithSignature(
            amountToStake,
            staker,
            block.timestamp + 1 hours
        );
        receiverContract.mockCCIPReceive(any2EvmMessage);

        stakerShares = strategyManager.stakerStrategyShares(staker, strategy);
        uint256 receiverShares = strategyManager.stakerStrategyShares(address(receiverContract), strategy);

        require(stakerShares == amountToStake, "stakerStrategyShares incorrect");
        require(receiverShares == 0, "receiverContract should not hold any shares");

        vm.stopBroadcast();

        IStrategy[] memory strategiesToWithdraw = new IStrategy[](1);
        strategiesToWithdraw[0] = strategy;

        uint256[] memory sharesToWithdraw = new uint256[](1);
        sharesToWithdraw[0] = stakerShares;
    }


    function test_Eigenlayer_DelegateTo() public {
        // function delegateToBySignature(
        //     address staker,
        //     address operator,
        //     SignatureWithExpiry memory stakerSignatureAndExpiry,
        //     SignatureWithExpiry memory approverSignatureAndExpiry,
        //     bytes32 approverSalt
        // )
    }

    function test_Eigenlayer_Undelegate() public {
        // DelegationManager.undelegate
    }


    function makeCCIPEigenlayerMsg_DepositWithSignature(
        uint256 _amount,
        address _staker,
        uint256 expiry
    ) public view returns (Client.Any2EVMMessage memory) {

        uint256 nonce = 0; // in production retrieve on StrategyManager on L1
        bytes32 domainSeparator = signatureUtils.getDomainSeparator(address(strategyManager), block.chainid);

        (
            bytes memory signature,
            bytes32 digestHash
        ) = signatureUtils.createEigenlayerDepositSignature(
            deployerKey,
            strategy,
            token,
            _amount,
            _staker,
            nonce,
            expiry,
            domainSeparator
        );

        signatureUtils.checkSignature_EIP1271(_staker, digestHash, signature);

        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](1);
        destTokenAmounts[0] = Client.EVMTokenAmount({
            token: address(token),
            amount: _amount
        });

        Client.Any2EVMMessage memory any2EvmMessage = Client.Any2EVMMessage({
            messageId: bytes32(0xffffffffffffffff9999999999999999eeeeeeeeeeeeeeee8888888888888888),
            sourceChainSelector: ArbSepolia.ChainSelector, // Arb Sepolia source chain selector
            sender: abi.encode(deployer), // bytes: abi.decode(sender) if coming from an EVM chain.
            data: abi.encode(string(
                eigenlayerMsgEncoders.encodeDepositIntoStrategyWithSignatureMsg(
                    address(strategy),
                    address(token),
                    _amount,
                    _staker,
                    expiry,
                    signature
                )
            )), // CCIP abi.encodes a string message when sending
            destTokenAmounts: destTokenAmounts // Tokens and their amounts in their destination chain representation.
        });

        return any2EvmMessage;
    }

}