;---------------------------------;
; Reflow Oven Controller          ;
;---------------------------------;
$NOLIST
$include(MODMAX10.inc)
$LIST

;---------------------------------;
; Pin Definitions                 ;
;---------------------------------;
ELCD_RS 	  EQU P1.7
ELCD_E  	  EQU P1.1
ELCD_D4 	  EQU P0.7
ELCD_D5 	  EQU P0.5
ELCD_D6 	  EQU P0.3
ELCD_D7 	  EQU P0.1

ROW1    	  EQU P1.2
ROW2    	  EQU P1.4
ROW3    	  EQU P1.6
ROW4      	  EQU P2.0
COL1    	  EQU P2.2
COL2    	  EQU P2.4
COL3    	  EQU P2.6
COL4    	  EQU P3.0

PB_MODE       EQU P1.5
PB_INC        EQU P1.3 
PB_START_STOP EQU P3.3 
SSR_PIN       EQU P1.0  
SPEAKER_PIN   EQU P2.1

LEDR_PIN	  EQU P0.0
LEDG_PIN	  EQU P0.2
LEDB_PIN      EQU P0.4

; Constants
FREQ          EQU 33333333
BAUD          EQU 115200
T2LOAD        EQU 65536-(FREQ/(32*BAUD))

; Calibration
TEMP_CALIB_K  EQU 335
VREF_MV       EQU 4108

;---------------------------------;
; Variables                       ;
;---------------------------------;
DSEG at 30H
    x:                 ds 4
    y:                 ds 4
    bcd:               ds 5 

    soak_temp:         ds 2
    soak_time:         ds 2
    reflow_temp:       ds 2
    reflow_time:       ds 2
    
    current_bcd:       ds 5  
    current_mode:      ds 1    
    view_mode:         ds 1    
    cur_temp:          ds 3 
    sec_bcd:           ds 2  
    stage_ch:          ds 1 
    blink_counter:     ds 1
    
    FSM1_STATE:        ds 1    
    FSM_LAST_STATE:    ds 1
    TEMP:              ds 1    
    SEC:               ds 1    
    
    total_sec:         ds 2    
    
    PWM_Count:         ds 1
    PWM_Threshold:     ds 1    
    Run:               ds 1
    
    Count1ms:          ds 2    
    Fast_Tick:         ds 1    

    val_lm4040:        ds 2 
    val_lm335:         ds 2 
    val_op07:          ds 2 
    temp_lm335:        ds 2
    temp_op07:         ds 2
    temp_thermocouple: ds 2
    
    errorflag:		   ds 1

BSEG
    mf:              dbit 1  
    refresh_flag:    dbit 1  
    blink_on:        dbit 1

CSEG
    org 0000H
    ljmp Main
    
    org 000Bh
    ljmp Timer0_ISR

;---------------------------------;
; Include Files                   ;
;---------------------------------;
$include(math32.asm)
$include(LCD_4bit_DE10Lite_no_RW.inc)

;---------------------------------;
; Main Program                    ;
;---------------------------------;
Str_Select:  db 'Select Variable ', 0
Str_Running: db 'Running: ', 0

Main:
    mov errorflag, #0
    mov SP, #7FH
    lcall Init_Ports
    lcall InitSerialPort 
    lcall ELCD_4BIT 
    
    mov ADC_C, #0x80 ; Reset ADC
    lcall Wait50ms

    ; Defaults
    mov soak_temp+0,    #050h 
    mov soak_temp+1,    #01h
    mov soak_time+0,    #060h 
    mov soak_time+1,    #00h
    mov reflow_temp+0,  #020h 
    mov reflow_temp+1,  #02h
    mov reflow_time+0,  #045h 
    mov reflow_time+1,  #00h

    mov current_mode,   #0xFF 
    mov view_mode,      #0         
    mov Run,            #0
    mov FSM1_STATE,     #0
    mov FSM_LAST_STATE, #0
    mov errorflag,      #0
    
    mov total_sec+0,    #0
    mov total_sec+1,    #0
    
    mov Count1ms+0,     #low(1000)
    mov Count1ms+1,     #high(1000)
    mov Fast_Tick,      #0
    clr mf
    clr refresh_flag
    
    setb PB_START_STOP
    setb PB_MODE
    setb PB_INC

    lcall Timer0_Init 
    setb EA             

Forever:
    lcall Check_StartStop
    
    mov a, Run
    jnz Skip_Keypad       
    lcall Check_Switches        
    mov a, current_mode
    cjne a, #0xFF, Scan_Keypad
    sjmp Skip_Keypad

