// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Imports from OpenZeppelin
import "@openzeppelin/contracts/access/Ownable.sol"; // provides standard ownership with owner(), onlyOwner, transferOwnership, renounceOwnership
import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; // nonReentrant modifier. Prevents attacks on functions that send ETH or call external contracts.
import "@openzeppelin/contracts/security/Pausable.sol"; // emergency mechanism to stop contract. Mechanism with whenNotPaused/ whenPaused

// Contract declaration

contract ParkingPPX is Ownable, ReentrancyGuard, Pausable { // All three modules are applied
    enum SpotState { FREE, CHECKED_IN, OCCUPIED } // Finite state machine for the parking spot (FREE: spot is unused; CHECKED_IN: driver deposited, contract waiting for sensor confirmation; OCCUPIED: driver is parked, contract is tracking time) 

    struct Spot { // Contains all the data for one spot in one place
        SpotState state; // lifecycle state
        address driver; // driver adress
        uint256 depositWei; // deposited funds
        uint256 checkInTime; // needed for timeout and cancel logic
        uint256 startTime; // billing begins here
    }

// global parameters and adresses

    address public oracle; // The raspberry pi (sensor system)
    uint256 public pricePerMinuteWei; // billing rate for parking
    uint256 public minDepositWei; // minimum deposit needed to fund parking
    uint256 public checkInTimeoutSec = 5 minutes; // the window for CHECKED_IN, if no confirmation from sensor, driver can cancel and get deposit back.

// storage mapping

    mapping(uint256 => Spot) public spots; // stores the data of spot by spotId. Public creates getter function

    // Tracks how much ETH is reserved for active deposits (must not be withdrawable).
    uint256 public totalDepositsLocked;

// Events

    event CheckedIn(uint256 indexed spotId, address indexed driver, uint256 depositWei); // Driver deposits and reserves a spot 
    event CheckInCancelled(uint256 indexed spotId, address indexed driver, uint256 refundWei); // Driver cancels check in and receives full refund after timeout
    event Occupied(uint256 indexed spotId, uint256 startTime); // Oracle confirms the presence of a car and billing starts
    event Freed(uint256 indexed spotId, uint256 endTime, uint256 minutesBilled, uint256 feeWei, uint256 refundWei, address indexed driver); // Oracle ends parking and contract transfers fee to owner and refund to driver
    event ForceReset(uint256 indexed spotId, SpotState oldState, address indexed oldDriver, uint256 refundWei); // Owner does emergency reset
    event ForceEnd(uint256 indexed spotId, address indexed driver, uint256 feeWei, uint256 refundWei); // Owner ends parking with normal flow

// Oracle authorization modifier
// restricts sensor functions to Pi key. Without this modifier any account can mark spots as occupied or free.
    modifier onlyOracle() {
        require(msg.sender == oracle, "not oracle");
        _;
    }

// Constructor
// Initializes the owner, the oracle address, the price and the minimum deposit.
    constructor( 
        uint256 _pricePerMinuteWei,
        address _oracle,
        uint256 _minDepositWei
    ) Ownable(msg.sender) {
        require(_oracle != address(0), "zero oracle"); // Prevents setting the oracle to zero address.
        pricePerMinuteWei = _pricePerMinuteWei;
        oracle = _oracle;
        minDepositWei = _minDepositWei;
    }
// Pause control

    function pause() external onlyOwner { // Owner can stop actions that are marked with whenNotPaused
        _pause();
    }

    function unpause() external onlyOwner { // Owner resumes the actions.
        _unpause();
    }

// Admin setters

    function setOracle(address _oracle) external onlyOwner { // Changes the orcale key if key is compromised or change needed.
        require(_oracle != address(0), "zero oracle");
        oracle = _oracle;
    }

    function setPricePerMinute(uint256 _pricePerMinuteWei) external onlyOwner { // Changes the billing price
        pricePerMinuteWei = _pricePerMinuteWei;
    }

    function setMinDeposit(uint256 _minDepositWei) external onlyOwner { // Changes the minimum deposit requirement
        minDepositWei = _minDepositWei;
    }

    function setCheckInTimeout(uint256 _timeoutSec) external onlyOwner { // Changes the timeout and avoids absurd values that will break flow of the contract.
        require(_timeoutSec >= 60, "timeout too small");
        checkInTimeoutSec = _timeoutSec;
    }

// Withdraw

    // Shows how much the owner can safely withdraw (fees only).
    function withdrawable() public view returns (uint256) {
        return address(this).balance - totalDepositsLocked;
    }

    function withdraw(address payable to, uint256 amountWei) // Withdraws the specified amount to the specified address
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        require(to != address(0), "zero to");

        uint256 available = withdrawable();
        require(amountWei <= available, "exceeds withdrawable");

        (bool ok, ) = to.call{value: amountWei}("");
        require(ok, "withdraw failed");
    }

// Driver check in 

    function checkIn(uint256 spotId) external payable whenNotPaused { // User can enter the contract and must be payable to accept the deposit of user. 
        Spot storage s = spots[spotId]; // Loads storage slot for chosen spotId 
        require(s.state == SpotState.FREE, "spot not free"); // Prevents double booking
        require(msg.value >= minDepositWei, "deposit too small"); // Requires user to deposit the minimum

// writes the reservation and timestamps
        s.state = SpotState.CHECKED_IN;
        s.driver = msg.sender;
        s.depositWei = msg.value;
        s.checkInTime = block.timestamp;
        s.startTime = 0;

        // Reserve the deposit so it cannot be withdrawn by the owner.
        totalDepositsLocked += msg.value;

        emit CheckedIn(spotId, msg.sender, msg.value); // records it off-chain
    }

