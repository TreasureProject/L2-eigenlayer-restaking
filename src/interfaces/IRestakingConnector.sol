// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

import {IStrategyManager} from "eigenlayer-contracts/src/contracts/interfaces/IStrategyManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IEigenlayerMsgDecoders} from "../interfaces/IEigenlayerMsgDecoders.sol";

struct EigenlayerDepositMessage {
    bytes4 functionSelector;
    uint256 amount;
    address staker;
}
event EigenlayerDepositParams(
    bytes4 indexed functionSelector,
    uint256 indexed amount,
    address indexed staker
);

struct EigenlayerDepositWithSignatureMessage {
    // bytes4 functionSelector;
    uint256 expiry;
    address strategy;
    address token;
    uint256 amount;
    address staker;
    bytes signature;
}
event EigenlayerDepositWithSignatureParams(
    bytes4 indexed functionSelector,
    uint256 indexed amount,
    address indexed staker
);

event EigenlayerQueueWithdrawalsParams(
    bytes4 indexed functionSelector,
    uint256 indexed amount,
    address indexed staker
);



interface IRestakingConnector is IEigenlayerMsgDecoders {

    function getStrategy() external returns (IStrategy);

    function getStrategyManager() external returns (IStrategyManager);

    function getEigenlayerContracts() external returns (
        IDelegationManager,
        IStrategyManager,
        IStrategy
    );

    function setEigenlayerContracts(
        IDelegationManager _delegationManager,
        IStrategyManager _strategyManager,
        IStrategy _strategy
    ) external;

}