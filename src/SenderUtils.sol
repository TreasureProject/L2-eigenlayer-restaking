// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {Adminable} from "./utils/Adminable.sol";

import {ISenderUtils} from "./interfaces/ISenderUtils.sol";
import {ISenderCCIP} from "./interfaces/ISenderCCIP.sol";
import {EigenlayerMsgDecoders, TransferToAgentOwnerMsg} from "./utils/EigenlayerMsgDecoders.sol";
import {FunctionSelectorDecoder} from "./utils/FunctionSelectorDecoder.sol";



contract SenderUtils is Initializable, Adminable, EigenlayerMsgDecoders {

    event SendingWithdrawalToAgentOwner(address indexed, uint256 indexed, address indexed);
    event WithdrawalCommitted(bytes32 indexed, address indexed, uint256 indexed, address);
    event SetGasLimitForFunctionSelector(bytes4 indexed, uint256 indexed);

    mapping(bytes32 => ISenderUtils.WithdrawalTransfer) public withdrawalTransferCommittments;
    mapping(bytes32 => bool) public withdrawalRootsSpent;
    mapping(bytes4 => uint256) internal _gasLimitsForFunctionSelectors;

    address internal _senderCCIP;

    constructor() {
        _disableInitializers();
    }

    function initialize() initializer public {

        // depositIntoStrategy + mint EigenAgent: [gas: 1_950,000]
        _gasLimitsForFunctionSelectors[0xe7a050aa] = 2_200_000;
        // mintEigenAgent: [gas: 1_500_000?]
        _gasLimitsForFunctionSelectors[0xcc15a557] = 1_600_000;
        // queueWithdrawals: [gas: 529,085]
        _gasLimitsForFunctionSelectors[0x0dd8dd02] = 800_000;
        // completeQueuedWithdrawals: [gas: 645,948]
        _gasLimitsForFunctionSelectors[0x60d7faed] = 800_000;
        // delegateTo: [gas: 550,292]
        _gasLimitsForFunctionSelectors[0xeea9064b] = 600_000;
        // undelegate: [gas: ?]
        _gasLimitsForFunctionSelectors[0xda8be864] = 400_000;

        __Adminable_init();
    }

    modifier onlySenderCCIP() {
        require(msg.sender == _senderCCIP, "not called by SenderCCIP");
        _;
    }

    function getSenderCCIP() public view returns (address) {
        return _senderCCIP;
    }

    function setSenderCCIP(address newSenderCCIP) public onlyOwner {
        _senderCCIP = newSenderCCIP;
    }

    function handleTransferToAgentOwner(bytes memory message) public returns (
        address,
        uint256,
        address
    ) {

        TransferToAgentOwnerMsg memory transferToAgentOwnerMsg = decodeTransferToAgentOwnerMsg(message);

        bytes32 withdrawalRoot = transferToAgentOwnerMsg.withdrawalRoot;

        ISenderUtils.WithdrawalTransfer memory withdrawalTransfer =
            withdrawalTransferCommittments[withdrawalRoot];

        // mark withdrawalRoot as spent to prevent multiple withdrawals
        withdrawalRootsSpent[withdrawalRoot] = true;
        delete withdrawalTransferCommittments[withdrawalRoot];

        emit SendingWithdrawalToAgentOwner(
            withdrawalTransfer.agentOwner,
            withdrawalTransfer.amount,
            withdrawalTransfer.tokenDestination
        );

        return (
            withdrawalTransfer.agentOwner,
            withdrawalTransfer.amount,
            withdrawalTransfer.tokenDestination
        );
    }

    /// Hook that executes during _buildCCIPMessage (sendMessagePayNative) call
    /// @param message is the outbound message passed to CCIP's _buildCCIPMessage function
    /// @param tokenL2 token on L2 for TransferToAgentOwner callback
    function beforeSendCCIPMessage(bytes memory message, address tokenL2) external onlySenderCCIP {

        bytes4 functionSelector = FunctionSelectorDecoder.decodeFunctionSelector(message);
        // When a user sends a message to `completeQueuedWithdrawal` from L2 to L1:
        if (functionSelector == IDelegationManager.completeQueuedWithdrawal.selector) {
            // 0x60d7faed == cast sig "completeQueuedWithdrawal((address,address,address,uint256,uint32,address[],uint256[]),address[],uint256,bool)"))
            commitWithdrawalRootInfo(message, tokenL2);
        }

    }

    function calculateWithdrawalRoot(
        IDelegationManager.Withdrawal memory withdrawal
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(withdrawal));
    }

    function commitWithdrawalRootInfo(bytes memory message, address tokenDestinationL2) public {

            require(tokenDestinationL2 != address(0), "cannot commit tokenL2 as address(0)");

            (
                IDelegationManager.Withdrawal memory withdrawal,
                , // tokensToWithdraw,
                , // middlewareTimesIndex
                bool receiveAsTokens, // receiveAsTokens
                address signer, // signer
                , // expiry
                // signature
            ) = decodeCompleteWithdrawalMsg(message);

            // only when withdrawing tokens back to L2, not for re-deposits from re-delegations
            if (receiveAsTokens) {
                bytes32 withdrawalRoot = calculateWithdrawalRoot(withdrawal);

                // Check for spent withdrawalRoots to prevent wasted CCIP message
                // as it will fail to withdraw from Eigenlayer
                require(
                    withdrawalRootsSpent[withdrawalRoot] == false,
                    "withdrawalRoot has already been used"
                );

                // Commit to WithdrawalTransfer(withdrawer, amount, token, owner) before sending completeWithdrawal message,
                // so that when the message returns with withdrawalRoot, we lookup (amount, tokenL2, owner)
                // to transfer the bridged funds to.
                withdrawalTransferCommittments[withdrawalRoot] = ISenderUtils.WithdrawalTransfer({
                    withdrawer: withdrawal.withdrawer, // eigenAgent
                    amount: withdrawal.shares[0],
                    tokenDestination: tokenDestinationL2,
                    agentOwner: signer // signer is owner of EigenAgent
                });

                emit WithdrawalCommitted(
                    withdrawalRoot,
                    withdrawal.withdrawer,
                    withdrawal.shares[0],
                    signer
                );
            }
    }

    function setGasLimitsForFunctionSelectors(
        bytes4[] memory functionSelectors,
        uint256[] memory gasLimits
    ) public onlyOwner {
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

