// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

library ArbSepolia {

    //////////////////////////////////////////////
    // Arb Sepolia
    //////////////////////////////////////////////
    // Router:
    // 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165
    //
    // chain selector:
    // 3478487238524512106
    //
    // CCIP-BnM token:
    // 0xA8C0c11bf64AF62CDCA6f93D3769B88BdD7cb93D
    //////////////////////////////////////////////

    address constant Router = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;

    uint64 constant ChainSelector = 3478487238524512106;

    // The CCIP-BnM contract address at the source chain
    // https://docs.chain.link/ccip/supported-networks/v1_2_0/testnet#arbitrum-sepolia-ethereum-sepolia
    address constant CcipBnM = 0xA8C0c11bf64AF62CDCA6f93D3769B88BdD7cb93D;

    address constant BridgeToken = CcipBnM ;

    address constant Link = 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E;

    uint256 constant ChainId = 421614;
}

library EthSepolia {
    //////////////////////////////////////////////
    // ETH Sepolia
    //////////////////////////////////////////////
    // Router:
    // 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59
    //
    // chain selector:
    // 16015286601757825753
    //
    // CCIP-BnM token:
    // 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05
    //////////////////////////////////////////////

    address constant Router = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

    uint64 constant ChainSelector = 16015286601757825753;

    address constant CcipBnM = 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05;

    address constant BridgeToken = CcipBnM ;

    address constant Link = 0x779877A7B0D9E8603169DdbD7836e478b4624789;

    uint256 constant ChainId = 11155111;
}