// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20; // Solidity-Version festlegen

/**
 * ParkingPPX (Pay-Per-Use Parkplatz)
 *
 * Ablauf:
 * 1) Driver ruft checkIn(spotId) und hinterlegt Deposit.
 * 2) Oracle ruft reportOccupied(spotId) wenn Auto erkannt wird (Parken startet).
 * 3) Oracle ruft reportFree(spotId) wenn Auto weg ist (Abrechnung + Refund).
 *
 * Robustheit:
 * - nonReentrant (lokaler Guard)
 * - Custom Errors (weniger Gas, klarere Semantik)
 * - Fees getrennt von Deposits (Owner kann nur accruedFees abheben)
 * - expireCheckIn(): verhindert Dauerblockade bei CHECKED_IN nach Timeout
 * - receive() revert: verhindert versehentliche Direktzahlungen
 */

// Abstrakter Vertrag: einfacher Reentrancy-Guard ohne externe Library
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1; // Guard-Status: nicht in Funktion
    uint256 private constant _ENTERED = 2;     // Guard-Status: gerade in Funktion
    uint256 private _status = _NOT_ENTERED;    // Initialzustand

    // Modifier schützt Funktionen vor Reentrancy
    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy(); // wenn schon drin: abbrechen
        _status = _ENTERED;                           // Eintritt markieren
        _;                                            // Funktionskörper ausführen
        _status = _NOT_ENTERED;                       // Exit markieren
    }
}

/* ------------------------------- Custom Errors ------------------------------ */
// Reentrancy-spezifischer Fehler
error Reentrancy();

// Rollen-/Berechtigungsfehler
error NotOwner();
error NotOracle();

// Parameter-/Inputfehler
error ZeroAddress();
error TimeoutTooSmall();

// Zustandsfehler für Parkplatz
error SpotNotFree();
error NotCheckedIn();
error NotOccupied();
error NotDriver();

// Zahlungs-/Timeoutfehler
error DepositTooSmall();
error TimeoutNotReached();
error CheckInExpired();
error TimeError();

// Withdraw-/Refundfehler
error WithdrawTooMuch();
error WithdrawFailed();
error RefundFailed();

