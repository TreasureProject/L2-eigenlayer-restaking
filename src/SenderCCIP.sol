// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {FunctionSelectorDecoder} from "./utils/FunctionSelectorDecoder.sol";
import {BaseMessengerCCIP} from "./BaseMessengerCCIP.sol";
import {ISenderHooks} from "./interfaces/ISenderHooks.sol";


/// @title L2 Messenger Contract: sends Eigenlayer messages to CCIP Router
contract SenderCCIP is Initializable, BaseMessengerCCIP {

    event MatchedReceivedFunctionSelector(bytes4 indexed);

    ISenderHooks public senderHooks;

    /// @param _router address of the router contract.
    /// @param _link address of the link contract.
    constructor(address _router, address _link) BaseMessengerCCIP(_router, _link) {
        _disableInitializers();
    }

    function initialize() initializer public {
        BaseMessengerCCIP.__BaseMessengerCCIP_init();
    }

    function getSenderHooks() public view returns (ISenderHooks) {
        return senderHooks;
    }

    /// @param _senderHooks address of the SenderHooks contract.
    function setSenderHooks(ISenderHooks _senderHooks) external onlyOwner {
        require(address(_senderHooks) != address(0), "_senderHooks cannot be address(0)");
        senderHooks = _senderHooks;
    }

    /*
     *
     *                Receiving
     *
     *
    */

    /**
     * @dev ccipReceiver is called when a CCIP bridge contract receives a CCIP message.
     * This contract allows us to define custom logic to handle outboound Eigenlayer messages
     * for instance, committing a withdrawalTransferRoot on outbound completeWithdrawal messages.
     */
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

        string memory textMsg = _afterCCIPReceiveMessage(any2EvmMessage);

        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address)),
            textMsg,
            s_lastReceivedTokenAddress,
            s_lastReceivedTokenAmount
        );
    }

    /**
     * @dev This function catches outbound completeWithdrawal messages to L1 Eigenlayer, and
     * sets a withdrawalTransferRoot commitment that contains info on the agentOwner and amount.
     * This is so when the SenderCCIP bridge receives the withdrawn funds from L1, it knows who to
     * transfer the funds to.
     */
    function _afterCCIPReceiveMessage(Client.Any2EVMMessage memory any2EvmMessage)
        internal
        returns (string memory textMsg)
    {
        bytes memory message = any2EvmMessage.data;
        bytes4 functionSelector = FunctionSelectorDecoder.decodeFunctionSelector(message);

        if (functionSelector == ISenderHooks.handleTransferToAgentOwner.selector) {
            // cast sig "handleTransferToAgentOwner(bytes)" == 0xd8a85b48
            (
                address agentOwner,
                uint256 amount
            ) = senderHooks.handleTransferToAgentOwner(message);

            // agentOwner is the signer, first committed when sending completeWithdrawal
            // message and generating the withdrawalTransferRoot.
            // completeWithdrawal only succeeds for the rightful signer/owner of the EigenAgent
            IERC20(any2EvmMessage.destTokenAmounts[0].token).transfer(agentOwner, amount);

            textMsg = "Completed withdrawal and sent tokens to EigenAgent owner";
        } else {
            emit MatchedReceivedFunctionSelector(functionSelector);
            textMsg = "unknown message";
        }

        return textMsg;
    }

    /*
     *
     *                Sending
     *
     *
    */

    /// @param _receiver The address of the receiver.
    /// @param _text The string data to be sent.
    /// @param _token The token to be transferred.
    /// @param _amount The amount of the token to be transferred.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @param _overrideGasLimit set the gaslimit manually. If 0, uses default gasLimits.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        address _receiver,
        string calldata _text,
        address _token,
        uint256 _amount,
        address _feeTokenAddress,
        uint256 _overrideGasLimit
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
        uint256 gasLimit;

        if (_overrideGasLimit > 0) {
            gasLimit = _overrideGasLimit;
        } else {
            bytes4 functionSelector = FunctionSelectorDecoder.decodeFunctionSelector(message);
            gasLimit = senderHooks.getGasLimitForFunctionSelector(functionSelector);
        }

        senderHooks.beforeSendCCIPMessage(message, _token);

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

