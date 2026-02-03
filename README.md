Data that needs to be filled in: 
Deposit: 20000000000000000 Wei;
pricepermin: 1000000000000 Wei;

account 1 = owner;
oracle address account 1 = address of account 2;
account 3 = user;
value account 3 bei checkin = 20000000000000000 Wei;

Case 1: Normaler Ablauf (Happy Path)

Ziel: checkIn → occupied → free → Abrechnung + Refund

🎭 Account 3 (Nutzer)
💰 Value: >= minDeposit (z.B. 0.02 ether)
▶️ checkIn(12)
✅ success, Event CheckedIn

🎭 Account 2 (Oracle)
▶️ reportOccupied(12)
✅ success, Event Occupied

(optional 1–2 Minuten warten)

🎭 Account 2 (Oracle)
▶️ reportFree(12)
✅ success, Event Freed
✅ Spot zurückgesetzt auf FREE (spots(12) zeigt state 0)

Case 2: Deposit zu klein (soll scheitern)

🎭 Account 3 (Nutzer)
💰 Value: unter minDeposit (z.B. 0.005 ether)
▶️ checkIn(12)
❌ revert "deposit too small"

✅ Spot bleibt FREE

Case 3: “Böser Parker” – Oracle startet ohne Check-in (soll scheitern)

🎭 Account 2 (Oracle)
▶️ reportOccupied(12)
❌ revert "not checked in"

Case 4: Check-in aber Auto kommt nie → Timeout → cancel (No-show)

Variante A (echte 5 Minuten warten)

🎭 Account 3 (Nutzer)
💰 Value: z.B. 0.02 ether
▶️ checkIn(12)
✅ success

⏱️ warte, bis checkInTimeoutSec vorbei ist (bei euch 5 min)

🎭 Account 3 (Nutzer)
▶️ cancelCheckIn(12)
✅ success, Event CheckInCancelled
✅ Spot FREE

Variante B (schneller testen)

🎭 Account 1 (Owner)
▶️ setCheckInTimeout(60)
✅ Timeout auf 60 Sekunden gesetzt

dann Case wie oben, aber nur 60s warten.

Case 5: Oracle versucht nach Timeout zu starten (soll scheitern)

🎭 Account 3 (Nutzer)
💰 Value: 0.02 ether
▶️ checkIn(12)
✅ success

⏱️ Timeout abwarten

🎭 Account 2 (Oracle)
▶️ reportOccupied(12)
❌ revert "check-in expired"

Case 6: Rollenprüfung (Access Control)
6A — Nutzer ruft Oracle-Funktion (soll scheitern)

🎭 Account 3 (Nutzer)
▶️ reportOccupied(12)
❌ revert "not oracle"

6B — Oracle ruft Owner-Funktion (soll scheitern)

🎭 Account 2 (Oracle)
▶️ setMinDeposit(...) oder setOracle(...)
❌ revert "not owner"

6C — Oracle versucht cancel (soll scheitern)

Voraussetzung: Spot ist CHECKED_IN (Nutzer hat eingecheckt)

🎭 Account 2 (Oracle)
▶️ cancelCheckIn(12)
❌ revert "not driver"

Case 7: Manual Override – Force Reset (Dispute)

Ziel: Betreiber setzt Spot zurück und refundet komplett

🎭 Account 3 (Nutzer)
💰 Value: 0.02 ether
▶️ checkIn(12)
✅ success

optional: 🎭 Account 2 (Oracle)
▶️ reportOccupied(12)
✅ success

🎭 Account 1 (Owner)
▶️ forceResetSpot(12)
✅ success, Event ForceReset
✅ Spot FREE
✅ Nutzer bekommt vollen Refund

Case 8: Manual Override – Force End (Owner beendet und rechnet ab)

Ziel: Parken läuft, aber Owner beendet und rechnet ab (z.B. Sensor defekt)

🎭 Account 3 (Nutzer)
💰 Value: 0.02 ether
▶️ checkIn(12)
✅ success

🎭 Account 2 (Oracle)
▶️ reportOccupied(12)
✅ success

(optional warten)

🎭 Account 1 (Owner)
▶️ forceEndParking(12)
✅ success, Event Freed und ForceEnd
✅ Spot FREE

Case 9: Doppeltes Einchecken verhindern (Concurrency)

🎭 Account 3 (Nutzer)
💰 Value: 0.02 ether
▶️ checkIn(12)
✅ success

🎭 Account 4 (anderer Nutzer)
💰 Value: 0.02 ether
▶️ checkIn(12)
❌ revert "spot not free"

Case 10: Owner Withdraw (Fees abheben)

Voraussetzung: Mindestens ein Parkvorgang wurde beendet, sodass Fees im Contract sind (Case 1 oder Case 8).

🎭 Account 1 (Owner)
▶️ withdraw(to, amountWei)

to = Account1 Adresse

amountWei = z.B. 1000000000000 (klein anfangen)
✅ success

❌ Versuch mit Account 3: revert "not owner"
