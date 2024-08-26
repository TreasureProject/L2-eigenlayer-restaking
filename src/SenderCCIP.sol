// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";

import {FunctionSelectorDecoder} from "./FunctionSelectorDecoder.sol";
import {BaseMessengerCCIP} from "./BaseMessengerCCIP.sol";
import {ISenderUtils} from "./interfaces/ISenderUtils.sol";
import {SenderUtils} from "./SenderUtils.sol";



contract SenderCCIP is Initializable, BaseMessengerCCIP {

    event MatchedReceivedFunctionSelector(bytes4 indexed, string indexed);

    event MatchedSentFunctionSelector(bytes4 indexed, string indexed);

    ISenderUtils public senderUtils;

    /// @param _router The address of the router contract.
    /// @param _link The address of the link contract.
    constructor(address _router, address _link) BaseMessengerCCIP(_router, _link) {
        _disableInitializers();
    }

    function initialize(ISenderUtils _senderUtils) initializer public {
        require(address(_senderUtils) != address(0), "_senderUtils cannot be address(0)");
        senderUtils = _senderUtils;
        BaseMessengerCCIP.__BaseMessengerCCIP_init();
    }

    function setSenderUtils(ISenderUtils _senderUtils) external onlyOwner {
        senderUtils = _senderUtils;
    }

    function mockCCIPReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) public {
        _ccipReceive(any2EvmMessage);
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage)
        internal
        override
        virtual
        onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        )
    {

        if (any2EvmMessage.destTokenAmounts.length > 0) {
            s_lastReceivedTokenAddress = any2EvmMessage.destTokenAmounts[0].token;
            s_lastReceivedTokenAmount = any2EvmMessage.destTokenAmounts[0].amount;
        } else {
            s_lastReceivedTokenAddress = address(0);
            s_lastReceivedTokenAmount = 0;
        }

        bytes memory message = any2EvmMessage.data;
        string memory text_msg;
        bytes4 functionSelector = FunctionSelectorDecoder.decodeFunctionSelector(message);

        if (functionSelector == ISenderUtils.handleTransferToAgentOwner.selector) {
            // bytes4(keccak256("handleTransferToAgentOwner(bytes32,address,bytes32)")) == 0x17f23aea
            (
                address agentOwner,
                uint256 amount,
                address tokenL2Address
            ) = senderUtils.handleTransferToAgentOwner(message);

            bool success = IERC20(tokenL2Address).transfer(agentOwner, amount);

            require(success, "SenderCCIP: failed to transfer token to agentOwner");

            text_msg = "completed eigenlayer withdrawal and transferred token to L2 staker";

        } else {

            emit MatchedReceivedFunctionSelector(functionSelector, "UnknownFunctionSelector");
            text_msg = "unknown message";
        }

        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address)),
            text_msg,
            s_lastReceivedTokenAddress = address(0),
            s_lastReceivedTokenAmount = 0
        );
    }

    /// @param _receiver The address of the receiver.
    /// @param _text The string data to be sent.
    /// @param _token The token to be transferred.
    /// @param _amount The amount of the token to be transferred.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        address _receiver,
        string calldata _text,
        address _token,
        uint256 _amount,
        address _feeTokenAddress
    ) internal override returns (Client.EVM2AnyMessage memory) {

        Client.EVMTokenAmount[] memory tokenAmounts;
        if (_amount <= 0) {
            // Must be an empty array as no tokens are transferred
            // non-empty arrays with 0 amounts error with CannotSendZeroTokens() == 0x5cf04449
            tokenAmounts = new Client.EVMTokenAmount[](0);
        } else {
            tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({
                token: _token,
                amount: _amount
            });
        }

        bytes memory message = abi.encode(_text);

        bytes4 functionSelector = FunctionSelectorDecoder.decodeFunctionSelector(message);

        // When User sends a message to CompleteQueuedWithdrawal from L2 to L1
        if (functionSelector == IDelegationManager.completeQueuedWithdrawal.selector) {
            // 0x60d7faed = abi.encode(keccask256("completeQueuedWithdrawal((address,address,address,uint256,uint32,address[],uint256[]),address[],uint256,bool)"))
            senderUtils.commitWithdrawalRootInfo(
                message,
                _token // token on L2 for TransferToAgentOwner callback
            );

        } else {

            string memory _functionSelectorName = senderUtils.getFunctionSelectorName(functionSelector);
            emit MatchedSentFunctionSelector(functionSelector, _functionSelectorName);

        }

        uint256 gasLimit = senderUtils.getGasLimitForFunctionSelector(functionSelector);

        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(_receiver),
                data: message,
                tokenAmounts: tokenAmounts,
                feeToken: _feeTokenAddress,
                extraArgs: Client._argsToBytes(
                    Client.EVMExtraArgsV1({ gasLimit: gasLimit })
                )
            });
    }
}