Scan_Keypad:
    lcall Keypad                
    jnc Skip_Keypad         
    mov a, R7                 
    cjne a, #0x0E, Check_Hash
    lcall Shift_Digits_Right 
    sjmp Update_Screen
Check_Hash:
    cjne a, #0x0F, Check_Valid_Digits
    sjmp Skip_Keypad      
Check_Valid_Digits:
    clr c
    subb a, #10
    jnc Skip_Keypad         
    lcall Shift_Digits_Left  
Update_Screen:
    lcall Save_Current_Val    

Skip_Keypad:
    lcall UI_Check_Buttons  
    
    jnb refresh_flag, Check_Sec_Flag
    clr refresh_flag
    
    lcall UI_Tick_Blink
    lcall Read_Temperature
    lcall Display_Temperature_Serial 
    
    lcall UI_Update_HEX      
    lcall UI_Update_Line1            
    lcall UI_Update_Line2    
    lcall Update_LED

Check_Sec_Flag:
    jnb mf, Loop_End 
    clr mf
    mov a, Run
    jz Refresh_Runtime
    lcall FSM_Update_With_Beep           
    
Refresh_Runtime:
    lcall UI_Refresh_Runtime

Loop_End:
    ljmp Forever

;---------------------------------;
; Serial Communication            ;
;---------------------------------;
InitSerialPort:
    clr TR2 
    mov T2CON,  #30H 
    mov RCAP2H, #high(T2LOAD)  
    mov RCAP2L, #low(T2LOAD)
    setb TR2 
    mov SCON,   #52H 
    ret

putchar:
    jnb TI, putchar
    clr TI
    mov SBUF, a
    ret

Display_Temperature_Serial:
    ; Send Current Temp (T=xxxC)
    mov a, #'T'
    lcall putchar
    mov a, #'='
    lcall putchar
    mov a, bcd+1
    anl a, #0FH
    orl a, #'0'
    lcall putchar
    mov a, bcd+0
    swap a
    anl a, #0FH
    orl a, #'0'
    lcall putchar
    mov a, bcd+0
    anl a, #0FH
    orl a, #'0'
    lcall putchar
    mov a, #'C'
    lcall putchar
    
    mov a, #' ' ; Separator
    lcall putchar

    ; Send 4 parameters continuously
    ; Soak Temperature
    mov a, soak_temp+1
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, soak_temp+0
    swap a
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, soak_temp+0
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, #' '
    lcall putchar

    ; Soak Time
    mov a, soak_time+1
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, soak_time+0
    swap a
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, soak_time+0
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, #' '
    lcall putchar

    ; Reflow Temperature
    mov a, reflow_temp+1
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, reflow_temp+0
    swap a
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, reflow_temp+0
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, #' '
    lcall putchar

    ; Reflow Time
    mov a, reflow_time+1
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, reflow_time+0
    swap a
    anl a, #0fh
    orl a, #30h
    lcall putchar
    mov a, reflow_time+0
    anl a, #0fh
    orl a, #30h
    lcall putchar

    ; Send current FSM state
    mov a, #' ' ; Separator
    lcall putchar
    mov a, FSM1_STATE
    add a, #30h ; Convert digit to ASCII
    lcall putchar

    ; Newline
    mov a, #'\r'
    lcall putchar
    mov a, #'\n'
    lcall putchar
    ret

;---------------------------------;
; Button Controls                 ;
;---------------------------------;
Check_StartStop:
    jb  PB_START_STOP, CSS_Ret             
    lcall Wait25ms
    jb  PB_START_STOP, CSS_Ret
    mov a, Run
    jnz CSS_Stop
CSS_Start:
    mov Run, #1
    mov errorflag, #0
    mov total_sec+0, #0
    mov total_sec+1, #0                   
    mov FSM1_STATE, #1                    
    mov SEC, #0
    mov PWM_Threshold, #100    
    lcall Beep_Long         
    sjmp CSS_WaitRel
CSS_Stop:
    mov Run, #0
    mov FSM1_STATE, #0
    mov SEC, #0
    mov errorflag, #0
    mov PWM_Threshold, #0                
    clr SSR_PIN
CSS_WaitRel:
    jnb PB_START_STOP, $                  
CSS_Ret: ret

