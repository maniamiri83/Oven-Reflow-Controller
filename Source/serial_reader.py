import time
import sys
import serial
import serial.tools.list_ports
import re
import csv
import threading
import kconvert
import dearpygui.dearpygui as dpg

# Parameters for how the plot is displayed
PLOT_VIEWABLE_TIME_WINDOW = 30
PLOT_LOOKAHEAD = 0
PLOT_MAX_TEMPERATURE_DEGC = 250
PLOT_COLOR_MCU = (125, 125, 255)
PLOT_COLOR_MM = (0, 255, 0)

TEMP_COLD_JUNCTION_DEGC = 18

arr_data_time = [] # Stores time. Only important for plotting
arr_data_temp_mcu = [] # Stores calculated thermocouple temperature from DE10-Lite
arr_data_temp_mm = [] # Stores calculated thermocouple temperature from multimeter
arr_data_temp_error = [] # Stores difference between the above two arrays

state_info_mcu = {"soaktemp": 0.0, "soaktime": 0.0, "refltemp": 0.0, "refltime": 0.0, "stateno": 0}

# === Various functions ===

# Appends the supplied values to the global arrays above
def write_data_arrays(time: float, data_temp_mcu: float, data_temp_mm: float, data_temp_error: float) -> None:
    global arr_data_time
    global arr_data_temp_mcu
    global arr_data_temp_mm
    global arr_data_temp_error
    
    arr_data_time += [time]
    arr_data_temp_mcu += [data_temp_mcu]
    arr_data_temp_mm += [data_temp_mm]
    arr_data_temp_error += [data_temp_error]

def get_data_mcu() -> float | None:
    data_temp_mcu = None

    ser_mcu.reset_input_buffer()
    ser_mcu_line = re.search(r'T=(\d+)C\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)', ser_mcu.readline().decode().strip().upper())
    if ser_mcu_line:
        try:
            data_temp_mcu = float(ser_mcu_line.group(1))
            state_info_mcu["soaktemp"] = float(ser_mcu_line.group(2))
            state_info_mcu["soaktime"] = float(ser_mcu_line.group(3)) 
            state_info_mcu["refltemp"] = float(ser_mcu_line.group(4)) 
            state_info_mcu["refltime"] = float(ser_mcu_line.group(5)) 
            state_info_mcu["stateno"] = int(ser_mcu_line.group(6))
        except:
            print(f"Invalid value sent by DE10-Lite: {data_temp_mcu}")

    return data_temp_mcu

# Replicated from sample code
def get_temp_mm() -> float | None:
    data_temp_mm = None

    strin = ser_mm.readline().decode()

    if len(strin) > 1 and strin[1] == '>':
        strin = ser_mm.readline().decode()
    
    ser_mm.write(b"MEAS1?\r\n")

    strin_clean = strin.replace("VDC", "")
    if len(strin_clean) > 0:
        try:
            millivolts_mm = float(strin_clean) * 1000
            data_temp_mm = float(round(kconvert.mV_to_C(millivolts_mm, TEMP_COLD_JUNCTION_DEGC), 2))
        except:
            print(f"Invalid value sent by {device_name_mm}: {strin_clean}")
    
    return data_temp_mm

# Reads from both serial ports and writes data to the arrays every second
def thread_function_serial() -> None:
    data_temp_mcu = get_data_mcu()
    data_temp_mm = get_temp_mm()

    if data_temp_mcu is not None and data_temp_mm is not None:
        if currently_plotting:
            data_temp_error = round(data_temp_mcu - data_temp_mm, 2)
            write_data_arrays(elapsed_time, data_temp_mcu, data_temp_mm, data_temp_error)
            print(f"{data_temp_mcu:>8} °C | {data_temp_mm:>8} °C | {data_temp_error:>8} °C")
    
    threading.Timer(0.0, thread_function_serial).start()

device_name_mm = ""

