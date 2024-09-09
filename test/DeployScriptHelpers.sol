// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {console} from "forge-std/Test.sol";

contract DeployScriptHelpers {

    function strEq(string memory s1, string memory s2) public pure returns (bool) {
        return keccak256(abi.encode(s1)) == keccak256(abi.encode(s2));
    }

    function compareErrorStr(string memory s1, string memory s2) public pure returns (bool) {
        if (strEq(s1, s2)) {
            console.log(s1);
        } else {
            revert(s1);
        }
    }

    function compareErrorBytes(bytes memory b1, string memory s2) public pure returns (bool) {
        string memory s1 = abi.decode(b1, (string));
        if (strEq(s1, s2)) {
            console.log(s1);
        } else {
            revert(s1);
        }
    }

    function test_deploy_script_helpers() public {}
}
