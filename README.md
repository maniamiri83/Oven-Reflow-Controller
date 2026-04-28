# Reflow Oven Controller

8052 Assembly firmware on a DE10-Lite FPGA that turns a consumer toaster oven into a precision reflow soldering station. Drives a solid-state relay via PWM through a 5-stage finite state machine, reads a K-type thermocouple through a custom analog front-end, and streams live temperature data to a Python validation GUI. Successfully soldered EFM8 microcontroller boards.

---

## Demo (click to play)

[![Demo](https://img.youtube.com/vi/fs8jwbeQrqk/maxresdefault.jpg)](https://m.youtube.com/watch?v=fs8jwbeQrqk&ra=m)

---

Temperature validation — DE10-Lite vs Fluke 45 multimeter across full reflow cycle

<img width="2560" height="1495" alt="Project1Plot" src="https://github.com/user-attachments/assets/0b8a805f-a2d7-4f44-99fb-7dfbd7eb4d5b" />

---

## Hardware

Full system — DE10-Lite FPGA board with analog front-end breadboard

<img width="3024" height="4032" alt="Project1Picture1" src="https://github.com/user-attachments/assets/c8fdee13-c797-4d5d-88fd-84f25ba7be9f" />

---

Analog front-end — OP07 amplifier, LM335 cold-junction sensor, LCD display


<img width="3024" height="4032" alt="Project1Picture2" src="https://github.com/user-attachments/assets/2995d866-c593-47b9-a872-851d57cdb004" />

---

Toaster oven during reflow stage

<img width="4032" height="3024" alt="Project1Picture3" src="https://github.com/user-attachments/assets/6d3abc0c-1ea7-4129-b3a0-114ecd2b7306" />


| Component | Role |
|---|---|
| DE10-Lite (8052 MCU core) | Main controller — runs all firmware |
| K-type thermocouple + OP07 (gain = 300) | Hot-junction temperature measurement |
| LM335 | Cold-junction compensation |
| LM4040 (4.096 V) | ADC voltage reference |
| 30 A solid-state relay + N-ch MOSFET | Oven power switching |
| 16×2 LCD (4-bit mode) | Parameter display and stage info |
| 4×4 matrix keypad | Soak/reflow temperature and time entry |
| Fluke 45 multimeter (serial) | Independent thermocouple validation |

---

## Firmware Architecture

All control logic is written in **8052 Assembly** — no HAL, no RTOS.

**Timer0 ISR (1 ms)** — PWM heartbeat. Compares `PWM_Count` against `PWM_Threshold` to drive `SSR_PIN` high or low. Also increments a 1 s `mf` flag and a 200 ms `refresh_flag` consumed by the main loop.

**5-Stage Reflow FSM**

FSM state transitions and Python GUI data flow

<img width="452" height="210" alt="hardware" src="https://github.com/user-attachments/assets/af6d91e1-4e12-4283-9afb-068cbb016b5e" />

---
| State | Action | Power |
|---|---|---|
| S0 — Idle | Awaiting start | 0% |
| S1 — Preheat ramp | Full power to soak temperature | 100% |
| S2 — Soak hold | Hold at soak temperature for soak time | 20% |
| S3 — Reflow ramp | Full power to reflow temperature | 100% |
| S4 — Reflow hold | Hold at reflow temperature for reflow time | 20% |
| S5 — Cooling | SSR off; wait for oven to drop below 60 °C | 0% |

**Temperature measurement** — three ADC channels read per loop: `val_lm4040` (reference), `val_lm335` (cold junction), `val_op07` (amplified thermocouple). 32-bit integer math library computes oven temperature from ratiometric ADC readings, corrected for cold-junction offset.

**Safety shutoffs** — automatic emergency stop with 10-beep alert and red LED if:
- Temperature does not reach 50 °C within the first 60 s (heating failure)
- Temperature exceeds 250 °C during the reflow hold (overtemperature)

**Serial output** — once per loop the MCU transmits:
```
T=<temp>C <soak_temp> <soak_time> <reflow_temp> <reflow_time> <FSM_state>
```

---

## Python Validation GUI

`serial_reader.py` reads two serial ports simultaneously — the DE10-Lite MCU and the Fluke 45 multimeter — converting multimeter voltage readings to temperature via NIST K-type thermocouple polynomials (`kconvert.py`). A live stripchart plots both temperature curves in real time and computes the error at each sample. Data can be exported to CSV.

**Measured accuracy: consistently < 3 °C error across full reflow cycles** (worst case observed during rapid ramp-up; steady-state error typically < 1 °C).

---

## Repository Structure

```
├── ReflowOvenController.asm   # Top-level firmware — FSM, ADC, UI, serial, PWM
├── math32.asm                 # 32-bit integer arithmetic library
├── LCD_4bit_DE10Lite_no_RW.inc
├── MODMAX10.inc
├── serial_reader.py           # Python dual-source validation GUI
└── kconvert.py                # NIST K-type thermocouple conversion polynomials
```

---

## Key Specs

- Temperature range: 25 °C – 240 °C, ±3 °C accuracy
- PWM period: 100 ms (Timer0, 1 ms ticks)
- SSR: 30 A / 120 VAC, MOSFET-driven control side
- Serial baud rate: 115200
- LCD refresh: 200 ms; FSM update: 1 s