;---------------------------------;
; ADC & Calculations              ;
;---------------------------------;
Read_Temperature:
    mov ADC_C, #0 
    lcall ADC_Wait
    mov val_lm4040+1, ADC_H
    mov val_lm4040+0, ADC_L
    
    mov ADC_C, #1 
    lcall ADC_Wait
    mov val_lm335+1, ADC_H
    mov val_lm335+0, ADC_L
    
    mov ADC_C, #2 
    lcall ADC_Wait
    mov val_op07+1, ADC_H
    mov val_op07+0, ADC_L

    ; Cold junction
    mov x+3, #0
    mov x+2, #0
    mov x+1, val_lm335+1
    mov x+0, val_lm335+0
    mov y+3, #0
    mov y+2, #0
    mov y+1, #10h
    mov y+0, #13h
    lcall mul32
    mov y+3, #0
    mov y+2, #0
    mov y+1, val_lm4040+1
    mov y+0, val_lm4040+0
    lcall div32
    Load_y(2730) 
    lcall sub32
    Load_y(10)   
    lcall div32
    mov temp_lm335+1, x+1
    mov temp_lm335+0, x+0

    ; Hot junction
    mov x+3, #0
    mov x+2, #0
    mov x+1, val_op07+1
    mov x+0, val_op07+0
    mov y+3, #0
    mov y+2, #0
    mov y+1, #01h
    mov y+0, #4Fh
    lcall mul32
    mov y+3, #0
    mov y+2, #0
    mov y+1, val_lm4040+1
    mov y+0, val_lm4040+0
    lcall div32
    mov temp_op07+1, x+1
    mov temp_op07+0, x+0
    
    ; Total
    mov x+3, #0
    mov x+2, #0
    mov x+1, temp_op07+1
    mov x+0, temp_op07+0
    mov y+3, #0
    mov y+2, #0
    mov y+1, temp_lm335+1
    mov y+0, temp_lm335+0
    lcall add32
    
    mov TEMP, x+0         
    lcall hex2bcd         
    ret

ADC_Wait:
    mov R2, #20
    djnz R2, $
    ret

Timer0_Init:
    mov a, TMOD
    anl a, #0F0h 
    orl a, #01h  
    mov TMOD, a
    mov TH0, #0F5h 
    mov TL0, #026h
    setb ET0 
    setb TR0 
    ret

Timer0_ISR:
    push acc
    push psw
    mov TH0, #0F5h
    mov TL0, #026h
    
    mov a, errorflag
    jnz PWM_Off   
    
    inc PWM_Count
    mov a, PWM_Count
    cjne a, #100, PWM_NW
    mov PWM_Count, #0
PWM_NW:
    mov a, PWM_Threshold
    jz  PWM_Off                 
    mov a, PWM_Count
    clr c
    subb a, PWM_Threshold             
    jc  PWM_On
PWM_Off:
    clr SSR_PIN
    sjmp Tick_Logic
PWM_On:
    setb SSR_PIN

Tick_Logic:
    inc Fast_Tick
    mov a, Fast_Tick
    cjne a, #200, Timer_Count
    mov Fast_Tick, #0
    setb refresh_flag

Timer_Count:
    mov a, Count1ms+0
    jnz Dec_Low
    mov a, Count1ms+1
    jnz Dec_High
    setb mf 
    mov Count1ms+0, #low(1000)
    mov Count1ms+1, #high(1000)
    mov a, Run
    jz ISR_Done
    inc total_sec+0
    mov a, total_sec+0
    jnz ISR_Done
    inc total_sec+1
    sjmp ISR_Done

Dec_High:
    dec Count1ms+1
    mov Count1ms+0, #0FFh
    sjmp ISR_Done
Dec_Low:
    dec Count1ms+0

ISR_Done:
    pop psw
    pop acc
    reti

;---------------------------------;
; Finite State Machine            ;
;---------------------------------;
COOL_TEMP EQU 60
HOT_TEMP  EQU 250
PWR_100   EQU 100
PWR_20    EQU 20

FSM_Update:
    mov a, FSM1_STATE
    jz FSM_S0_Jump
    cjne a, #1, FSM_S1_D
    ljmp FSM_S1
FSM_S1_D: cjne a, #2, FSM_S2_D
    ljmp FSM_S2
FSM_S2_D: cjne a, #3, FSM_S3_D
    ljmp FSM_S3
FSM_S3_D: cjne a, #4, FSM_S4_D
    ljmp FSM_S4
FSM_S4_D: ljmp FSM_S5
FSM_S0_Jump: ljmp FSM_S0

FSM_S0: mov PWM_Threshold, #0
    mov SEC, #0
    ret

FSM_S1: 
    mov a, total_sec+1
    jnz FSM_Check_Safe_Temp 
    mov a, total_sec+0
    cjne a, #60, FSM_S1_Time_Check
    sjmp FSM_Check_Safe_Temp 
