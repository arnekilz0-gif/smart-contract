// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20; // Compiler version >= 0.8.20 

// Imports from OpenZeppelin
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol"; // provides standard ownership with owner(), onlyOwner, transferOwnership, renounceOwnership
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol"; // nonReentrant modifier. Prevents reentering on functions that use nonReentrant and that send ETH or call external contracts.
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol"; // emergency mechanism to stop contract. Mechanism with whenNotPaused/ whenPaused

// Contract declaration

contract ParkingPPX is Ownable, ReentrancyGuard, Pausable { // All three modules are applied
    // subsequent code is taken from [https://docs.soliditylang.org/en/latest/structure-of-a-contract.html#enum-types]
    enum SpotState { FREE, CHECKED_IN, OCCUPIED } // Finite state machine for the parking spot (FREE: spot is unused; CHECKED_IN: driver deposited, contract waiting for sensor confirmation; OCCUPIED: driver is parked, contract is tracking time) 

    // subsequent code is taken from [https://docs.soliditylang.org/en/latest/structure-of-a-contract.html#struct-types] and enables that several variables can be grouped in one type
    struct Spot { // Contains all the data for one spot in one place
        SpotState state; // lifecycle state
        address driver; // driver adress
        uint256 depositWei; // deposited funds
        uint256 checkInTime; // timestamp of check in
        uint256 startTime; // timestamp when parking starts
    }

    // global parameters and adresses
    // subsequent code is taken from [https://docs.soliditylang.org/en/v0.8.34/cheatsheet.html#function-visibility-specifiers] and is visible externally and internally and creates a getter function
    address public oracle; // The raspberry pi (sensor system)
    uint256 public pricePerMinuteWei; // billing rate for parking
    uint256 public minDepositWei; // minimum deposit needed to fund parking
    uint256 public checkInTimeoutSec = 5 minutes; // the window for CHECKED_IN, if no confirmation from sensor, driver can cancel and get deposit back.

    // storage mapping
    // subsequent code is taken from [https://docs.soliditylang.org/en/latest/types.html#mapping-types]
    mapping(uint256 => Spot) public spots; // Maps spotId to its stored struct. The public keyword generates a getter.

    // Financial variable
    uint256 public totalDepositsLocked; // total deposits currently reserved

    // Events
    // subsequent code is taken from [https://docs.soliditylang.org/en/latest/contracts.html#events]
    event CheckedIn(uint256 indexed spotId, address indexed driver, uint256 depositWei); // Driver deposits and reserves a spot 
    event CheckInCancelled(uint256 indexed spotId, address indexed driver, uint256 refundWei); // Driver cancels check in and receives full refund after timeout
    event Occupied(uint256 indexed spotId, uint256 startTime); // Oracle confirms the presence of a car and billing starts
    event Freed(uint256 indexed spotId, uint256 endTime, uint256 minutesBilled, uint256 feeWei, uint256 refundWei, address indexed driver); // Oracle ends parking, the fee remains in contract and owner can withdraw later
    event ForceReset(uint256 indexed spotId, SpotState oldState, address indexed oldDriver, uint256 refundWei); // Owner does emergency reset
    event ForceEnd(uint256 indexed spotId, address indexed driver, uint256 feeWei, uint256 refundWei); // Owner ends parking with normal flow

    // Oracle authorization modifier
    // restricts sensor functions to Pi key. Without this modifier any account can mark spots as occupied or free.
    // subsequent code is taken from [https://docs.soliditylang.org/en/latest/contracts.html#function-modifiers] and is used to change the behaviour of functions in a declarative way. In Addition code is taken from here [https://docs.soliditylang.org/en/latest/contracts.html#custom-errors] to add a custom error that shows when the condition is false. 
    modifier onlyOracle() {
        require(msg.sender == oracle, "not oracle");
        _; // inserts the function body at that point.
    }

    // Constructor
    // Initializes the owner, the oracle address, the price and the minimum deposit.
    // subsequent code is taken from here [https://docs.soliditylang.org/en/latest/contracts.html#constructor] to declare the constructor function
    constructor( 
        uint256 _pricePerMinuteWei,
        address _oracle,
        uint256 _minDepositWei
        // subsequent code is taken from her [https://docs.openzeppelin.com/contracts/5.x/api/access#Ownable] and sets the intial owner
    ) Ownable(msg.sender) { 
        require(_oracle != address(0), "zero oracle"); // Code is taken from here [https://docs.soliditylang.org/en/latest/contracts.html#custom-errors]. It now requires that the oracle address is not zero. Zero Oracle would permanently disable oracle restricted flows.
        pricePerMinuteWei = _pricePerMinuteWei; // price
        oracle = _oracle; // oracle
        minDepositWei = _minDepositWei; // minimum deposit
    }
    // Pause control
    // pause() and unpause() allow the owner to stop the mechanism. Designed to freeze flow without destroying state.
    // The following functions follow this code [https://docs.soliditylang.org/en/latest/contracts.html#functions]. Code from [https://docs.soliditylang.org/en/latest/contracts.html#function-visibility] and [https://docs.openzeppelin.com/contracts/5.x/api/access#Ownable] is used to change visibility and add access modifier.
    function pause() external onlyOwner { // Owner can stop actions that are marked with whenNotPaused
        _pause(); // this code is taken from [https://docs.openzeppelin.com/contracts/5.x/api/utils#Pausable]
    }

    function unpause() external onlyOwner { // Owner resumes the actions.
        _unpause(); // this code is taken from [https://docs.openzeppelin.com/contracts/5.x/api/utils#Pausable]
    }

    // Admin setters
    // The following functions have external visibility and an onlyOwner modifier with code from [https://docs.soliditylang.org/en/latest/contracts.html#function-visibility and https://docs.openzeppelin.com/contracts/5.x/api/access#Ownable] 
    function setOracle(address _oracle) external onlyOwner { // Changes the orcale key if key is compromised or change needed.
        require(_oracle != address(0), "zero oracle"); // Code is taken from here [https://docs.soliditylang.org/en/latest/contracts.html#custom-errors]. It now requires that the oracle address is not zero. Zero Oracle would permanently disable oracle restricted flows.
        oracle = _oracle;
    }

    function setPricePerMinute(uint256 _pricePerMinuteWei) external onlyOwner { // Changes the billing price
        pricePerMinuteWei = _pricePerMinuteWei;
    }

    function setMinDeposit(uint256 _minDepositWei) external onlyOwner { // Changes the minimum deposit requirement
        minDepositWei = _minDepositWei;
    }

    function setCheckInTimeout(uint256 _timeoutSec) external onlyOwner { // Changes the timeout and avoids absurd values that will break flow of the contract.
        require(_timeoutSec >= 60, "timeout too small"); // Code is taken from here [https://docs.soliditylang.org/en/latest/contracts.html#custom-errors]. This requires that the minimum timeout can not be smaller than 60 seconds.
        checkInTimeoutSec = _timeoutSec;
    }

    // Withdraw Logic
    // This is the only way to withdraw funds from the contract. Withdrawable shows how much balance is in the contract that is not a deposit of a driver that is still parking.
    // The withdraw function is then used to transfer the withdrawable balance to any address.
    // Shows how much the owner can safely withdraw (fees only).
    // Subsequent code is taken from here [https://docs.soliditylang.org/en/latest/contracts.html#getter-functions].
    function withdrawable() public view returns (uint256) {
        return address(this).balance - totalDepositsLocked; // enforces deposit isolation and an external access
    }
    // With code from here [https://docs.soliditylang.org/en/v0.8.34/types.html#address] the function can send Ether to a plain address.
    function withdraw(address payable to, uint256 amountWei) // Withdraws the specified amount to the specified address 
        // Modifiers
        external // Code from [https://docs.soliditylang.org/en/latest/contracts.html#function-visibility] to set the visibility to external.
        onlyOwner // Code from [https://docs.openzeppelin.com/contracts/5.x/api/access#Ownable] to restrict the access.
        nonReentrant // Code from [https://docs.openzeppelin.com/contracts/5.x/api/utils#ReentrancyGuard] to prevent reentrancy attacks.
        whenNotPaused // Code from [https://docs.openzeppelin.com/contracts/5.x/api/utils#Pausable] to make the function only callable when not paused.
    {
        // Subsequent Code is taken from [https://docs.soliditylang.org/en/latest/contracts.html#custom-errors]. It adds custom errors that prevent a faulty transaction.
        require(to != address(0), "zero to"); // Require that the address is not a zero address

        uint256 available = withdrawable();
        require(amountWei <= available, "exceeds withdrawable"); // Require that the amount must not exceed withdrawable amount

        (bool ok, ) = to.call{value: amountWei}(""); // Send the amount to the specified address
        require(ok, "withdraw failed"); // Require that the transfer was successful
    }

    // Driver check in 
    // The following functions with code from [https://docs.soliditylang.org/en/latest/contracts.html#functions] control the check in and the cancellation of a check in of a driver.
    // Visibility
    function checkIn(uint256 spotId) external payable whenNotPaused { // User can enter the contract and must be payable to accept the deposit of user. 
        Spot storage s = spots[spotId]; // Loads storage slot for chosen spotId 
        require(s.state == SpotState.FREE, "spot not free"); // Require that the spot is free
        require(msg.value >= minDepositWei, "deposit too small"); // Require that the deposit is at least the minimum deposit

        // writes the reservation and timestamps
        s.state = SpotState.CHECKED_IN; 
        s.driver = msg.sender;
        s.depositWei = msg.value;
        s.checkInTime = block.timestamp;
        s.startTime = 0;

        // Reserve the deposit so it cannot be withdrawn by the owner.
        totalDepositsLocked += msg.value;

        emit CheckedIn(spotId, msg.sender, msg.value); // Emit the CheckedIn event.
    }

    // Driver cancels check in 
    // This function uses external visibility with code from [https://docs.soliditylang.org/en/latest/contracts.html#function-visibility] and adds a nonReentrant and whenNotPaused modifier with code from [https://docs.openzeppelin.com/contracts/5.x/api/utils#ReentrancyGuard; https://docs.openzeppelin.com/contracts/5.x/api/utils#Pausable]
    function cancelCheckIn(uint256 spotId) external nonReentrant whenNotPaused { // allows driver to cancel check in ande get deposit back when sensor didnt signal occupied
        // According to solidity documentation [https://docs.soliditylang.org/en/latest/introduction-to-smart-contracts.html#locations] a variable declared with storage becomes a reference to a state variable. This line creates a reference on the saved spot, therefore all changes on s will be saved in the contract.
        Spot storage s = spots[spotId];
        // Custom errors with code from here [https://docs.soliditylang.org/en/latest/contracts.html#custom-errors]
        require(s.state == SpotState.CHECKED_IN, "not checked in"); // Require that the spot is checked in.
        require(s.driver == msg.sender, "not driver"); // Require that it is the original driver.
        require(block.timestamp >= s.checkInTime + checkInTimeoutSec, "timeout not reached"); // Require that the timeout has been reached.

        // the refund amount and driver adress are cached before the reset
        uint256 refundWei = s.depositWei; 
        address driver = s.driver;

        // Release reserved deposit before reset/refund with code from [https://docs.soliditylang.org/en/latest/cheatsheet.html#order-of-precedence-of-operators].
        totalDepositsLocked -= refundWei;

        _resetSpot(s); // clears the state before sending amount of ETH/ Wei

        (bool ok, ) = payable(driver).call{value: refundWei}(""); // Refund uses call
        require(ok, "refund failed"); // Require succes

        // With code from here [https://docs.soliditylang.org/en/latest/contracts.html#example] we emit the event CheckInCancelled and it is stored in the transaction logs.
        emit CheckInCancelled(spotId, driver, refundWei); // Emits CheckInCancelled
    }

    // Oracle reports occupied

    function reportOccupied(uint256 spotId) external onlyOracle whenNotPaused { // Pi confirms the arrival of user (car/ vehicle)
        Spot storage s = spots[spotId];
        require(s.state == SpotState.CHECKED_IN, "not checked in"); // Require CHECKED_IN
        require(block.timestamp <= s.checkInTime + checkInTimeoutSec, "check-in expired"); // Require that the check in has not expired

        s.state = SpotState.OCCUPIED; // Sets state to OCCUPIED
        s.startTime = block.timestamp; // Starts the time of parking

        emit Occupied(spotId, s.startTime); // Emits Occupied
    }

    // Oracle report free

    function reportFree(uint256 spotId) external onlyOracle nonReentrant whenNotPaused { // Pi confirms the car left, ends the billing of the user and resolves the contract
        Spot storage s = spots[spotId];
        require(s.state == SpotState.OCCUPIED, "not occupied"); // Requires OCCUPIED 
        _finalizeAndReset(spotId, s, block.timestamp); // Calls _finalizeAndReset
    }

    // Owner emgerncy functions

    // Owner force reset spot

    function forceResetSpot(uint256 spotId) external onlyOwner nonReentrant { // Allows owner for manual recovery when something is stuck or there are sensor issues. Function refunds the full deposit and resets the spot.
        Spot storage s = spots[spotId];
        SpotState oldState = s.state;
        require(oldState != SpotState.FREE, "already free"); // Require not FREE

        // Cache desposit
        address oldDriver = s.driver;
        uint256 refundWei = s.depositWei;

        // Release reserved deposit before reset/refund.
        totalDepositsLocked -= refundWei;

        _resetSpot(s); // Reset spot

        // Refund driver if present
        if (refundWei > 0 && oldDriver != address(0)) {
            (bool ok, ) = payable(oldDriver).call{value: refundWei}("");
            require(ok, "refund failed");
        }

        emit ForceReset(spotId, oldState, oldDriver, refundWei); // Emit ForceReset
    }

    // Owner force end

    function forceEndParking(uint256 spotId) external onlyOwner nonReentrant { // Owner has the ability to manually settle the contract if oracle can not report free (sensor issues)
        Spot storage s = spots[spotId];
        require(s.state == SpotState.OCCUPIED, "not occupied"); // Requires OCCUPIED

        // Calls _finalizeAndReset and emits ForceEnd
        (uint256 feeWei, uint256 refundWei, address driver) = _finalizeAndReset(spotId, s, block.timestamp);
        emit ForceEnd(spotId, driver, feeWei, refundWei);
    }

    // Internal Functions

    function _resetSpot(Spot storage s) internal {
        s.state = SpotState.FREE; // FREE
        s.driver = address(0); // zero address
        s.depositWei = 0; // zero deposit
        s.checkInTime = 0; // zero timestamps 
        s.startTime = 0; // zero timestamps
    }

    // Settlement helper (Core billing engine)

    function _finalizeAndReset( // Bills the user and refunds the rest of deposit
        uint256 spotId,
        Spot storage s,
        uint256 endTime
    ) internal returns (uint256 feeWei, uint256 refundWei, address driver) {
        require(endTime >= s.startTime, "time error"); // Require endTime >= startTime

        // Cache deposit
        uint256 deposit = s.depositWei;

        uint256 durationSec = endTime - s.startTime; // Duration of the parking
        uint256 minutesBilled = (durationSec + 59) / 60; // Rounds the duration up to full minutes
        if (minutesBilled == 0) minutesBilled = 1; // Ensures there is a minimum charge even if the minutesBilled are 0

        uint256 cost = minutesBilled * pricePerMinuteWei; // Compute cost

        // Determine fee and corresponding refund split
        if (cost >= deposit) {
            feeWei = deposit;
            refundWei = 0;
        } else {
            feeWei = cost;
            refundWei = deposit - cost;
        }

        // Cache driver
        driver = s.driver;

        // Release reserved deposit: session ends here.
        totalDepositsLocked -= deposit;

        // Reset spot
        _resetSpot(s);

        // Refund driver if present
        if (refundWei > 0 && driver != address(0)) {
            (bool ok, ) = payable(driver).call{value: refundWei}("");
            require(ok, "Refund failed");
        }

        // Emit Freed
        emit Freed(spotId, endTime, minutesBilled, feeWei, refundWei, driver);
        
        // Return fee/ refund
        return (feeWei, refundWei, driver);
    }
    // Allows direct Ether transfers
    receive() external payable {}
}