/* ---------------------------------- Contract --------------------------------- */
contract ParkingPPX is ReentrancyGuard {
    // Zustände pro Spot
    enum SpotState {
        FREE,        // frei
        CHECKED_IN,  // reserviert (Deposit liegt)
        OCCUPIED     // Parken läuft
    }

    // Datenstruktur pro Spot
    struct Spot {
        SpotState state;     // aktueller Zustand
        address driver;      // Fahrer, der eingecheckt hat und Refund bekommt
        uint256 depositWei;  // hinterlegtes Deposit
        uint256 checkInTime; // Timestamp beim checkIn
        uint256 startTime;   // Timestamp beim Start des Parkens
    }

    address public owner;              // Contract-Owner (Admin)
    address public oracle;             // Oracle-Adresse (Raspberry Pi Account)
    uint256 public pricePerMinuteWei;  // Preis pro angefangener Minute
    uint256 public minDepositWei;      // Mindestdeposit
    uint256 public checkInTimeoutSec = 5 minutes; // Timeout für CHECKED_IN

    // Nur verdiente Gebühren (Fees) werden hier kumuliert
    uint256 public accruedFeesWei;

    // SpotId -> Spot-Daten (public erzeugt automatisch Getter)
    mapping(uint256 => Spot) public spots;

    /* --------------------------------- Events -------------------------------- */
    // checkIn wurde gemacht
    event CheckedIn(uint256 indexed spotId, address indexed driver, uint256 depositWei);

    // checkIn wurde gecancelt/abgelaufen (refund komplett)
    event CheckInCancelled(uint256 indexed spotId, address indexed driver, uint256 refundWei);

    // Parken wurde gestartet
    event Occupied(uint256 indexed spotId, uint256 startTime);

    // Parken beendet inkl. Settlement
    event Freed(uint256 indexed spotId, uint256 endTime, uint256 minutesBilled, uint256 feeWei, uint256 refundWei, address indexed driver);

    // Admin-Änderungen
    event OracleChanged(address indexed oldOracle, address indexed newOracle);
    event PriceChanged(uint256 oldPricePerMinuteWei, uint256 newPricePerMinuteWei);
    event MinDepositChanged(uint256 oldMinDepositWei, uint256 newMinDepositWei);
    event TimeoutChanged(uint256 oldTimeoutSec, uint256 newTimeoutSec);

    // Owner-Override Events
    event ForceReset(uint256 indexed spotId, SpotState oldState, address indexed oldDriver, uint256 refundWei);
    event ForceEnd(uint256 indexed spotId, address indexed driver, uint256 feeWei, uint256 refundWei);

    /* -------------------------------- Modifiers ------------------------------- */
    // Nur Owner darf
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(); // sonst revert
        _;                                          // sonst weiter
    }

    // Nur Oracle darf
    modifier onlyOracle() {
        if (msg.sender != oracle) revert NotOracle(); // sonst revert
        _;                                            // sonst weiter
    }

    /* ------------------------------- Constructor ------------------------------ */
    // Setzt Preis, Oracle, Mindestdeposit; Owner ist der Deployer
    constructor(uint256 _pricePerMinuteWei, address _oracle, uint256 _minDepositWei) {
        if (_oracle == address(0)) revert ZeroAddress(); // oracle muss gesetzt sein
        owner = msg.sender;                              // deployer ist owner
        pricePerMinuteWei = _pricePerMinuteWei;          // preis speichern
        oracle = _oracle;                                // oracle speichern
        minDepositWei = _minDepositWei;                  // mindestdeposit speichern
    }

    /* --------------------------- Owner/Admin Functions ------------------------- */
    // Oracle-Adresse ändern (z.B. neue Pi-Adresse)
    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress(); // keine 0-Adresse
        address old = oracle;                            // alte oracle merken
        oracle = _oracle;                                // neue oracle setzen
        emit OracleChanged(old, _oracle);                // event
    }

    // Preis pro Minute ändern
    function setPricePerMinute(uint256 _pricePerMinuteWei) external onlyOwner {
        uint256 old = pricePerMinuteWei;                 // alten preis merken
        pricePerMinuteWei = _pricePerMinuteWei;          // neuen preis setzen
        emit PriceChanged(old, _pricePerMinuteWei);      // event
    }

    // Mindestdeposit ändern
    function setMinDeposit(uint256 _minDepositWei) external onlyOwner {
        uint256 old = minDepositWei;                     // alt merken
        minDepositWei = _minDepositWei;                  // neu setzen
        emit MinDepositChanged(old, _minDepositWei);     // event
    }

    // Timeout ändern (min 60 Sekunden)
    function setCheckInTimeout(uint256 _timeoutSec) external onlyOwner {
        if (_timeoutSec < 60) revert TimeoutTooSmall();  // zu klein -> revert
        uint256 old = checkInTimeoutSec;                 // alt merken
        checkInTimeoutSec = _timeoutSec;                 // neu setzen
        emit TimeoutChanged(old, _timeoutSec);           // event
    }

    /**
     * Owner kann ausschließlich accruedFeesWei abheben (nicht laufende Deposits).
     */
    function withdraw(address payable to, uint256 amountWei) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();      // Zieladresse prüfen
        if (amountWei > accruedFeesWei) revert WithdrawTooMuch(); // nur Fees abhebbar

        accruedFeesWei -= amountWei;                     // erst buchen (CEI)

        (bool ok, ) = to.call{value: amountWei}("");     // ETH senden
        if (!ok) revert WithdrawFailed();                // wenn fail -> revert
    }

    /* ------------------------------ Driver Actions ----------------------------- */
    // Driver checkt ein und zahlt Deposit
    function checkIn(uint256 spotId) external payable {
        Spot storage s = spots[spotId];                  // Spot aus mapping holen
        if (s.state != SpotState.FREE) revert SpotNotFree();      // muss frei sein
        if (msg.value < minDepositWei) revert DepositTooSmall();  // min deposit

        s.state = SpotState.CHECKED_IN;                  // Zustand setzen
        s.driver = msg.sender;                           // driver speichern
        s.depositWei = msg.value;                        // deposit speichern
        s.checkInTime = block.timestamp;                 // checkin timestamp
        s.startTime = 0;                                 // startTime zurücksetzen

        emit CheckedIn(spotId, msg.sender, msg.value);   // event
    }

    /**
     * Driver kann nach Timeout canceln, falls nie geparkt wurde.
     */
    function cancelCheckIn(uint256 spotId) external nonReentrant {
        Spot storage s = spots[spotId];                  // Spot laden
        if (s.state != SpotState.CHECKED_IN) revert NotCheckedIn(); // muss CHECKED_IN
        if (s.driver != msg.sender) revert NotDriver();   // nur der driver darf
        if (block.timestamp < s.checkInTime + checkInTimeoutSec) revert TimeoutNotReached(); // timeout prüfen

        uint256 refundWei = s.depositWei;                // refund ist komplettes deposit
        address driver = s.driver;                       // driver merken

        _deleteSpot(spotId);                             // state vor refund löschen (CEI)

        (bool ok, ) = payable(driver).call{value: refundWei}(""); // refund senden
        if (!ok) revert RefundFailed();                  // wenn fail -> revert

        emit CheckInCancelled(spotId, driver, refundWei);// event
    }

    /**
     * Zusätzliche Robustheit: Jeder kann einen abgelaufenen CHECKED_IN auflösen (Full refund).
     */
    function expireCheckIn(uint256 spotId) external nonReentrant {
        Spot storage s = spots[spotId];                  // Spot laden
        if (s.state != SpotState.CHECKED_IN) revert NotCheckedIn(); // muss CHECKED_IN
        if (block.timestamp < s.checkInTime + checkInTimeoutSec) revert TimeoutNotReached(); // timeout prüfen

        uint256 refundWei = s.depositWei;                // refund = deposit
        address driver = s.driver;                       // driver merken

        _deleteSpot(spotId);                             // vor refund löschen (CEI)

        (bool ok, ) = payable(driver).call{value: refundWei}(""); // refund senden
        if (!ok) revert RefundFailed();                  // fail -> revert

        emit CheckInCancelled(spotId, driver, refundWei);// event (wiederverwendet)
    }

    /* ------------------------------- Oracle Actions ---------------------------- */
    // Oracle meldet: Auto erkannt -> Parken startet
    function reportOccupied(uint256 spotId) external onlyOracle {
        Spot storage s = spots[spotId];                  // Spot laden
        if (s.state != SpotState.CHECKED_IN) revert NotCheckedIn(); // muss reserviert sein
        if (block.timestamp > s.checkInTime + checkInTimeoutSec) revert CheckInExpired();   // check-in noch gültig?

        s.state = SpotState.OCCUPIED;                    // Zustand OCCUPIED
        s.startTime = block.timestamp;                   // Startzeit setzen

        emit Occupied(spotId, s.startTime);              // event
    }

    // Oracle meldet: Auto weg -> Settlement & Refund
    function reportFree(uint256 spotId) external onlyOracle nonReentrant {
        Spot storage s = spots[spotId];                  // Spot laden
        if (s.state != SpotState.OCCUPIED) revert NotOccupied(); // muss OCCUPIED sein

        _finalizeAndDelete(spotId, s, block.timestamp);  // Settlement + delete + refund
    }

    /* ------------------------ Manual Override / Dispute ------------------------ */
    // Owner-Notfall: Spot zurücksetzen und deposit vollständig erstatten
    function forceResetSpot(uint256 spotId) external onlyOwner nonReentrant {
        Spot storage s = spots[spotId];                  // Spot laden
        SpotState oldState = s.state;                    // alten state merken
        if (oldState == SpotState.FREE) revert SpotNotFree(); // hier: already free nicht erlaubt

        address oldDriver = s.driver;                    // driver merken
        uint256 refundWei = s.depositWei;                // refund = deposit

        _deleteSpot(spotId);                             // Spot löschen (CEI)

        if (refundWei > 0 && oldDriver != address(0)) {  // nur wenn sinnvoll
            (bool ok, ) = payable(oldDriver).call{value: refundWei}(""); // refund senden
            if (!ok) revert RefundFailed();              // fail -> revert
        }

        emit ForceReset(spotId, oldState, oldDriver, refundWei); // event
    }

    // Owner kann OCCUPIED zwangsweise beenden und regulär abrechnen
    function forceEndParking(uint256 spotId) external onlyOwner nonReentrant {
        Spot storage s = spots[spotId];                  // Spot laden
        if (s.state != SpotState.OCCUPIED) revert NotOccupied(); // muss OCCUPIED

        (uint256 feeWei, uint256 refundWei, address driver) =
            _finalizeAndDelete(spotId, s, block.timestamp);      // Settlement

        emit ForceEnd(spotId, driver, feeWei, refundWei); // Zusatz-Event
    }

    /* --------------------------------- Helpers -------------------------------- */
    // Spot komplett löschen (setzt alle Struct-Felder auf Default)
    function _deleteSpot(uint256 spotId) internal {
        delete spots[spotId];
    }

    // Sekunden -> Minuten aufrunden, Minimum 1 Minute
    function _ceilMinutes(uint256 sec) internal pure returns (uint256) {
        return sec == 0 ? 1 : (sec + 59) / 60;
    }

    // Settlement: fee berechnen, fee cap auf deposit, refund berechnen, Fees buchen, Spot löschen, refund senden, Event
    function _finalizeAndDelete(
        uint256 spotId,
        Spot storage s,
        uint256 endTime
    ) internal returns (uint256 feeWei, uint256 refundWei, address driver) {
        if (endTime < s.startTime) revert TimeError();   // Zeit muss vorwärts laufen

        uint256 durationSec = endTime - s.startTime;     // Dauer in Sekunden
        uint256 minutesBilled = _ceilMinutes(durationSec); // Minuten aufrunden

        feeWei = minutesBilled * pricePerMinuteWei;      // Fee berechnen

        if (feeWei >= s.depositWei) {                    // Fee größer/gleich Deposit?
            feeWei = s.depositWei;                       // cap: max deposit
            refundWei = 0;                               // kein refund
        } else {
            refundWei = s.depositWei - feeWei;           // refund = deposit - fee
        }

        driver = s.driver;                               // driver merken

        accruedFeesWei += feeWei;                        // Fee als verdiente Gebühr buchen

        _deleteSpot(spotId);                             // Spot löschen vor refund (CEI)

        if (refundWei > 0 && driver != address(0)) {     // refund nur wenn >0 und driver gesetzt
            (bool ok, ) = payable(driver).call{value: refundWei}(""); // refund senden
            if (!ok) revert RefundFailed();              // fail -> revert
        }

        emit Freed(spotId, endTime, minutesBilled, feeWei, refundWei, driver); // Abschluss-Event
        return (feeWei, refundWei, driver);              // Rückgabe für forceEnd Event
    }

    // Direktes ETH senden an den Contract blockieren
    receive() external payable {
        revert("direct payments disabled");
    }
}