FSM_S1_Time_Check:
    jnc FSM_Check_Safe_Temp 
    sjmp FSM_S1_Continue    

FSM_Check_Safe_Temp:
    mov a, TEMP
    cjne a, #50, FSM_Temp_Diff
    sjmp FSM_S1_Continue 
FSM_Temp_Diff:
    jnc FSM_S1_Continue  
    
    mov Run, #0
    mov FSM1_STATE, #0
    mov errorflag, #1
    clr SSR_PIN
    mov R7, #10           
    lcall Beep_Repeat    
    ret

FSM_S1_Continue:
    mov PWM_Threshold, #PWR_100
    mov SEC, #0
    mov R1, soak_temp+0
    mov R2, soak_temp+1
    lcall BCD3_To_Bin8
    mov R0, a                     
    mov a, TEMP
    clr c
    subb a, R0                    
    jc  FSM_Ret1
    mov FSM1_STATE, #2
    mov SEC, #0
    mov PWM_Threshold, #PWR_20
    ret
FSM_Ret1:
	ljmp FSM_Ret
	
FSM_S2: mov PWM_Threshold, #PWR_20
    inc SEC
    mov R1, soak_time+0
    mov R2, soak_time+1
    lcall BCD3_To_Bin8
    mov R0, a                     
    mov a, SEC
    clr c
    subb a, R0
    jc  FSM_Ret
    mov FSM1_STATE, #3
    mov SEC, #0
    mov PWM_Threshold, #PWR_100
    ret

FSM_S3: mov PWM_Threshold, #PWR_100
    mov SEC, #0
    mov R1, reflow_temp+0
    mov R2, reflow_temp+1
    lcall BCD3_To_Bin8
    mov R0, a                     
    mov a, TEMP
    clr c
    subb a, R0
    jc  FSM_Ret
    mov FSM1_STATE, #4
    mov SEC, #0
    mov PWM_Threshold, #PWR_20
    ret

FSM_S4: 
	mov PWM_Threshold, #PWR_20
    inc SEC
    mov a, TEMP
    clr c
    subb a, #HOT_TEMP
    jc FSM_S4_Continue 
    mov Run, #0
    mov FSM1_STATE, #0
    mov SEC, #0
    mov PWM_Threshold, #0
    mov errorflag, #1
    clr SSR_PIN  
    mov R7, #10
    lcall Beep_Repeat
    ret
     
FSM_S4_Continue: 
 	mov R1, reflow_time+0
    mov R2, reflow_time+1
    lcall BCD3_To_Bin8 
	mov R0, a                     
    mov a, SEC
    clr c
    subb a, R0
    jc  FSM_Ret  
    mov FSM1_STATE, #5
    mov SEC, #0
    mov PWM_Threshold, #0
    ret

FSM_S5: mov PWM_Threshold, #0
    mov a, TEMP
    clr c
    subb a, #COOL_TEMP
    jc  FSM_CoolDone             
    ret                             

FSM_CoolDone:
    mov FSM1_STATE, #0
    mov SEC, #0
    mov Run, #0
    clr SSR_PIN
FSM_Ret: ret

FSM_Update_With_Beep:
    mov a, FSM1_STATE
    mov FSM_LAST_STATE, a
    lcall FSM_Update
    mov a, FSM1_STATE
    cjne a, FSM_LAST_STATE, FUB_Changed
    ret
; FSM_Update_With_Beep_Changed
FUB_Changed: 
    mov a, FSM_LAST_STATE
    cjne a, #5, FUB_Generic_Beep
    mov a, FSM1_STATE
    jnz FUB_Generic_Beep 
    mov R7, #5
    lcall Beep_Repeat
    ret

FUB_Generic_Beep:
    lcall Beep_Long
    ret

Beep_Repeat:
    push AR7
Beep_Loop_Main:
    lcall Beep_Long
    lcall Wait500ms
    djnz R7, Beep_Loop_Main
    pop AR7
    ret

Beep_Long:
    push acc
    push AR0
    push AR1
    mov R1, #4       
B_Loop_Outer:
    mov R0, #250     
B_Loop_Inner:
    cpl SPEAKER_PIN
    lcall Wait1ms
    djnz R0, B_Loop_Inner
    djnz R1, B_Loop_Outer
    clr SPEAKER_PIN
    pop AR1
    pop AR0
    pop acc
    ret

Wait1ms:
    push AR0
    push AR1
    mov R0, #6
