//SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP1271SignatureUtils} from "eigenlayer-contracts/src/contracts/libraries/EIP1271SignatureUtils.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IStrategyManagerDomain} from "../IStrategyManagerDomain.sol";

// import "@openzeppelin/contracts/interfaces/IERC1271.sol";
// import "@openzeppelin/contracts/utils/Address.sol";
// import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";


library SignatureUtilsEIP1271 {

    function checkSignature_EIP1271(
        address signer,
        bytes32 digestHash,
        bytes memory signature
    ) public {
        EIP1271SignatureUtils.checkSignature_EIP1271(signer, digestHash, signature);
    }

    function createDigest(
        IStrategy strategy,
        IERC20 token,
        uint256 amount,
        address staker,
        uint256 nonce,
        uint256 expiry,
        bytes32 domainSeparator
    ) public returns (bytes32) {

        /// The EIP-712 typehash for the deposit struct used by the contract
        bytes32 DEPOSIT_TYPEHASH =
            keccak256("Deposit(address staker,address strategy,address token,uint256 amount,uint256 nonce,uint256 expiry)");

        bytes32 structHash = keccak256(abi.encode(DEPOSIT_TYPEHASH, staker, strategy, token, amount, nonce, expiry));
        // calculate the digest hash
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        return digestHash;
    }

    function getDomainSeparator(
        address strategyManagerAddr
    ) public returns (bytes32) {
        bytes32 domainSeparator = IStrategyManagerDomain(strategyManagerAddr).domainSeparator();
        return domainSeparator;
    }
}