// Driver cancels check in 

    function cancelCheckIn(uint256 spotId) external nonReentrant whenNotPaused { // allows driver to cancel check in ande get deposit back when sensor didnt signal occupied
        Spot storage s = spots[spotId];
        require(s.state == SpotState.CHECKED_IN, "not checked in"); // spot must be CHECKED_IN
        require(s.driver == msg.sender, "not driver"); // Caller must be the same driver/ user
        require(block.timestamp >= s.checkInTime + checkInTimeoutSec, "timeout not reached"); // timout mechanism needs to be done

// the refund amount and driver adress are cached before the reset
        uint256 refundWei = s.depositWei; 
        address driver = s.driver;

        // Release reserved deposit before reset/refund.
        totalDepositsLocked -= refundWei;

        _resetSpot(s); // clears the state before sending amount of ETH/ Wei

        (bool ok, ) = payable(driver).call{value: refundWei}(""); // Refund uses call
        require(ok, "refund failed"); 

        emit CheckInCancelled(spotId, driver, refundWei); // Emits CheckInCancelled
    }

// Oracle reports occupied

    function reportOccupied(uint256 spotId) external onlyOracle whenNotPaused { // Pi confirms the arrival of user (car/ vehicle)
        Spot storage s = spots[spotId];
        require(s.state == SpotState.CHECKED_IN, "not checked in"); // Must be CHECKED_IN
        require(block.timestamp <= s.checkInTime + checkInTimeoutSec, "check-in expired"); // Prevents that spot can be occupied after timeout of check in runs out

        s.state = SpotState.OCCUPIED; // Sets state to OCCUPIED
        s.startTime = block.timestamp; // Starts the time of parking

        emit Occupied(spotId, s.startTime); // Emits Occupied
    }

// Oracle report free

    function reportFree(uint256 spotId) external onlyOracle nonReentrant whenNotPaused { // Pi confirms the car left, ends the billing of the user and resolves the contract
        Spot storage s = spots[spotId];
        require(s.state == SpotState.OCCUPIED, "not occupied"); // Requires OCCUPIED 
        _finalizeAndReset(spotId, s, block.timestamp); // Calls finalizeAndReset
    }

// Owner emgerncy reset

    function forceResetSpot(uint256 spotId) external onlyOwner nonReentrant { // Allows owner for manual recovery when something is stuck or there are sensor issues. Function refunds the full deposit and resets the spot.
        Spot storage s = spots[spotId];
        SpotState oldState = s.state;
        require(oldState != SpotState.FREE, "already free");

        address oldDriver = s.driver;
        uint256 refundWei = s.depositWei;

        // Release reserved deposit before reset/refund.
        totalDepositsLocked -= refundWei;

        _resetSpot(s);

        if (refundWei > 0 && oldDriver != address(0)) {
            (bool ok, ) = payable(oldDriver).call{value: refundWei}("");
            require(ok, "refund failed");
        }

        emit ForceReset(spotId, oldState, oldDriver, refundWei);
    }

// Owner force end

    function forceEndParking(uint256 spotId) external onlyOwner nonReentrant { // Owner has the ability to manually settle the contract if oracle can not report free (sensor issues)
        Spot storage s = spots[spotId];
        require(s.state == SpotState.OCCUPIED, "not occupied"); // Requires OCCUPIED

        (uint256 feeWei, uint256 refundWei, address driver) = _finalizeAndReset(spotId, s, block.timestamp);
        emit ForceEnd(spotId, driver, feeWei, refundWei);
    }

    function _resetSpot(Spot storage s) internal {
        s.state = SpotState.FREE;
        s.driver = address(0);
        s.depositWei = 0;
        s.checkInTime = 0;
        s.startTime = 0;
    }

// Settlement helper

    function _finalizeAndReset( // Bills the user and refunds the rest of deposit
        uint256 spotId,
        Spot storage s,
        uint256 endTime
    ) internal returns (uint256 feeWei, uint256 refundWei, address driver) {
        require(endTime >= s.startTime, "time error"); // Sanity check

        uint256 deposit = s.depositWei;

        uint256 durationSec = endTime - s.startTime; // Duration of the parking
        uint256 minutesBilled = (durationSec + 59) / 60; // Rounds the duration up to full minutes
        if (minutesBilled == 0) minutesBilled = 1; // Ensures there is a minimum charge even if the minutesBilled are 0

        uint256 cost = minutesBilled * pricePerMinuteWei;

        if (cost >= deposit) {
            feeWei = deposit;
            refundWei = 0;
        } else {
            feeWei = cost;
            refundWei = deposit - cost;
        }

        driver = s.driver;

        // Release reserved deposit: session ends here.
        totalDepositsLocked -= deposit;

        _resetSpot(s);

        if (refundWei > 0 && driver != address(0)) {
            (bool ok, ) = payable(driver).call{value: refundWei}("");
            require(ok, "Refund failed");
        }

        emit Freed(spotId, endTime, minutesBilled, feeWei, refundWei, driver);
        return (feeWei, refundWei, driver);
    }

    receive() external payable {}
}