L1_1ms: mov R1, #230
L2_1ms: djnz R1, L2_1ms
    djnz R0, L1_1ms
    pop AR1
    pop AR0
    ret

Wait50ms:
    mov R0, #30
W50_L3: mov R1, #74
W50_L2: mov R2, #250
W50_L1: djnz R2, W50_L1 
    djnz R1, W50_L2 
    djnz R0, W50_L3 
    ret

Wait25ms:
    mov R0, #15
    sjmp W50_L3

Wait500ms:
    push AR0
    mov R0, #5
L_500:
    push AR0 
    mov R0, #100 
L_100: lcall Wait1ms
    djnz R0, L_100
    pop AR0
    djnz R0, L_500
    pop AR0
    ret

Init_Ports:
    mov P0MOD, #10111111B 
    mov P1MOD, #11010111B
    mov P2MOD, #00000011B 
    clr SPEAKER_PIN
    clr LEDR_PIN
    clr LEDG_PIN
    clr LEDB_PIN
    mov P3MOD, #00000000B
    ret

;---------------------------------;
; LCD User Interface              ;
;---------------------------------;
; Converts internal binary timer to BCD and ASCII
UI_Refresh_Runtime:
    mov a, SEC
    lcall Bin8_To_BCD3
    mov a, R6
    swap a
    orl  a, R5
    mov sec_bcd+0, a
    mov a, R7
    anl a, #0Fh
    mov sec_bcd+1, a
    mov a, FSM1_STATE
    add a, #30h
    mov stage_ch, a
    ret

; Updates top row of LCD, includes:
; Temperature, 3 digits followed by 'C'
; Stage time,  3 digits folowed by 'S'
; State,       current FSM state number
UI_Update_Line1:
    Set_Cursor(1, 1)
    mov a, bcd+1
    anl a, #0Fh
    orl a, #30h
    lcall ?WriteData
    mov a, bcd+0
    swap a
    anl a, #0Fh
    orl a, #30h
    lcall ?WriteData
    mov a, bcd+0
    anl a, #0Fh
    orl a, #30h
    lcall ?WriteData
    mov a, #'C'
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, sec_bcd+1
    anl a, #0Fh
    orl a, #30h
    lcall ?WriteData
    Display_BCD(sec_bcd+0)
    mov a, #'S'
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, stage_ch
    lcall ?WriteData
    ret

