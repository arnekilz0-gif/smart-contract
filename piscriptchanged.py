#!/usr/bin/env python3
import os, time, json
from statistics import median
from web3 import Web3
from gpiozero import Device, DistanceSensor
from gpiozero.pins.lgpio import LGPIOFactory

# ------------------- KONFIG -------------------
PC_RPC = "http://141.44.206.249:7545"
CONTRACT_ADDRESS = "0xFfA2696a7dbe9Cd2d191729a5fAA0C891a17c862"
ABI_PATH = "/home/group3/parking_oracle/ParkingABI.json"

# Hardening: prefer env var; fallback keeps your current behavior.
ORACLE_PRIVATE_KEY = os.getenv(
    "ORACLE_PRIVATE_KEY",
    "0x6c3810792932cf009a569c9f2f0317553ecbda2129d32ed9c13ca8a2b9949bdf"
)

SPOT_ID = 1

D_OCC_CM  = 20.0   # <= belegt
D_FREE_CM = 27.0   # >= frei
N = 3              # debounce hits

SAMPLES = 3
SAMPLE_DELAY_S = 0.05
LOOP_SLEEP_S = 1.0
GAS_LIMIT = 300000

# ------------------- GPIO -------------------
Device.pin_factory = LGPIOFactory()
sensor = DistanceSensor(echo=18, trigger=17, max_distance=1.0)

def read_distance_cm(samples=SAMPLES, delay_s=SAMPLE_DELAY_S):
    vals = []
    for _ in range(samples):
        try:
            d = sensor.distance  # 0.0..1.0
        except Exception:
            d = None
        if d is not None:
            cm = d * 100.0
            if 0.5 <= cm <= 100.0:
                vals.append(cm)
        time.sleep(delay_s)
    return median(vals) if vals else None

# ------------------- WEB3 -------------------
w3 = Web3(Web3.HTTPProvider(PC_RPC))
if not w3.is_connected():
    raise SystemExit("RPC nicht erreichbar. Prüfe PC-IP/Port und dass Ganache/Hardhat im LAN lauscht.")

addr = Web3.to_checksum_address(CONTRACT_ADDRESS)
if w3.eth.get_code(addr) in (b"", b"\x00"):
    raise SystemExit("Keine Contract-Bytes an CONTRACT_ADDRESS. Adresse/Netzwerk falsch?")

with open(ABI_PATH, "r") as f:
    abi = json.load(f)

c = w3.eth.contract(address=addr, abi=abi)

acct = w3.eth.account.from_key(ORACLE_PRIVATE_KEY)
ORACLE_ADDR = acct.address

def send_tx(fn, label):
    nonce = w3.eth.get_transaction_count(ORACLE_ADDR, "pending")
    latest = w3.eth.get_block("latest")
    base_fee = latest.get("baseFeePerGas")  # None on legacy chains

    tx = fn.build_transaction({
        "from": ORACLE_ADDR,
        "nonce": nonce,
        "gas": GAS_LIMIT,
        "chainId": w3.eth.chain_id,
    })

    if base_fee is None:
        tx["gasPrice"] = w3.eth.gas_price
    else:
        tip = w3.to_wei(1, "gwei")
        tx["maxPriorityFeePerGas"] = tip
        tx["maxFeePerGas"] = int(base_fee) * 2 + tip

    signed = w3.eth.account.sign_transaction(tx, ORACLE_PRIVATE_KEY)
    raw = getattr(signed, "rawTransaction", signed.raw_transaction)

    txh = w3.eth.send_raw_transaction(raw)
    r = w3.eth.wait_for_transaction_receipt(txh)
    print(f"TX {label} mined:", txh.hex(), "status:", r.status)

# ------------------- LOOP -------------------
occupied = False
occ_hits = 0
free_hits = 0

print("Oracle address:", ORACLE_ADDR)
print(f"Starting loop... OCC<= {D_OCC_CM}cm, FREE>= {D_FREE_CM}cm, N={N}")

while True:
    cm = read_distance_cm()
    if cm is None:
        print("No valid distance reading")
        time.sleep(LOOP_SLEEP_S)
        continue

    print(f"distance={cm:5.1f}cm | occupied={occupied} | hits occ/free={occ_hits}/{free_hits}")

    if not occupied:
        occ_hits = occ_hits + 1 if cm <= D_OCC_CM else 0
        if occ_hits >= N:
            print("==> OCCUPIED detected -> reportOccupied")
            try:
                send_tx(c.functions.reportOccupied(SPOT_ID), "reportOccupied")
                occupied = True
            except Exception as e:
                print("reportOccupied failed:", e)
            occ_hits = free_hits = 0
    else:
        free_hits = free_hits + 1 if cm >= D_FREE_CM else 0
        if free_hits >= N:
            print("==> FREE detected -> reportFree")
            try:
                send_tx(c.functions.reportFree(SPOT_ID), "reportFree")
                occupied = False
            except Exception as e:
                print("reportFree failed:", e)
            occ_hits = free_hits = 0

    time.sleep(LOOP_SLEEP_S)
