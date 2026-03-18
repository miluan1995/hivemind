// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/HiveMindTreasury.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        address token = 0xce11641effead02f64d8d31d5354112c23b44444;
        uint256 minHolding = 1000 ether; // 1000 HIVEMIND minimum to register as agent

        vm.startBroadcast(pk);
        HiveMindTreasury treasury = new HiveMindTreasury(owner, token, minHolding);
        vm.stopBroadcast();

        console.log("Treasury deployed at:", address(treasury));
    }
}
