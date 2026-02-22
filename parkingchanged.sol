// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract ParkingPPX is Ownable, ReentrancyGuard, Pausable {
    enum SpotState { FREE, CHECKED_IN, OCCUPIED }

    struct Spot {
        SpotState state;
        address driver;
        uint256 depositWei;
        uint256 checkInTime;
        uint256 startTime;
    }

    address public oracle;
    uint256 public pricePerMinuteWei;
    uint256 public minDepositWei;
    uint256 public checkInTimeoutSec = 5 minutes;

    mapping(uint256 => Spot) public spots;

    // Tracks how much ETH is reserved for active deposits (must not be withdrawable).
    uint256 public totalDepositsLocked;

    event CheckedIn(uint256 indexed spotId, address indexed driver, uint256 depositWei);
    event CheckInCancelled(uint256 indexed spotId, address indexed driver, uint256 refundWei);
    event Occupied(uint256 indexed spotId, uint256 startTime);
    event Freed(
        uint256 indexed spotId,
        uint256 endTime,
        uint256 minutesBilled,
        uint256 feeWei,
        uint256 refundWei,
        address indexed driver
    );

    event ForceReset(uint256 indexed spotId, SpotState oldState, address indexed oldDriver, uint256 refundWei);
    event ForceEnd(uint256 indexed spotId, address indexed driver, uint256 feeWei, uint256 refundWei);

    modifier onlyOracle() {
        require(msg.sender == oracle, "not oracle");
        _;
    }

    constructor(
        uint256 _pricePerMinuteWei,
        address _oracle,
        uint256 _minDepositWei
    ) Ownable(msg.sender) {
        require(_oracle != address(0), "zero oracle");
        pricePerMinuteWei = _pricePerMinuteWei;
        oracle = _oracle;
        minDepositWei = _minDepositWei;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "zero oracle");
        oracle = _oracle;
    }

    function setPricePerMinute(uint256 _pricePerMinuteWei) external onlyOwner {
        pricePerMinuteWei = _pricePerMinuteWei;
    }

    function setMinDeposit(uint256 _minDepositWei) external onlyOwner {
        minDepositWei = _minDepositWei;
    }

    function setCheckInTimeout(uint256 _timeoutSec) external onlyOwner {
        require(_timeoutSec >= 60, "timeout too small");
        checkInTimeoutSec = _timeoutSec;
    }

    // Shows how much the owner can safely withdraw (fees only).
    function withdrawable() public view returns (uint256) {
        return address(this).balance - totalDepositsLocked;
    }

    function withdraw(address payable to, uint256 amountWei)
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

    function checkIn(uint256 spotId) external payable whenNotPaused {
        Spot storage s = spots[spotId];
        require(s.state == SpotState.FREE, "spot not free");
        require(msg.value >= minDepositWei, "deposit too small");

        s.state = SpotState.CHECKED_IN;
        s.driver = msg.sender;
        s.depositWei = msg.value;
        s.checkInTime = block.timestamp;
        s.startTime = 0;

        // Reserve the deposit so it cannot be withdrawn by the owner.
        totalDepositsLocked += msg.value;

        emit CheckedIn(spotId, msg.sender, msg.value);
    }

    function cancelCheckIn(uint256 spotId) external nonReentrant whenNotPaused {
        Spot storage s = spots[spotId];
        require(s.state == SpotState.CHECKED_IN, "not checked in");
        require(s.driver == msg.sender, "not driver");
        require(block.timestamp >= s.checkInTime + checkInTimeoutSec, "timeout not reached");

        uint256 refundWei = s.depositWei;
        address driver = s.driver;

        // Release reserved deposit before reset/refund.
        totalDepositsLocked -= refundWei;

        _resetSpot(s);

        (bool ok, ) = payable(driver).call{value: refundWei}("");
        require(ok, "refund failed");

        emit CheckInCancelled(spotId, driver, refundWei);
    }

    function reportOccupied(uint256 spotId) external onlyOracle whenNotPaused {
        Spot storage s = spots[spotId];
        require(s.state == SpotState.CHECKED_IN, "not checked in");
        require(block.timestamp <= s.checkInTime + checkInTimeoutSec, "check-in expired");

        s.state = SpotState.OCCUPIED;
        s.startTime = block.timestamp;

        emit Occupied(spotId, s.startTime);
    }

    function reportFree(uint256 spotId) external onlyOracle nonReentrant whenNotPaused {
        Spot storage s = spots[spotId];
        require(s.state == SpotState.OCCUPIED, "not occupied");
        _finalizeAndReset(spotId, s, block.timestamp);
    }

    function forceResetSpot(uint256 spotId) external onlyOwner nonReentrant {
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

    function forceEndParking(uint256 spotId) external onlyOwner nonReentrant {
        Spot storage s = spots[spotId];
        require(s.state == SpotState.OCCUPIED, "not occupied");

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

    function _finalizeAndReset(
        uint256 spotId,
        Spot storage s,
        uint256 endTime
    ) internal returns (uint256 feeWei, uint256 refundWei, address driver) {
        require(endTime >= s.startTime, "time error");

        uint256 deposit = s.depositWei;

        uint256 durationSec = endTime - s.startTime;
        uint256 minutesBilled = (durationSec + 59) / 60;
        if (minutesBilled == 0) minutesBilled = 1;

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