# Replicated from sample code
def find_serial_port_mm() -> None:
    global ser_mm
    global ser_mm_connected
    global device_name_mm
    
    try:
        ser_mm.close()
    except:
        pass

    port_list = list(serial.tools.list_ports.comports())
    for port in reversed(port_list):
        try:
            ser_mm = serial.Serial(port[0], 9600, timeout=0.5)
            ser_mm.write(b'\x03')
            instr = ser_mm.readline()
            pstring = instr.decode()

            if len(pstring) > 1:
                if pstring[1] == '>':
                    ser_mm.timeout=3
                    ser_mm.write(b"VDC; RATE S; *IDN?\r\n")
                    instr = ser_mm.readline()
                    device_name_mm = instr.decode()
                    ser_mm.readline()
                    ser_mm.write(b"MEAS1?\r\n")
                    ser_mm_connected = True

                    break

                else:
                    ser_mm.close()
            else:
                ser_mm.close()
        except:
            ser_mm_connected = False

# === GUI Callbacks ===

def callback_button_clear_plot() -> None:
    global start_time
    global elapsed_time
    global arr_data_time
    global arr_data_temp_mcu
    global arr_data_temp_mm
    global arr_data_temp_error

    start_time = time.time()
    elapsed_time = 0
    arr_data_time = []
    arr_data_temp_mcu = []
    arr_data_temp_mm = []
    arr_data_temp_error = []

    dpg.set_axis_limits("tag_x_axis", 0, PLOT_VIEWABLE_TIME_WINDOW)

currently_plotting = False

def callback_button_start_stop_plotting() -> None:
    global currently_plotting

    if currently_plotting:
        dpg.set_item_label("tag_button_start_stop_plotting", "Start Plotting")
    else:
        dpg.set_item_label("tag_button_start_stop_plotting", "Stop Plotting")

    currently_plotting = not currently_plotting

filename = "validation_data.csv"

def callback_button_save_data() -> None:
    with open(filename, 'w', newline='') as csvfile:
        fieldnames = ["time", "temp_mcu", "temp_mm", "temp_error"]
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)

        writer.writeheader()
        for i in range(len(arr_data_time)):
            writer.writerow({
                "time": arr_data_time[i],
                "temp_mcu": arr_data_temp_mcu[i],
                "temp_mm": arr_data_temp_mm[i],
                "temp_error": arr_data_temp_error[i]
            })

    print(f"Saved validation data to \"{filename}\"")

scrolling_plot = False

def callback_button_scroll_plot() -> None:
    global scrolling_plot

    if scrolling_plot:
        dpg.set_item_label("tag_button_scroll_plot", "Stripchart View")
    else:
        dpg.set_item_label("tag_button_scroll_plot", "Full View")

    scrolling_plot = not scrolling_plot

# === Initialization ===

ser_mcu = serial.Serial()
ser_mcu_connected = False
try:
    ser_mcu = serial.Serial(
        port='COM5',
        baudrate=115200,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        bytesize=serial.EIGHTBITS
    )

    ser_mcu.is_open
    ser_mcu_connected = True
except:
    pass

ser_mm = serial.Serial()
ser_mm_connected = False
find_serial_port_mm()

if not ser_mcu_connected:
    print("Error: Serial connection for DE10-Lite not found")

if not ser_mm_connected:
    print("Error: Serial connection for multimeter not found")

if (not ser_mcu_connected) or (not ser_mm_connected):
    dpg.destroy_context()
    sys.exit(-1)

ser_mm.is_open

serial_thread = threading.Timer(0, thread_function_serial)
serial_thread.daemon = True

dpg.create_context()

