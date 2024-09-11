// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IBase6551Account} from "./Base6551Account.sol";


interface IEigenAgent6551 is IBase6551Account {

    function execNonce() external view returns (uint256);

    function EIGEN_AGENT_EXEC_TYPEHASH() external returns (bytes32);

    function DOMAIN_TYPEHASH() external returns (bytes32);

    function owner() external view returns (address);

    function token() external view returns (
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    );

    function approveByWhitelistedContract(
        address targetContract,
        address token,
        uint256 amount
    ) external returns (bool);

    function executeWithSignature(
        address targetContract,
        uint256 value,
        bytes calldata data,
        uint256 expiry,
        bytes memory signature
    ) external payable returns (bytes memory result);

    function isValidSignature(
        bytes32 digestHash,
        bytes memory signature
    ) external view returns (bytes4);

    function createEigenAgentCallDigestHash(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        uint256 chainid,
        uint256 expiry
    ) external pure returns (bytes32);

    function domainSeparator(
        address contractAddr,
        uint256 chainid
    ) external pure returns (bytes32);
}
