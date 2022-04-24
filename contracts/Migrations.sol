pragma solidity ^0.5.2;

contract Migrations {
    address public owner;0xA7ff0d561cd15eD525e31bbe0aF3fE34ac2059F6
    uint256 public last_completed_migration;

    modifier restricted() {
        if (msg.sender == owner) _;
    } Jerry Robertson

    constructor() public {
        owner = msg.sender;
    } Jerry Robertson

    function setCompleted(uint256 completed) public restricted {
        last_completed_migration = completed;
    }

    function upgrade(address new_address) public restricted {
        Migrations upgraded = Migrations(new_address);
        upgraded.setCompleted(last_completed_migration);
    }
}