with dpg.window(tag="tag_main_window", width=400, height=400):
    with dpg.group(horizontal=True):
        dpg.add_button(label="Clear Plot", callback=callback_button_clear_plot)
        dpg.add_button(label="Start Plotting", tag="tag_button_start_stop_plotting", callback=callback_button_start_stop_plotting)
        dpg.add_button(label="Save Data", callback=callback_button_save_data)
        dpg.add_button(label="Stripchart View", tag="tag_button_scroll_plot", callback=callback_button_scroll_plot)
        dpg.add_spacer(width=10)
        dpg.add_text(default_value="", tag="tag_state_info")

    with dpg.theme(tag="tag_theme_data_mcu"):
        with dpg.theme_component(dpg.mvLineSeries):
            dpg.add_theme_color(dpg.mvPlotCol_Line, PLOT_COLOR_MCU, category=dpg.mvThemeCat_Plots)

    with dpg.theme(tag="tag_theme_data_mm"):
        with dpg.theme_component(dpg.mvLineSeries):
            dpg.add_theme_color(dpg.mvPlotCol_Line, PLOT_COLOR_MM, category=dpg.mvThemeCat_Plots)

    with dpg.plot(label="Thermocouple Temperature", height=-1, width=-1):
        dpg.add_plot_legend()

        dpg.add_plot_axis(dpg.mvXAxis, label="Time [s]", tag="tag_x_axis")
        dpg.add_plot_axis(dpg.mvYAxis, label="Temperature [°C]", tag="tag_y_axis")
        dpg.set_axis_limits("tag_x_axis", 0, PLOT_VIEWABLE_TIME_WINDOW)
        dpg.set_axis_limits("tag_y_axis", 0, PLOT_MAX_TEMPERATURE_DEGC)

        dpg.add_line_series(
            x=list(arr_data_time), y=list(arr_data_temp_mcu),
            label="DE10-Lite", parent="tag_y_axis", tag="tag_data_mcu"
        )

        dpg.add_line_series(
            x=list(arr_data_time), y=list(arr_data_temp_mm),
            label=device_name_mm, parent="tag_y_axis", tag="tag_data_mm"
        )

        dpg.bind_item_theme("tag_data_mcu", "tag_theme_data_mcu")
        dpg.bind_item_theme("tag_data_mm", "tag_theme_data_mm")

        dpg.set_item_label("tag_data_mcu", f"DE10-Lite")
        dpg.set_item_label("tag_data_mm", f"{device_name_mm}")

dpg.create_viewport(title='Rabin\'s Awesome Verification Data Collector ™©', width=800, height=600)
dpg.set_primary_window("tag_main_window", True)
dpg.setup_dearpygui()
dpg.show_viewport()

# === Main loop ===

start_time = time.time()
elapsed_time = 0
serial_thread.start()

# below replaces, start_dearpygui()
while dpg.is_dearpygui_running():
    # insert here any code you would like to run in the render loop
    # you can manually stop by using stop_dearpygui()

    dpg.set_value("tag_data_mcu", [list(arr_data_time), list(arr_data_temp_mcu)])
    dpg.set_value("tag_data_mm", [list(arr_data_time), list(arr_data_temp_mm)])
    dpg.fit_axis_data("tag_x_axis")
    dpg.fit_axis_data("tag_y_axis")

    if state_info_mcu["stateno"] == 1:
        dpg.set_value("tag_state_info", f"Stage 1: Target Temperature = {state_info_mcu['soaktemp']} °C")
    elif state_info_mcu["stateno"] == 2:
        dpg.set_value("tag_state_info", f"Stage 2: Time Duration = {state_info_mcu['soaktime']} s")
    elif state_info_mcu["stateno"] == 3:
        dpg.set_value("tag_state_info", f"Stage 3: Target Temperature = {state_info_mcu['refltemp']} °C")
    elif state_info_mcu["stateno"] == 4:
        dpg.set_value("tag_state_info", f"Stage 4: Time Duration = {state_info_mcu['refltime']} s")
    elif state_info_mcu["stateno"] == 5:
        dpg.set_value("tag_state_info", f"Stage 5: Cooling to 60 °C")
    else:
        dpg.set_value("tag_state_info", "End of Reflow Cycle")

    if scrolling_plot:
        if elapsed_time >= PLOT_VIEWABLE_TIME_WINDOW - PLOT_LOOKAHEAD:
            dpg.set_axis_limits("tag_x_axis", elapsed_time - PLOT_VIEWABLE_TIME_WINDOW + PLOT_LOOKAHEAD, elapsed_time + PLOT_LOOKAHEAD)
    else:
        if elapsed_time >= PLOT_VIEWABLE_TIME_WINDOW - PLOT_LOOKAHEAD:
            dpg.set_axis_limits("tag_x_axis", 0, elapsed_time + PLOT_LOOKAHEAD)

    if currently_plotting:
        elapsed_time = time.time() - start_time
    dpg.render_dearpygui_frame()

dpg.destroy_context()
sys.exit(0)