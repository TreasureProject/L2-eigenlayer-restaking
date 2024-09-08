// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {ISignatureUtils} from "eigenlayer-contracts/src/contracts/interfaces/ISignatureUtils.sol";

import {EigenlayerMsgDecoders, DelegationDecoders} from "./utils/EigenlayerMsgDecoders.sol";
import {EigenlayerMsgEncoders} from "./utils/EigenlayerMsgEncoders.sol";
import {Adminable} from "./utils/Adminable.sol";

import {IRestakingConnector} from "./interfaces/IRestakingConnector.sol";
import {IEigenAgent6551} from "../src/6551/IEigenAgent6551.sol";
import {IAgentFactory} from "../src/6551/IAgentFactory.sol";



contract RestakingConnector is
    Initializable,
    IRestakingConnector,
    EigenlayerMsgDecoders,
    Adminable
{

    IDelegationManager public delegationManager;
    IStrategyManager public strategyManager;
    IStrategy public strategy;

    address private _receiverCCIP;
    IAgentFactory public agentFactory;

    error AddressZero(string msg);

    event SetQueueWithdrawalBlock(address indexed, uint256 indexed, uint256 indexed);
    event SetGasLimitForFunctionSelector(bytes4 indexed, uint256 indexed);

    mapping(address user => mapping(uint256 nonce => uint256 withdrawalBlock)) private _withdrawalBlock;
    mapping(bytes4 => uint256) internal _gasLimitsForFunctionSelectors;

    /*
     *
     *                 Functions
     *
     *
     */

    constructor() {
        _disableInitializers();
    }

    function initialize(IAgentFactory newAgentFactory) initializer public {

        if (address(newAgentFactory) == address(0))
            revert AddressZero("AgentFactory cannot be address(0)");

        agentFactory = newAgentFactory;

        // cast sig "handleTransferToAgentOwner(bytes)" == 0xd8a85b48
        // [gas: 268_420]
        _gasLimitsForFunctionSelectors[0xd8a85b48] = 290_000;

        __Adminable_init();
    }

    modifier onlyReceiverCCIP() {
        require(msg.sender == _receiverCCIP, "not called by ReceiverCCIP");
        _;
    }

    function getReceiverCCIP() public view returns (address) {
        return _receiverCCIP;
    }

    function setReceiverCCIP(address newReceiverCCIP) public onlyOwner {
        _receiverCCIP = newReceiverCCIP;
    }

    function getAgentFactory() public view returns (address) {
        return address(agentFactory);
    }

    function setAgentFactory(address newAgentFactory) public onlyOwner {
        if (newAgentFactory == address(0))
            revert AddressZero("AgentFactory cannot be address(0)");

        agentFactory = IAgentFactory(newAgentFactory);
    }

    /*
     *
     *                EigenAgent <> Eigenlayer Handlers
     *
     *
    */

    // Mints an EigenAgent before depositing if a user does not already have one.
    // If the user already has an EigenAgent this call will continue depositing
    // It will not mint a new EigenAgent if a user already has one. Users can only own one.
    function depositWithEigenAgent(bytes memory messageWithSignature) public onlyReceiverCCIP {

        (
            // original message
            address _strategy,
            address token,
            uint256 amount,
            // message signature
            address signer, // original_staker
            uint256 expiry,
            bytes memory signature // signature from original_staker
        ) = decodeDepositIntoStrategyMsg(messageWithSignature);

        // Get original_staker's EigenAgent, or spawn one.
        try agentFactory.tryGetEigenAgentOrSpawn(signer) returns (IEigenAgent6551 eigenAgent) {

            // Token flow: ReceiverCCIP approves RestakingConnector to move tokens to EigenAgent,
            // then EigenAgent approves StrategyManager to move tokens into Eigenlayer
            try eigenAgent.approveByWhitelistedContract(
                address(strategyManager),
                token,
                amount
            ) {
                // success
            } catch {
                revert IRestakingConnector.EigenAgentExecutionError(signer, expiry);
            }

            // ReceiverCCIP approves RestakingConnector just before calling this function
            try IERC20(token).transferFrom(
                _receiverCCIP,
                address(eigenAgent),
                amount
            ) {
                // success
            } catch {
                revert IRestakingConnector.EigenAgentExecutionError(signer, expiry);
            }

            try eigenAgent.executeWithSignature(
                address(strategyManager), // strategyManager
                0 ether,
                EigenlayerMsgEncoders.encodeDepositIntoStrategyMsg(_strategy, token, amount),
                expiry,
                signature
            ) returns (bytes memory result) {
                // success, do nothing.
            } catch {
                revert IRestakingConnector.EigenAgentExecutionError(signer, expiry);
            }

        } catch {
            revert IRestakingConnector.EigenAgentExecutionError(signer, expiry);
        }

    }

    function mintEigenAgent(bytes memory message) public onlyReceiverCCIP {
        // Mint a EigenAgent manually, no signature required.
        address recipient = decodeMintEigenAgent(message);
        agentFactory.tryGetEigenAgentOrSpawn(recipient);
    }

    function queueWithdrawalsWithEigenAgent(bytes memory messageWithSignature) public onlyReceiverCCIP {
        (
            // original message
            IDelegationManager.QueuedWithdrawalParams[] memory qwpArray,
            // message signature
            , // address signer
            uint256 expiry,
            bytes memory signature
        ) = decodeQueueWithdrawalsMsg(messageWithSignature);

        address withdrawer = qwpArray[0].withdrawer;
        uint256 withdrawalNonce = delegationManager.cumulativeWithdrawalsQueued(withdrawer);
        _withdrawalBlock[withdrawer][withdrawalNonce] = block.number;
        /// msg.sender == withdrawer == staker (EigenAgent is all three)
        IEigenAgent6551 eigenAgent = IEigenAgent6551(payable(withdrawer));

        eigenAgent.executeWithSignature(
            address(delegationManager),
            0 ether,
            EigenlayerMsgEncoders.encodeQueueWithdrawalsMsg(qwpArray),
            expiry,
            signature
        );
    }

    function completeWithdrawalWithEigenAgent(bytes memory messageWithSignature)
        public onlyReceiverCCIP
        returns (
            bool receiveAsTokens,
            uint256 withdrawalAmount,
            address withdrawalToken,
            string memory messageForL2,
            bytes32 withdrawalTransferRoot
        )
    {
        // scope to reduce variable count
        {
            (
                // original message
                IDelegationManager.Withdrawal memory withdrawal,
                IERC20[] memory tokensToWithdraw,
                uint256 middlewareTimesIndex,
                bool _receiveAsTokens,
                // message signature
                address signer,
                uint256 expiry,
                bytes memory signature
            ) = decodeCompleteWithdrawalMsg(messageWithSignature);

            // eigenAgent == withdrawer == staker == msg.sender (in Eigenlayer)
            IEigenAgent6551 eigenAgent = IEigenAgent6551(payable(withdrawal.withdrawer));

            // (1) EigenAgent receives tokens from Eigenlayer
            // then (2) approves RestakingConnector to (3) transfer tokens to ReceiverCCIP
            eigenAgent.executeWithSignature(
                address(delegationManager),
                0 ether,
                EigenlayerMsgEncoders.encodeCompleteWithdrawalMsg(
                    withdrawal,
                    tokensToWithdraw,
                    middlewareTimesIndex,
                    _receiveAsTokens
                ),
                expiry,
                signature
            );

            // assign variables to return to L2
            receiveAsTokens = _receiveAsTokens;
            withdrawalAmount = withdrawal.shares[0];
            withdrawalToken = address(tokensToWithdraw[0]);
            withdrawalTransferRoot = EigenlayerMsgEncoders.calculateWithdrawalTransferRoot(
                delegationManager.calculateWithdrawalRoot(withdrawal), // withdrawalRoot
                withdrawalAmount,
                signer
            );
            // hash(withdrawalRoot, signer) to make withdrawalTransferRoot for L2 transfer
            messageForL2 = string(EigenlayerMsgEncoders.encodeHandleTransferToAgentOwnerMsg(
                withdrawalTransferRoot
            ));

            if (_receiveAsTokens) {
                // (2) EigenAgent approves RestakingConnector to transfer tokens to ReceiverCCIP
                eigenAgent.approveByWhitelistedContract(
                    address(this), // restakingConnector
                    withdrawalToken,
                    withdrawalAmount
                );
                // (3) RestakingConnector transfers tokens to ReceiverCCIP, to bridge tokens to Router (bridge)
                IERC20(withdrawalToken).transferFrom(
                    address(eigenAgent),
                    _receiverCCIP,
                    withdrawalAmount
                );
            }
        }
        //// Named return variables are defined in the function signature. This line is not needed.
        // return (
        //     receiveAsTokens,
        //     withdrawalAmount,
        //     withdrawalToken,
        //     messageForL2,
        //     withdrawalTransferRoot
        // );
    }

    function delegateToWithEigenAgent(bytes memory messageWithSignature) public onlyReceiverCCIP {
        (
            // original message
            address operator,
            ISignatureUtils.SignatureWithExpiry memory approverSignatureAndExpiry,
            bytes32 approverSalt,
            // message signature
            address signer,
            uint256 expiry,
            bytes memory signature
        ) = DelegationDecoders.decodeDelegateToMsg(messageWithSignature);

        IEigenAgent6551 eigenAgent = agentFactory.getEigenAgent(signer);

        eigenAgent.executeWithSignature(
            address(delegationManager),
            0 ether,
            EigenlayerMsgEncoders.encodeDelegateTo(
                operator,
                approverSignatureAndExpiry,
                approverSalt
            ),
            expiry,
            signature
        );
    }

    function undelegateWithEigenAgent(bytes memory messageWithSignature) public onlyReceiverCCIP {
        (
            // original message
            address eigenAgentAddr, // staker in Eigenlayer delegating
            // message signature
            , // address signer
            uint256 expiry,
            bytes memory signature
        ) = DelegationDecoders.decodeUndelegateMsg(messageWithSignature);

        IEigenAgent6551 eigenAgent = IEigenAgent6551(payable(eigenAgentAddr));

        uint256 withdrawalNonce = delegationManager.cumulativeWithdrawalsQueued(eigenAgentAddr);

        _withdrawalBlock[eigenAgentAddr][withdrawalNonce] = block.number;

        eigenAgent.executeWithSignature(
            address(delegationManager),
            0 ether,
            EigenlayerMsgEncoders.encodeUndelegateMsg(address(eigenAgent)),
            expiry,
            signature
        );
    }

    /*
     *
     *                 Functions
     *
     *
    */

    function getQueueWithdrawalBlock(address staker, uint256 nonce) public view returns (uint256) {
        return _withdrawalBlock[staker][nonce];
    }

    /// @dev Checkpoint the actual block.number before queueWithdrawal happens
    /// When dispatching a L2 -> L1 message to queueWithdrawal, the block.number
    /// varies depending on how long it takes to bridge.
    /// We need the block.number to in the following step to
    /// create the withdrawalRoot used to completeWithdrawal.
    function setQueueWithdrawalBlock(
        address staker,
        uint256 nonce,
        uint256 blockNumber
    ) external onlyAdminOrOwner {
        _withdrawalBlock[staker][nonce] = blockNumber;
        emit SetQueueWithdrawalBlock(staker, nonce, blockNumber);
    }

    function getEigenlayerContracts()
        public view
        returns (IDelegationManager, IStrategyManager, IStrategy)
    {
        return (delegationManager, strategyManager, strategy);
    }

    function setEigenlayerContracts(
        IDelegationManager _delegationManager,
        IStrategyManager _strategyManager,
        IStrategy _strategy
    ) public onlyOwner {

        if (address(_delegationManager) == address(0))
            revert AddressZero("_delegationManager cannot be address(0)");

        if (address(_strategyManager) == address(0))
            revert AddressZero("_strategyManager cannot be address(0)");

        if (address(_strategy) == address(0))
            revert AddressZero("_strategy cannot be address(0)");

        delegationManager = _delegationManager;
        strategyManager = _strategyManager;
        strategy = _strategy;
    }

    function setGasLimitsForFunctionSelectors(
        bytes4[] memory functionSelectors,
        uint256[] memory gasLimits
    ) public onlyAdminOrOwner {

        require(functionSelectors.length == gasLimits.length, "input arrays must have the same length");

        for (uint256 i = 0; i < gasLimits.length; ++i) {
            _gasLimitsForFunctionSelectors[functionSelectors[i]] = gasLimits[i];
            emit SetGasLimitForFunctionSelector(functionSelectors[i], gasLimits[i]);
        }
    }

    function getGasLimitForFunctionSelector(bytes4 functionSelector) public view returns (uint256) {
        uint256 gasLimit = _gasLimitsForFunctionSelectors[functionSelector];
        if (gasLimit != 0) {
            return gasLimit;
        } else {
            // default gasLimit
            return 400_000;
        }
    }
}