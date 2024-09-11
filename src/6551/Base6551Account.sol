// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";


interface IBase6551Account {
    receive() external payable;

    function execNonce() external view returns (uint256);

    function isValidSigner(address signer, bytes calldata context)
        external
        view
        returns (bytes4 magicValue);

    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    function owner() external view returns (address);

    function token() external view returns (
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    );
}


interface IERC6551Executable {
    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory);
}

// This is a copy of ERC6551Account.sol in reference 6551 repository:
// import {ERC6551Account} from "@6551/examples/simple/ERC6551Account.sol"
//
// The differences are:
// (1) renaming `state` variable to `execNonce` for creating executeWithSignature digests, and
// (2) add `virtual` to the execute() function to make it overridable
// (3) isValidSignature has no implementation, to be overidden in EigenAgent6551.sol
abstract contract Base6551Account is IERC165, IERC1271, IBase6551Account, IERC6551Executable {

    uint256 public execNonce;

    receive() external payable {}

    function execute(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        virtual
        returns (bytes memory result)
    {
        require(_isValidSigner(msg.sender), "Invalid signer");
        require(operation == 0, "Only call operations are supported");

        ++execNonce;

        bool success;
        (success, result) = to.call{value: value}(data);

        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function isValidSigner(address signer, bytes calldata) external view virtual returns (bytes4) {
        if (_isValidSigner(signer)) {
            return IBase6551Account.isValidSigner.selector;
        }

        return bytes4(0);
    }

    function isValidSignature(bytes32 digestHash, bytes memory signature)
        public
        view
        virtual
        returns (bytes4 magicValue);

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(IERC165, IBase6551Account)
        returns (bool)
    {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IBase6551Account).interfaceId
            || interfaceId == type(IERC6551Executable).interfaceId;
    }

    /// @notice Gets the NFT collection associated with ERC-6551 accounts
    function token() public view virtual returns (uint256, address, uint256) {
        bytes memory footer = new bytes(0x60);

        assembly {
            extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
        }

        return abi.decode(footer, (uint256, address, uint256));
    }

    /// @notice Gets the owner of the ERC-6551 account
    function owner() public view virtual returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) return address(0);

        return IERC721(tokenContract).ownerOf(tokenId);
    }

    function _isValidSigner(address signer) internal view virtual returns (bool) {
        return signer == owner();
    }
}