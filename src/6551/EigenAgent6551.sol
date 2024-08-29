// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IERC6551Account} from "@6551/interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "@6551/interfaces/IERC6551Executable.sol";

import {ERC6551AccountUpgradeable} from "./ERC6551AccountUpgradeable.sol";
import {IEigenAgent6551} from "./IEigenAgent6551.sol";
import {IEigenAgentOwner721} from "./IEigenAgentOwner721.sol";



contract EigenAgent6551 is ERC6551AccountUpgradeable, IEigenAgent6551 {

    /*
     *
     *            Constants
     *
     */

    uint256 public execNonce;

    /// @notice The EIP-712 typehash for the deposit struct used by the contract
    bytes32 public constant EIGEN_AGENT_EXEC_TYPEHASH = keccak256("ExecuteWithSignature(address target, uint256 value, bytes data, uint256 expiry)");

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    error CallerIsNotOwner();
    error CallerNotWhitelisted();
    error SignatureNotFromNftOwner();
    error OnlyCallOperationsSupported();

    event ExecutedCall(address indexed target, bytes indexed data);

    /*
     *
     *            Functions
     *
     */

    function getExecNonce() public view returns (uint256) {
        return execNonce;
    }

    function getAgentOwner() public view returns (address) {
        return owner();
    }

    function agentImplVersion() public virtual override returns (uint256) {
        return 1;
    }

    function beforeExecute(bytes calldata data) public override virtual returns (bytes4) {
        return IEigenAgent6551.beforeExecute.selector;
    }

    function afterExecute(
        bytes calldata data,
        bool success,
        bytes memory result
    ) public override virtual returns (bytes4) {
        return IEigenAgent6551.afterExecute.selector;
    }

    function isValidSignature(
        bytes32 digestHash,
        bytes memory signature
    ) public view virtual override returns (bytes4) {
        bool isValid = ECDSA.recover(digestHash, signature) == owner(); // owner of the NFT
        if (isValid) {
            return IERC1271.isValidSignature.selector;
        }

        return bytes4(0);
    }

    modifier onlySignedByNftOwner(
        bytes32 _digestHash,
        bytes memory _signature
    ) {
        if (isValidSignature(_digestHash, _signature) != IERC1271.isValidSignature.selector)
            revert SignatureNotFromNftOwner();
        _;
    }

    modifier onlyWhitelistedCallers() {
        (uint256 chainId, address contractAddress, uint256 tokenId) = token();
        // TODO: require chainId == L1
        if (!IEigenAgentOwner721(contractAddress).isWhitelistedCaller(msg.sender)) {
            revert CallerNotWhitelisted();
        }
        _;
    }

    // Uses the signature that signed the depositIntoStrategy struct,
    // as depositIntoStrategy struct contains (token, amount) fields used in ERC20 approve()
    function approveWithSignature(
        address targetContract,
        uint256 value,
        bytes calldata data,
        uint256 expiry,
        bytes memory signature
    ) external returns (bool) {

        bytes32 digestHash = createEigenAgentCallDigestHash(
            targetContract,
            value,
            data,
            execNonce,
            block.chainid,
            expiry
        );

        if (isValidSignature(digestHash, signature) != IERC1271.isValidSignature.selector)
            revert SignatureNotFromNftOwner();

        (address token, uint256 amount) = decodeApproveERC20FromDepositMsg(data);

        return IERC20(token).approve(targetContract, amount);
    }

    function approveByWhitelistedContract(
        address targetContract,
        address token,
        uint256 amount
    ) external onlyWhitelistedCallers returns (bool) {
        return IERC20(token).approve(targetContract, amount);
    }

    function executeWithSignature(
        address targetContract,
        uint256 value,
        bytes calldata data,
        uint256 expiry,
        bytes memory signature
    )
        external
        payable
        virtual
        returns (bytes memory result)
    {
        // no longer need msg.sender == nftOwner constraint
        // if (!_isValidSigner(msg.sender)) revert CallerIsNotOwner();
        bytes32 digestHash = createEigenAgentCallDigestHash(
            targetContract,
            value,
            data,
            execNonce,
            block.chainid,
            expiry
        );

        if (isValidSignature(digestHash, signature) != IERC1271.isValidSignature.selector)
            revert SignatureNotFromNftOwner();

        ++state;
        bool success;

        beforeExecute(data);
        {
            // solhint-disable-next-line avoid-low-level-calls
            (success, result) = targetContract.call{value: value}(data);
        }
        afterExecute(data, success, result);

        emit ExecutedCall(targetContract, data);

        require(success, string(result));
        return result;
    }

    function createEigenAgentCallDigestHash(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        uint256 chainid,
        uint256 expiry
    ) public pure returns (bytes32) {

        bytes32 structHash = keccak256(abi.encode(
            EIGEN_AGENT_EXEC_TYPEHASH,
            target,
            value,
            data,
            nonce,
            chainid,
            expiry
        ));
        // calculate the digest hash
        bytes32 digestHash = keccak256(abi.encodePacked(
            "\x19\x01",
            getDomainSeparator(target, chainid),
            structHash
        ));

        return digestHash;
    }

    function getDomainSeparator(
        address contractAddr, // strategyManagerAddr, or delegationManagerAddr
        uint256 destinationChainid
    ) public pure returns (bytes32) {

        uint256 chainid = destinationChainid;

        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("EigenLayer")), chainid, contractAddr));
        // Note: in calculating the domainSeparator:
        // address(this) is the StrategyManager, not this contract (SignatureUtilsEIP2172)
        // chainid is the chain Eigenlayer is deployed on (it can fork!), not the chain you are calling this function
        // So chainid should be destination chainid in the context of L2 -> L1 restaking calls
    }

    function decodeApproveERC20FromDepositMsg(bytes memory message)
        public pure
        returns (address, uint256)
    {
        ////////////////////////////////////////////////////////
        //// deserialize data from Deposit Msg for approve()
        ////////////////////////////////////////////////////////

        // e7a050aa                                                         [32] function selector
        // 0000000000000000000000000b731ce99ec04be646ecac8a7fa9a5126b44c54b [36] strategy
        // 000000000000000000000000fd57b4ddbf88a4e07ff4e34c487b99af2fe82a05 [68] token
        // 0000000000000000000000000000000000000000000000000009f295cd5f0000 [100] amount

        address token;
        uint256 amount;

        assembly {
            token := mload(add(message, 68))
            amount := mload(add(message, 100))
        }

        return (token, amount);
    }

    /*
     *
     *            EIP-1271 Smart Contract Signature
     *
     */

    // function isValidSignature(
    //     bytes32 _hash,
    //     bytes memory _signature
    // ) public pure returns (bytes4 magicValue) {
    //     bytes4 constant internal MAGICVALUE = 0x1626ba7e;
    //     // implement some hash/signature scheme that checks:
    //     // (bool success, bytes memory result) = EigenAgent6551.staticcall(
    //     //     abi.encodeWithSelector(IERC1271.isValidSignature.selector, hash, signature)
    //     // );
    //     // abi.decode(result, (bytes32)) == bytes32(IERC1271.isValidSignature.selector));
    //     return MAGICVALUE;
    // }
}