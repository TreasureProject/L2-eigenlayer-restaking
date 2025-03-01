// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Client} from "@chainlink/ccip/libraries/Client.sol";

interface ISenderHooks {

    struct FundsTransfer {
        address tokenL2;
        address agentOwner;
    }

    function getSenderCCIP() external view returns (address);

    function setSenderCCIP(address newSenderCCIP) external;

    function getGasLimitForFunctionSelector(bytes4 functionSelector) external returns (uint256);

    function setGasLimitsForFunctionSelectors(
        bytes4[] memory functionSelectors,
        uint256[] memory gasLimits
    ) external;

    function bridgeTokensL1toL2(address _bridgeTokenL1) external returns (address);

    function setBridgeTokens(address _bridgeTokenL1, address _bridgeTokenL2) external;

    function clearBridgeTokens(address _bridgeTokenL1) external;

    function getTransferRootAgentOwner(bytes32 transferRoot) external returns (address);

    function isTransferRootSpent(bytes32 transferRoot) external returns (bool);

    function calculateWithdrawalTransferRoot(
        bytes32 withdrawalRoot,
        address agentOwner
    ) external pure returns (bytes32);

    function calculateRewardsTransferRoot(
        bytes32 rewardsRoot,
        address agentOwner
    ) external pure returns (bytes32);

    function beforeSendCCIPMessage(
        bytes memory message,
        Client.EVMTokenAmount[] memory tokenAmounts
    ) external returns (uint256 gasLimit);

    function handleTransferToAgentOwner(bytes memory message) external returns (address);

}


