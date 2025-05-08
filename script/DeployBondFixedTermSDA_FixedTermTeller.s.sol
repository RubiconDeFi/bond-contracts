// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {BondAggregator} from "../src/BondAggregator.sol";
import {BondFixedTermSDA} from "../src/BondFixedTermSDA.sol";
import {BondFixedTermTeller} from "../src/BondFixedTermTeller.sol";
import {RolesAuthority, Authority} from "solmate/auth/authorities/RolesAuthority.sol";

import "forge-std/console.sol";
import "forge-std/Script.sol";

contract DeployBondFixedTermSDA_FixedTermTeller is Script {
    /// @dev Aka owner.
    address public GUARDIAN = 0x86df6e29ee8494c389DfFDFb7ce2CE2a62B41bb4;

    function setUp() public {}

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);

	/// @dev Deploy 'RolesAuthority' contract controlled only by the owner.
	RolesAuthority authority = new RolesAuthority(GUARDIAN, Authority(address(0)));

	BondAggregator aggregator = new BondAggregator(GUARDIAN, authority);	
	
	BondFixedTermTeller tellerFixedTerm = new BondFixedTermTeller({
		protocol_: GUARDIAN, // address that will receive fees.
		aggregator_: aggregator,
		guardian_: GUARDIAN,
		authority_: authority
	});
	BondFixedTermSDA fixedTermSDA = new BondFixedTermSDA({
		teller_: tellerFixedTerm,
		aggregator_: aggregator,
		guardian_: GUARDIAN,
		authority_: authority
	});
	
	aggregator.registerAuctioneer(fixedTermSDA);
	
	console.log("authority |", address(authority));
	console.log("aggregator|", address(aggregator));
	console.log("teller_ft |", address(tellerFixedTerm));
	console.log("sda_ft    |", address(fixedTermSDA));	
    }
}
