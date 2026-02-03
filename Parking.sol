// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ParkingPPX (Pay-Per-Use Parkplatz)
 *
 * Ablauf:
 * 1) Driver ruft checkIn(spotId) und hinterlegt Deposit (=> Vertragsschluss / Zustimmung).
 * 2) Oracle (IoT/Sensor-Account) ruft reportOccupied(spotId), wenn Auto erkannt wird (=> Parken startet).
 * 3) Oracle ruft reportFree(spotId), wenn Auto weg ist (=> Abrechnung + Refund).
 *
 * Erweiterungen (nach deinen Wünschen):
 * - Timeout für CHECKED_IN (5 Minuten): Driver kann canceln und Deposit zurückholen
 * - Mindest-Deposit
 * - Reentrancy-Guard (nonReentrant)
 * - Manual Override / Dispute-Handling (Owner-only forceReset / forceEnd)
 */

/* ----------------------------- Reentrancy Guard ---------------------------- */
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrancy");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract ParkingPPX is ReentrancyGuard {
    enum SpotState {
        FREE,
        CHECKED_IN,
        OCCUPIED
    }

    struct Spot {
        SpotState state;
        address driver;        // wer eingecheckt hat / refund bekommt
        uint256 depositWei;    // hinterlegte Kaution
        uint256 checkInTime;   // Zeitpunkt checkIn (Timeout-Logik)
        uint256 startTime;     // Zeitpunkt Parkstart (nur in OCCUPIED)
    }

    address public owner;
    address public oracle;                 // Raspberry Pi / Sensor-Oracle
    uint256 public pricePerMinuteWei;      // Preis pro (angefangene) Minute
    uint256 public minDepositWei;          // Mindestdeposit
    uint256 public checkInTimeoutSec = 5 minutes;

    mapping(uint256 => Spot) public spots;

    /* --------------------------------- Events -------------------------------- */
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

    event OracleChanged(address indexed oldOracle, address indexed newOracle);
    event PriceChanged(uint256 oldPricePerMinuteWei, uint256 newPricePerMinuteWei);
    event MinDepositChanged(uint256 oldMinDepositWei, uint256 newMinDepositWei);
    event TimeoutChanged(uint256 oldTimeoutSec, uint256 newTimeoutSec);

    event ForceReset(uint256 indexed spotId, SpotState oldState, address indexed oldDriver, uint256 refundWei);
    event ForceEnd(uint256 indexed spotId, address indexed driver, uint256 feeWei, uint256 refundWei);

    /* -------------------------------- Modifiers ------------------------------- */
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, "not oracle");
        _;
    }

    /* ------------------------------- Constructor ------------------------------ */
    constructor(
        uint256 _pricePerMinuteWei,
        address _oracle,
        uint256 _minDepositWei
    ) {
        owner = msg.sender;
        pricePerMinuteWei = _pricePerMinuteWei;
        oracle = _oracle;
        minDepositWei = _minDepositWei;
    }

    /* --------------------------- Owner/Admin Functions ------------------------- */
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "zero oracle");
        address old = oracle;
        oracle = _oracle;
        emit OracleChanged(old, _oracle);
    }

    function setPricePerMinute(uint256 _pricePerMinuteWei) external onlyOwner {
        uint256 old = pricePerMinuteWei;
        pricePerMinuteWei = _pricePerMinuteWei;
        emit PriceChanged(old, _pricePerMinuteWei);
    }

    function setMinDeposit(uint256 _minDepositWei) external onlyOwner {
        uint256 old = minDepositWei;
        minDepositWei = _minDepositWei;
        emit MinDepositChanged(old, _minDepositWei);
    }

    function setCheckInTimeout(uint256 _timeoutSec) external onlyOwner {
        require(_timeoutSec >= 60, "timeout too small");
        uint256 old = checkInTimeoutSec;
        checkInTimeoutSec = _timeoutSec;
        emit TimeoutChanged(old, _timeoutSec);
    }

    /**
     * Owner kann Fees abheben (Gebuehren bleiben im Contract).
     */
    function withdraw(address payable to, uint256 amountWei) external onlyOwner nonReentrant {
        require(to != address(0), "zero to");
        (bool ok, ) = to.call{value: amountWei}("");
        require(ok, "withdraw failed");
    }

    /* ------------------------------ Driver Actions ----------------------------- */
    /**
     * Driver geht den Vertrag ein (z.B. via QR / Web / Remix): checkIn + Deposit.
     */
    function checkIn(uint256 spotId) external payable {
        Spot storage s = spots[spotId];
        require(s.state == SpotState.FREE, "spot not free");
        require(msg.value >= minDepositWei, "deposit too small");

        s.state = SpotState.CHECKED_IN;
        s.driver = msg.sender;
        s.depositWei = msg.value;
        s.checkInTime = block.timestamp;
        s.startTime = 0;

        emit CheckedIn(spotId, msg.sender, msg.value);
    }

    /**
     * Driver kann nach Timeout canceln, falls nie geparkt wurde.
     * -> Spot wird wieder FREE, Deposit komplett zurück.
     */
    function cancelCheckIn(uint256 spotId) external nonReentrant {
        Spot storage s = spots[spotId];
        require(s.state == SpotState.CHECKED_IN, "not checked in");
        require(s.driver == msg.sender, "not driver");
        require(block.timestamp >= s.checkInTime + checkInTimeoutSec, "timeout not reached");

        uint256 refundWei = s.depositWei;
        address driver = s.driver;

        _resetSpot(s);

        // Interaction (Refund) nach State-Reset (CEI)
        (bool ok, ) = payable(driver).call{value: refundWei}("");
        require(ok, "refund failed");

        emit CheckInCancelled(spotId, driver, refundWei);
    }

    /* ------------------------------- Oracle Actions ---------------------------- */
    /**
     * Oracle meldet: Auto erkannt -> Parken startet.
     * Optional: Wir erzwingen, dass der Check-in nicht "abgelaufen" ist,
     * damit ein sehr alter Check-in nicht ewig blockiert.
     */
    function reportOccupied(uint256 spotId) external onlyOracle {
        Spot storage s = spots[spotId];
        require(s.state == SpotState.CHECKED_IN, "not checked in");
        require(block.timestamp <= s.checkInTime + checkInTimeoutSec, "check-in expired");

        s.state = SpotState.OCCUPIED;
        s.startTime = block.timestamp;

        emit Occupied(spotId, s.startTime);
    }

    /**
     * Oracle meldet: Auto weg -> Abrechnung & Refund.
     */
    function reportFree(uint256 spotId) external onlyOracle nonReentrant {
        Spot storage s = spots[spotId];
        require(s.state == SpotState.OCCUPIED, "not occupied");

        _finalizeAndReset(spotId, s, block.timestamp);
    }

    /* ------------------------ Manual Override / Dispute ------------------------ */
    /**
     * Owner "Not-Aus": Spot hart zurücksetzen.
     * - Wenn CHECKED_IN: volle Erstattung an Driver
     * - Wenn OCCUPIED: wird NICHT automatisch abgerechnet (dafür forceEnd nutzen),
     *   sondern ebenfalls zurückgesetzt mit voller Erstattung (gute Demo-Dispute-Lösung).
     *   (Du kannst das bewusst so argumentieren: bei Dispute erstmal full refund,
     *    Abrechnung off-chain klären.)
     */
    function forceResetSpot(uint256 spotId) external onlyOwner nonReentrant {
        Spot storage s = spots[spotId];
        SpotState oldState = s.state;
        require(oldState != SpotState.FREE, "already free");

        address oldDriver = s.driver;
        uint256 refundWei = s.depositWei;

        _resetSpot(s);

        if (refundWei > 0 && oldDriver != address(0)) {
            (bool ok, ) = payable(oldDriver).call{value: refundWei}("");
            require(ok, "refund failed");
        }

        emit ForceReset(spotId, oldState, oldDriver, refundWei);
    }

    /**
     * Owner kann ein OCCUPIED "zwangsweise" beenden und regulär abrechnen
     * (z.B. Sensor defekt, aber ihr wollt Fee berechnen).
     */
    function forceEndParking(uint256 spotId) external onlyOwner nonReentrant {
        Spot storage s = spots[spotId];
        require(s.state == SpotState.OCCUPIED, "not occupied");

        // reguläres Settlement wie reportFree
        (uint256 feeWei, uint256 refundWei, address driver) = _finalizeAndReset(spotId, s, block.timestamp);

        emit ForceEnd(spotId, driver, feeWei, refundWei);
    }

    /* --------------------------------- Helpers -------------------------------- */
    function getSpot(uint256 spotId)
        external
        view
        returns (SpotState state, address driver, uint256 depositWei, uint256 checkInTime, uint256 startTime)
    {
        Spot storage s = spots[spotId];
        return (s.state, s.driver, s.depositWei, s.checkInTime, s.startTime);
    }

    function _resetSpot(Spot storage s) internal {
        s.state = SpotState.FREE;
        s.driver = address(0);
        s.depositWei = 0;
        s.checkInTime = 0;
        s.startTime = 0;
    }

    /**
     * Abrechnung:
     * - Minuten werden aufgerundet: ceil(seconds/60)
     * - Fee wird auf Deposit gecappt (kein Debt-Tracking, bewusst vereinfachte Uni-Logik)
     * - Refund = deposit - fee (falls positiv)
     *
     * Gibt fee/refund/driver zurück (für forceEnd Event).
     */
    function _finalizeAndReset(
        uint256 spotId,
        Spot storage s,
        uint256 endTime
    ) internal returns (uint256 feeWei, uint256 refundWei, address driver) {
        require(endTime >= s.startTime, "time error");

        uint256 durationSec = endTime - s.startTime;
        uint256 minutesBilled = (durationSec + 59) / 60;
        if (minutesBilled == 0) minutesBilled = 1;

        feeWei = minutesBilled * pricePerMinuteWei;

        if (feeWei >= s.depositWei) {
            feeWei = s.depositWei; // capped
            refundWei = 0;
        } else {
            refundWei = s.depositWei - feeWei;
        }

        driver = s.driver;

        // Effects: reset first
        _resetSpot(s);

        // Interaction: refund after reset
        if (refundWei > 0 && driver != address(0)) {
            (bool ok, ) = payable(driver).call{value: refundWei}("");
            require(ok, "refund failed");
        }

        emit Freed(spotId, endTime, minutesBilled, feeWei, refundWei, driver);
        return (feeWei, refundWei, driver);
    }

    receive() external payable {}
}
