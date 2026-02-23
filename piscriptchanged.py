#!/usr/bin/env python3
# Imports
import os, time, json
from statistics import median
from web3 import Web3
from gpiozero import Device, DistanceSensor
from gpiozero.pins.lgpio import LGPIOFactory

# Configuration
# RPC endpoint of Ganache Instance
PC_RPC = "http://141.44.206.249:7545"

# Deployed smart contract address
CONTRACT_ADDRESS = "0xFfA2696a7dbe9Cd2d191729a5fAA0C891a17c862"

# ABI JSON file produced from compiled and deployed smart contract
ABI_PATH = "/home/group3/parking_oracle/ParkingABI.json"

# Private key handling:
# Prefer variable so oracle address doesnt get leaked out of images
ORACLE_PRIVATE_KEY = os.getenv(
    "ORACLE_PRIVATE_KEY",
    "0x6c3810792932cf009a569c9f2f0317553ecbda2129d32ed9c13ca8a2b9949bdf"
)

# Exact parking spot this sensor controls
SPOT_ID = 1

# Occupancy threshholds in centimeters
# Hysteresis: OCC uses <= 20cm, FREE uses >= 27cm. This prevents rapid changes with a single number.
D_OCC_CM  = 20.0   
D_FREE_CM = 27.0 

# Debounce implementation
# There need to be N consecutive OCC or FREE before emitting a state change
N = 3              

# Sampling for noise reduction
# Read multiple sensor samples and use median to reduce outliers (sensor issues)
SAMPLES = 3
SAMPLE_DELAY_S = 0.05

# Loop pacing
LOOP_SLEEP_S = 1.0

# Conservative gas limit for smart contract calls
GAS_LIMIT = 300000

# GPIO
# Force GPIO Zero to use the lgpio backend
Device.pin_factory = LGPIOFactory()

# DistanceSensor expect GPIO pin numbers for echo/ trigger
# max_distance is in meters in GPIO Zero; 1.0m maximum
sensor = DistanceSensor(echo=18, trigger=17, max_distance=1.0)

def read_distance_cm(samples=SAMPLES, delay_s=SAMPLE_DELAY_S):
    """
    Return a robust distance estimate in centimeters, or None if no valid reading.
    
    Median is used because the sensor can spike due to reflections/ angle/ noise. The median is robust to single outliers.
    
    Rejects nonsense readings (very tiny/ very large), which often appear on sensor glitches.
    """
    
    vals = []
    for _ in range(samples):
        try:
            d = sensor.distance  
        except Exception:
            d = None
        if d is not None:
            cm = d * 100.0
            if 0.5 <= cm <= 100.0:
                vals.append(cm)
        time.sleep(delay_s)
    return median(vals) if vals else None

# WEB3
w3 = Web3(Web3.HTTPProvider(PC_RPC))

# Fast Fail: if RPC is not reachable dont run the loop.
if not w3.is_connected():
    raise SystemExit("RPC not reachable. Check IP of the device with Ganache.")

# Fast Fail: if there is no code at smart contract address, ABI calls wil fail
addr = Web3.to_checksum_address(CONTRACT_ADDRESS)
if w3.eth.get_code(addr) in (b"", b"\x00"):
    raise SystemExit("Keine Contract-Bytes an CONTRACT_ADDRESS. Adresse/Netzwerk falsch?")

# Load ABI used t oencode function calls
with open(ABI_PATH, "r") as f:
    abi = json.load(f)

# Create a contract instance bound to the deployed address
c = w3.eth.contract(address=addr, abi=abi)

# Derive oracle account from private key
acct = w3.eth.account.from_key(ORACLE_PRIVATE_KEY)
ORACLE_ADDR = acct.address

def send_tx(fn, label):
    """
    Build, sign and send a transaction for the given contract function call.

    Core invariants:
    - Nonce must be correct (pending to avoid duplicate nonce if tx not mined yet)
    - legacy gasPrice if the chain does not support EIP-1559 base fees
    - Use EIP-1559 fee fields if baseFeePergas exists

    Failure
    - Revert in contract then receipt status 0 or exception
    - Nonce mismatch if parallel runs of the script use the same key
    - Underpriced tx if fee settings are too low on non local chains
    """
    nonce = w3.eth.get_transaction_count(ORACLE_ADDR, "pending")

    # EIP-1559 networks expose baseFeePerGas
    latest = w3.eth.get_block("latest")
    base_fee = latest.get("baseFeePerGas")  

    # Build transaction without signature
    tx = fn.build_transaction({
        "from": ORACLE_ADDR,
        "nonce": nonce,
        "gas": GAS_LIMIT,
        "chainId": w3.eth.chain_id,
    })

    if base_fee is None:
        #Legacy fee model
        tx["gasPrice"] = w3.eth.gas_price
    else:
        #EIP-1559 fee model: maxFeePerGas caps total; maxPriorityFeePerGas is the tip
        tip = w3.to_wei(1, "gwei")
        tx["maxPriorityFeePerGas"] = tip
        tx["maxFeePerGas"] = int(base_fee) * 2 + tip

    # Sign offline and send signed tx bytes
    signed = w3.eth.account.sign_transaction(tx, ORACLE_PRIVATE_KEY)

    # Web3.py changed attribute naming
    raw = getattr(signed, "rawTransaction", signed.raw_transaction)

    txh = w3.eth.send_raw_transaction(raw)
    r = w3.eth.wait_for_transaction_receipt(txh)

    print(f"TX {label} mined:", txh.hex(), "status:", r.status)

# Loop

# Occupied = False means the spot is free intially
# Emit reportOccupied only when N consectuive reading of <= D_OCC_CM
# Emit reportFree only when N consecutive reading of >= D_FREE_CM
occupied = False
occ_hits = 0
free_hits = 0

# Printing statements for visualization
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
        # Count consecutive OCCUPIED and reset if condition breaks
        occ_hits = occ_hits + 1 if cm <= D_OCC_CM else 0

        # Send blockchain update when stable for N iterations
        if occ_hits >= N:
            print("==> OCCUPIED detected -> reportOccupied")
            try:
                send_tx(c.functions.reportOccupied(SPOT_ID), "reportOccupied")
                occupied = True
            except Exception as e:
                print("reportOccupied failed:", e)
            
            # Reset both counter after succes or failure
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