; Updates bottom row of LCD, includes:
; Total seconds, "Running" followed by 3 digits and 'S'
UI_Update_Line2:
    Set_Cursor(2, 1)
    mov a, Run
    jz  UI_L2_NR
    Send_Constant_String(#Str_Running)
    mov x+0, total_sec+0
    mov x+1, total_sec+1
    mov x+2, #0
    mov x+3, #0
    lcall hex2bcd
    mov a, bcd+1
    swap a
    anl a, #0Fh
    orl a, #30h
    lcall ?WriteData
    mov a, bcd+1
    anl a, #0Fh
    orl a, #30h
    lcall ?WriteData
    mov a, bcd+0
    swap a
    anl a, #0Fh
    orl a, #30h
    lcall ?WriteData
    mov a, bcd+0
    anl a, #0Fh
    orl a, #30h
    lcall ?WriteData
    mov a, #'s'
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    lcall ?WriteData
    ret
     
; UI Line 2 Not Running
; Idle state prompting "Select Variable"
UI_L2_NR:
    mov a, current_mode
    cjne a, #0xFF, UI_L2_V
    Send_Constant_String(#Str_Select)
    ret

; UI Line 2 Variable
; State where switch-controlled parameters are selected for editing
UI_L2_V:
    mov a, current_mode
    cjne a, #0, UI_L2_M1
    mov a,#'S'
    lcall ?WriteData
    mov a,#'o'
    lcall ?WriteData
    mov a,#'a'
    lcall ?WriteData
    mov a,#'k'
    lcall ?WriteData
    mov a,#'T'
    lcall ?WriteData
    mov a,#'='
    lcall ?WriteData
    ljmp UI_L2_P

; UI Line 2 Mode 1
UI_L2_M1: cjne a, #1, UI_L2_M2
    mov a,#'S'
    lcall ?WriteData
    mov a,#'o'
    lcall ?WriteData
    mov a,#'a'
    lcall ?WriteData
    mov a,#'k'
    lcall ?WriteData
    mov a,#'S'
    lcall ?WriteData
    mov a,#'='
    lcall ?WriteData
    ljmp UI_L2_P
    
; UI Line 2 Mode 2
UI_L2_M2: cjne a, #2, UI_L2_M3
    mov a,#'R'
    lcall ?WriteData
    mov a,#'e'
    lcall ?WriteData
    mov a,#'f'
    lcall ?WriteData
    mov a,#'l'
    lcall ?WriteData
    mov a,#'T'
    lcall ?WriteData
    mov a,#'='
    lcall ?WriteData
    ljmp UI_L2_P

; UI Line 2 Mode 3
UI_L2_M3: mov a,#'R'
    lcall ?WriteData
    mov a,#'e'
    lcall ?WriteData
    mov a,#'f'
    lcall ?WriteData
    mov a,#'l'
    lcall ?WriteData
    mov a,#'S'
    lcall ?WriteData
    mov a,#'='
    lcall ?WriteData
    
; UI Line 2 Print Parameter
; Common-mode code to print BCD numbers for any selected mode
UI_L2_P: mov a, current_bcd+1
    anl a, #0Fh
    orl a, #30h
    lcall ?WriteData
    Display_BCD(current_bcd+0)
    mov a, current_mode
    jb acc.0, UI_U_S
    mov a, #'C'
    sjmp UI_U_Out
    
; UI Unit Seconds
; Branch that prints 's' after the 3 digits
UI_U_S: mov a, #'s'

; UI Unit Output
; Clears remaining LCD trailing spaces
UI_U_Out: 
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    lcall ?WriteData
    lcall ?WriteData
    lcall ?WriteData
    lcall ?WriteData
    lcall ?WriteData
    ret

;---------------------------------;
; RGB LEDs Logic                  ;
;---------------------------------;
; Red   = Error
; Blue  = Cooling/Stage 5
; Green = Running
Update_LED:
	clr LEDR_PIN
    clr LEDG_PIN
    clr LEDB_PIN
    mov a, errorflag
    jz Cool_LED
    setb LEDR_PIN
    ret
Cool_LED:
	mov a, FSM1_STATE
	cjne a, #5, Run_LED
    setb LEDB_PIN
    ret 
Run_LED:
	mov a, Run
	jz Done_LED
	setb LEDG_PIN
Done_LED: 
	ret

;---------------------------------;
; HEX Displays User Interface     ;
;---------------------------------;
SevenSegLUT: 
    db 0C0h, 0F9h, 0A4h, 0B0h, 099h, 092h, 082h, 0F8h, 080h, 090h 
    db 088h, 083h, 0C6h, 0A1h, 086h, 08Eh 
SEG_BLANK EQU 0FFh

Get7Seg:
    mov dptr, #SevenSegLUT
    movc a, @a+dptr
    ret

UI_Update_HEX:
	mov a, errorflag
	jz UI_Normal_HEX
	lcall HEX_Error
	ret    
	
; Displays different data based on view_mode
UI_Normal_HEX:
    mov a, view_mode
    jz HEX_SRC_CUR
    cjne a, #1, HEX_SRC_RFL
    
; Soak temperature digits for display
HEX_SRC_SOAK:
    mov a, soak_temp+1
    anl a, #0Fh
    mov R7, a
    mov a, soak_temp+0
    swap a
    anl a, #0Fh
    mov R6, a
    mov a, soak_temp+0
    anl a, #0Fh
    mov R5, a
    mov R4, #0xC
    sjmp HEX_WRITE
    
; Current temperature digits for display
HEX_SRC_CUR:
    mov a, bcd+1
    anl a, #0Fh
    mov R7, a 
    mov a, bcd+0
    swap a
    anl a, #0Fh
    mov R6, a 
    mov a, bcd+0
    anl a, #0Fh
    mov R5, a 
    mov R4, #0xFF 
    sjmp HEX_WRITE
    
; Reflow temperature digits for display
HEX_SRC_RFL:
    mov a, reflow_temp+1
    anl a, #0Fh
    mov R7, a
    mov a, reflow_temp+0
    swap a
    anl a, #0Fh
    mov R6, a
    mov a, reflow_temp+0
    anl a, #0Fh
    mov R5, a
    mov R4, #0xC
    
; Calls Get7Seg and moves results to {HEX3:HEX0}
HEX_WRITE:
    mov a, R7
    lcall Get7Seg
    mov HEX3, a
    mov a, R6
    lcall Get7Seg
    mov HEX2, a
    mov a, R5
    lcall Get7Seg
    mov HEX1, a
    mov a, R4 
    cjne a, #0xFF, HEX_W_0
    mov HEX0, #SEG_BLANK
    sjmp HEX_W_Done
    
HEX_W_0: lcall Get7Seg
    mov HEX0, a
    
HEX_W_Done:
    mov HEX4, #SEG_BLANK
    mov HEX5, #SEG_BLANK
    ret
    
; Displays "Error" across {HEX4:HEX0} in fail state
HEX_Error:
	mov HEX5, #SEG_BLANK
	mov HEX4, #086h 
    mov HEX3, #0AFh 
    mov HEX2, #0AFh 
    mov HEX1, #0C5h 
    mov HEX0, #0AFh 
    ret

; Assigns mode based on which switch {SW3:SW0} is up
; 0,1,2,3, or 0xFF to register R3
Check_Switches:
    mov a, SWA
    anl a, #0x0F 
    jz Set_Default_Mode
    jb acc.0, Set_Mode_0
    jb acc.1, Set_Mode_1
    jb acc.2, Set_Mode_2
    jb acc.3, Set_Mode_3
    ret
    
Set_Default_Mode: mov R3, #0xFF 
    sjmp Check_Mode_Change
Set_Mode_0: mov R3, #0
    sjmp Check_Mode_Change
Set_Mode_1: mov R3, #1
    sjmp Check_Mode_Change
Set_Mode_2: mov R3, #2
    sjmp Check_Mode_Change
Set_Mode_3: mov R3, #3

; Save and swap sequence for comparing current mode and new mode from switches
Check_Mode_Change:
    mov a, current_mode
    cjne a, AR3, Do_Mode_Change 
    ret       

; Saves old data before loeading new data                            
Do_Mode_Change:
    mov a, current_mode
    cjne a, #0xFF, Save_Old_Data
    sjmp Load_New_Data
    
Save_Old_Data: lcall Save_Current_Val

Load_New_Data: mov current_mode, R3
    cjne R3, #0xFF, Load_Valid_Mode_Data
    ret
    
Load_Valid_Mode_Data: lcall Load_Saved_Val
    ret

; Saves entered 3-digit BCD number to one of the four selected modes
Save_Current_Val:
    mov a, current_mode
    cjne a, #0, Save_M1
    mov soak_temp+0, current_bcd+0
    mov soak_temp+1, current_bcd+1
    ret
    
Save_M1: cjne a, #1, Save_M2
    mov soak_time+0, current_bcd+0
    mov soak_time+1, current_bcd+1
    ret
    
Save_M2: cjne a, #2, Save_M3
    mov reflow_temp+0, current_bcd+0
    mov reflow_temp+1, current_bcd+1
    ret
    
Save_M3: mov reflow_time+0, current_bcd+0
    mov reflow_time+1, current_bcd+1
    ret

; Fetches stored values to display as BCD
Load_Saved_Val:
    mov current_bcd+0, #0
    mov current_bcd+1, #0
    mov a, current_mode
    cjne a, #0, Load_M1
    mov current_bcd+0, soak_temp+0
    mov current_bcd+1, soak_temp+1
    ret
    
Load_M1: cjne a, #1, Load_M2
    mov current_bcd+0, soak_time+0
    mov current_bcd+1, soak_time+1
    ret
    
Load_M2: cjne a, #2, Load_M3
    mov current_bcd+0, reflow_temp+0
    mov current_bcd+1, reflow_temp+1
    ret
    
Load_M3: mov current_bcd+0, reflow_time+0
    mov current_bcd+1, reflow_time+1
    ret

; Converts 3-digit BCD into a 8-bit binary
BCD3_To_Bin8:
    mov a, R1
    anl a, #0Fh
    mov R4, a 
    mov a, R1
    swap a
    anl a, #0Fh
    mov b, #10
    mul ab
    add a, R4
    mov R3, a 
    mov a, R2
    anl a, #0Fh
    mov b, #100
    mul ab
    add a, R3
    ret

; Converts 8-bit binary to hundereds, tens, and ones by performing repeated subtraction
Bin8_To_BCD3:
    mov R7, #0
    mov R6, #0
    mov R5, #0
    
B100: clr c
    subb a, #100
    jc B10
    inc R7
    sjmp B100
    
B10: add a, #100

B10_L: clr c
    subb a, #10
    jc B1
    inc R6
    sjmp B10_L
    
B1: add a, #10
    mov R5, a
    ret

; Scans for the mode and increment pushbuttons
UI_Check_Buttons:
    jb PB_MODE, UI_Mode_D             
    mov R2, #100
    djnz R2, $
    jb PB_MODE, UI_Mode_D
    inc view_mode
    mov a, view_mode
    cjne a, #3, UI_Mode_OK
    mov view_mode, #0
    
UI_Mode_OK: jnb PB_MODE, $

UI_Mode_D: jb PB_INC, UI_Inc_D
    mov R2, #100
    djnz R2, $
    jb PB_INC, UI_Inc_D
    mov a, Run
    jnz UI_Inc_D
    lcall UI_Inc_Pressed
    jnb PB_INC, $
    
UI_Inc_D: ret

; Increment button logic
; Clmaps to 250 degrees Celsius if >250
UI_Inc_Pressed:
    mov a, current_mode
    cjne a, #0xFF, UI_I_Do
    ret
    
UI_I_Do: mov a, current_mode
    jb acc.0, UI_I_Time
    lcall BCD_Inc_3Digit
    lcall Cap_Over250_To250
    ljmp Save_Current_Val
    
UI_I_Time: lcall BCD_Inc_3Digit
    ljmp Save_Current_Val

BCD_Inc_3Digit:
    mov a, current_bcd+0
    add a, #01h
    da a
    mov current_bcd+0, a
    jnc BCD_I_Done
    mov a, current_bcd+1
    anl a, #0Fh
    add a, #01h
    da a
    anl a, #0Fh
    mov current_bcd+1, a
    
BCD_I_Done: ret

Cap_Over250_To250:
    mov a, current_bcd+1
    anl a, #0Fh
    clr c
    subb a, #02h
    jc C_OK
    jnz C_Do
    mov a, current_bcd+0
    clr c
    subb a, #051h
    jc C_OK
    
C_Do: mov current_bcd+1, #02h
    mov current_bcd+0, #050h
    
C_OK: ret

UI_Tick_Blink:
    inc blink_counter
    mov a, blink_counter
    cjne a, #10, UIB_Done
    mov blink_counter, #0
    cpl blink_on
    
UIB_Done: ret

CHECK_COLUMN MAC
    jb %0, CHECK_COL_%M
    mov R7, %1
    jnb %0, $ 
    setb c
    ret
CHECK_COL_%M:
ENDMAC

;---------------------------------;
; Keypad Scanning Routine         ;
;---------------------------------;
; Numbers 0-9
; '*' to delete/backspace
; Characters A-D, '#' disabled
Keypad:
    clr ROW1
    clr ROW2
    clr ROW3
    clr ROW4
    mov c, COL1
    anl c, COL2
    anl c, COL3
    anl c, COL4
    jnc K_Debounce
    clr c
    ret
    
K_Debounce:
    lcall Wait25ms
    mov c, COL1
    anl c, COL2
    anl c, COL3
    anl c, COL4
    jnc K_Code
    clr c
    ret
    
K_Code:      
    setb ROW1
    setb ROW2
    setb ROW3
    setb ROW4
    clr ROW1
    CHECK_COLUMN(COL1, #01H)
    CHECK_COLUMN(COL2, #02H)
    CHECK_COLUMN(COL3, #03H)
    CHECK_COLUMN(COL4, #0AH)
    setb ROW1
    clr ROW2
    CHECK_COLUMN(COL1, #04H)
    CHECK_COLUMN(COL2, #05H)
    CHECK_COLUMN(COL3, #06H)
    CHECK_COLUMN(COL4, #0BH)
    setb ROW2
    clr ROW3
    CHECK_COLUMN(COL1, #07H)
    CHECK_COLUMN(COL2, #08H)
    CHECK_COLUMN(COL3, #09H)
    CHECK_COLUMN(COL4, #0CH)
    setb ROW3
    clr ROW4
    CHECK_COLUMN(COL1, #0EH) 
    CHECK_COLUMN(COL2, #00H) 
    CHECK_COLUMN(COL3, #0FH) 
    CHECK_COLUMN(COL4, #0DH) 
    setb ROW4
    clr c
    ret

MYRLC MAC
    mov a, %0
    rlc a
    mov %0, a
ENDMAC

Shift_Digits_Left:
    mov R0, #4 
S_L0: clr c
    MYRLC(current_bcd+0)
    MYRLC(current_bcd+1)
    djnz R0, S_L0
    mov a, R7
    orl a, current_bcd+0
    mov current_bcd+0, a
    mov a, current_bcd+1
    anl a, #0x0F
    mov current_bcd+1, a
    ret

MYRRC MAC
    mov a, %0
    rrc a
    mov %0, a
ENDMAC

Shift_Digits_Right:
    mov R0, #4 
S_R0: clr c
    MYRRC(current_bcd+1)
    MYRRC(current_bcd+0)
    djnz R0, S_R0
    ret

END
