; wAx - Wedge Assembler/Disassembler
* = $a000

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
; LABEL DEFINITIONS
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
; Configuration
ACHAR       = $40               ; Wedge character @ for assembly
DCHAR       = $24               ; Wedge character $ for disassembly
MCHAR       = $26               ; Wedge character & for memory dump
QUOTE       = $22               ; Quote character
DA_LINES    = $10               ; Disassemble this many lines of code
DA_BUFFER   = $0230             ; Disassembly buffer
A_BUFFER    = $0248             ; Assembly buffer

; System resources
IGONE       = $0308             ; Vector to GONE
CBINV       = $0316             ; BRK vector
GONE        = $c7e4
CHRGET      = $0073
BUF         = $0200             ; Input buffer
PRTSTR      = $cb1e             ; Print from data (Y,A)
CHROUT      = $ffd2
BUFPTR      = $7a               ; Pointer to buffer
CHARAC      = $07               ; Temporary character
CURLIN      = $39               ; Current BASIC line number

; Constants
; Addressing mode encodings
INDIRECT    = $10               ; e.g., JMP ($0306)
INDIRECT_X  = $20               ; e.g., STA ($1E,X)
INDIRECT_Y  = $30               ; e.g., CMP ($55),Y
ABSOLUTE    = $40               ; e.g., JSR $FFD2
ABSOLUTE_X  = $50               ; e.g., STA $1E00,X
ABSOLUTE_Y  = $60               ; e.g., LDA $8000,Y
ZEROPAGE    = $70               ; e.g., BIT $A2
ZEROPAGE_X  = $80               ; e.g., CMP $00,X
ZEROPAGE_Y  = $90               ; e.g., LDX $FA,Y
IMMEDIATE   = $a0               ; e.g., LDA #$2D
IMPLIED     = $b0               ; e.g., INY
RELATIVE    = $c0               ; e.g., BCC $181E

; Other constant
TABLE_END   = $ff               ; Indicates the end of mnemonic table

; Assembler workspace
WORK        = $a4               ; Temporary workspace (2 bytes)
LANG_PTR    = $a6               ; Language Pointer (2 bytes)
FUNCTION    = $a8               ; Current function (ACHAR, DCHAR)
BUFFER      = $a9               ; Buffer index
INSTDATA    = $aa               ; Instruction data (2 bytes)
PRGCTR      = $ac               ; PRGCTR assembly address (2 bytes)
OPCODE      = $ae               ; Assembly target for hypotesting
OPERAND     = $af               ; Operand storage (2 bytes)
RB_OPERAND  = $b1               ; Hypothetical relative branch operand
                            
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
; INSTALLER
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
Install:    lda #<Scan
            sta IGONE
            lda #>Scan
            sta IGONE+1
            
            lda #<Break
            sta CBINV
            lda #>Break
            sta CBINV+1
            
            lda #<Intro
            ldy #>Intro
            jsr PRTSTR
            rts
            
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
; MAIN PROGRAM
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;              
Scan:       jsr CHRGET
            cmp #DCHAR          ; Disassemble with $
            beq Prepare
            cmp #ACHAR          ; Assemble with @
            beq Prepare
            cmp #MCHAR          ; Memory dump
            beq Prepare
            jmp GONE+3          ; +3 because jsr CHRGET is done

Prepare:    tay                 ; Y = the wedge character for function dispatch
            ldx #$00            ; wAx is to be zeropage-neutral, so preserve
-loop:      lda WORK,x          ;   its workspace on the stack. When this
            pha                 ;   routine is done, put the data back
            inx                 ;   ,,
            cpx #$0e            ;   ,,
            bne loop            ;   ,,

; Get PRGCTR address from the first four characters after the wedge
GetAddr:    jsr Buff2Byte       ; Convert 2 characters to a byte
            sta PRGCTR+1        ; Save to the PRGCTR high byte
            jsr Buff2Byte       ; Convert next 2 characters to byte
            sta PRGCTR          ; Save to the PRGCTR low byte

; Dispatch Functions
; Based on the wedge character detected
Dispatch:   sty FUNCTION            ; Store the mode (to normalize spaces in buffer)
            cpy #DCHAR          ; Dispatch Disassembler
            beq Disp_Dasm
            cpy #ACHAR          ; Dispatch Assembler
            beq Disp_Asm
            cpy #MCHAR          ; Dispatch Memory dump
            beq Disp_Mem
            
; Dispatch Disassembler            
Disp_Dasm:  ldx #DA_LINES       ; Show this many lines of code
-loop:      txa
            pha
            jsr Disasm          ; Disassmble the code at the program counter
            jsr PrintBuff       ; Display the buffer
            lda #$0d            ; Carriage return after each instruction
            jsr CHROUT          ; ,,
            pla                 ; Restore X
            tax                 ; ,,
            dex
            bne loop
            jmp Return    
            
; Dispatch Memory Dump            
Disp_Mem:   ldx #DA_LINES       ; Show this many groups of four
-loop:      txa
            pha
            jsr Memory
            jsr PrintBuff
            pla
            tax
            dex
            bne loop
            jmp Return                    
            
; Dispatch Assembler
Disp_Asm:   lda #$00            ; Reset the buffer index
            sta BUFFER          ; ,,
            jsr CHRGET          ; The first character after the address must
            cmp #QUOTE          ;   be a double quote
            bne AsmFail
-loop       jsr CHRGET          ; Transcribe characters to the assembler buffer
            cmp #QUOTE          ;   until either a dollar sign or quote is
            beq test            ;   found. The dollar sign moves to operand
            jsr Transcribe      ;   parsing, while the quote moves right to
            cmp #"$"            ;   hypotesting, as it is implied/acc mode
            beq continue        ;   ,,
            cmp #$00            ; $00 means we ran out of characters,  
            beq AsmFail         ;   so fail
            bne loop
continue:   jsr GetOperand      ; Once $ is found, then grab the operand
-loop       jsr CHRGET
            cmp #QUOTE          ; Look for a double quote to end the line
            beq test            ; ,,
            cmp #$00            ; Or fail if there's no closing quote         
            beq AsmFail         ; ,,
            jsr Transcribe
            jmp loop
test:       lda #$00            ; End the buffer with a $00
            jsr Transcribe      ; ,,
            jsr Hypotest        ; Line is done; hypothesis test for a match
            bcc AsmFail
            ldy #$00            ; A match was found. Transcribe the good code
            lda OPCODE          ;   to the program counter. The number of bytes
            sta (PRGCTR),y      ;   to transcribe is stored in the FUNCTION memory
            ldx FUNCTION        ;   location.
            cpx #$02            ;
            bcc Return
            lda OPERAND         ; Store the low operand byte, if indicated
            iny
            sta (PRGCTR),y
            cpx #$03
            bcc Return
            lda OPERAND+1       ; Store the high operand byte, if indicated
            iny
            sta (PRGCTR),y
            lda CURLIN+1
            jmp Return
            
; Assembly Fail
; Invalid opcode or formatting
; Falls through to Return
AsmFail     lda #"?"
            jsr CHROUT             
            
; Return from Wedge
Return:     ldx #$0d            ; Restore working space to its original state
-loop:      pla                 ;   from the stack (see Prepare)
            sta WORK,x          ;   ,,
            dex                 ;   ,,
            bpl loop            ;   ,,
readout:    jsr CHRGET          ; Read through any extra nonzero bytes in the
            bne readout         ;   buffer, to prevent ?SYNTAX ERROR
            jmp GONE+3          ; Continue parsing with IGONE

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
; DISASSEMBLER COMPONENTS
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
Disasm:     lda #$00            ; Reset the buffer index
            sta BUFFER          ; ,,
            lda #ACHAR          ; If we're in Assembler mode, don't include
            cmp FUNCTION        ; the address in the buffer
            beq op_start        ; ,,
            lda #DCHAR          ; Start each line with the wedge character, so
            jsr BuffWrt         ;   the user can chain commands
            jsr Address
op_start:   ldy #$00            ; Get the opcode
            lda (PRGCTR),y      ;   ,,
            jsr Lookup          ; Look it up
            jsr Mnemonic
            lda #$00            ; Write $00 to the buffer for printing
            jsr BuffWrt         ;   purposes
            jsr NextValue       ; Advance to the next line of code
            rts
            
; Write Mnemonic and Parameters
Mnemonic:   bcc unknown
            ldx INSTDATA
            lda Tuplet,x
            jsr BuffWrt
            lda Tuplet+1,x
            jsr BuffWrt
            lda INSTDATA+1
            and #$0f
            tax
            lda Char3,x
            jsr BuffWrt
            jsr Parameter
            rts
unknown:    lda #"?"
            jsr BuffWrt
            rts

; Parameter Display
; Dispatch display routines based on addressing mode
Parameter:  lda INSTDATA+1
            and #$f0            ; Isolate addressing mode
            cmp #IMPLIED
            beq DisImp
            pha
            jsr Space           ; There's a space after all other mnemonics
            pla
            cmp #RELATIVE
            beq DisRel
            cmp #IMMEDIATE
            beq DisImm
            cmp #ZEROPAGE
            bcs DisZP
            cmp #ABSOLUTE
            bcs DisAbs
            jmp DisInd

; Disassemble Implied
DisImp:     rts
            
; Disassemble Immediate            
DisImm:     lda #"#"
            jsr BuffWrt
            jsr Param_8
            rts

DisZP:      pha
            jsr Param_8
            pla
            sec
            sbc #ZEROPAGE
            jmp draw_xy         ; From this point, it's the same as Absolute            

DisRel:     jsr HexPrefix
            jsr NextValue       ; Get the operand of the instruction, advance
                                ;   the program counter. It might seem weird to
                                ;   advance the PC when we're operating on it a
                                ;   few lines down, but we need to add two
                                ;   bytes to get the offset to the right spot.
                                ;   One of those bytes is here, and the other
                                ;   comes from setting the Carry flag before
                                ;   the addition below
            sta WORK
            and #$80            ; Get the sign of the operand
            beq sign
            ora #$ff            ; Extend the sign out to 16 bits, if negative
sign:       sta WORK+1          ; Set the high byte to either $00 or $ff
            lda WORK
            sec
            adc PRGCTR
            sta WORK
            lda WORK+1
            adc PRGCTR+1
            jsr Hex             ; No need to save the high byte, just show it
            lda WORK            ; Show the low byte of the computed address
            jsr Hex             ; ,,
            rts
                            
; Disassemble Absolute            
DisAbs:     pha                 ; Save addressing mode for use later
            jsr Param_16
            pla
            sec
            sbc #ABSOLUTE
draw_xy:    ldx #"X"
            cmp #$10
            beq abs_ind
            ldx #"Y"
            cmp #$20
            beq abs_ind
            rts
abs_ind:    lda #","            ; This is an indexed addressing mode, so
            jsr BuffWrt         ;   write a comma and index register
            txa                 ;   ,,
            jsr BuffWrt         ;   ,,
            rts                      

; Disassemble Indirect 
DisInd:     pha
            lda #"("
            jsr BuffWrt
            pla
            cmp #INDIRECT
            bne ind_xy
            jsr Param_16
            lda #")"
            jsr BuffWrt
            rts
ind_xy:     pha
            jsr Param_8
            pla
            cmp #INDIRECT_X
            bne ind_y
            lda #","
            jsr BuffWrt
            lda #"X"
            jsr BuffWrt
            lda #")"
            jsr BuffWrt
            rts
ind_y:      lda #")"
            jsr BuffWrt
            lda #","
            jsr BuffWrt
            lda #"Y"
            jsr BuffWrt
            rts 
            
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
; ASSEMBLER COMPONENTS
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Get Operand
; Populate the operand for an instruction by looking forward in the buffer and
; counting upcoming hex digits.
GetOperand: ldy #$00            ; Valid number count
            sty OPERAND         ; Initialize operand
            sty OPERAND+1       ; ,,
            lda BUFPTR          ; Save the buffer pointer for backtracking
            pha
-loop:      jsr CHRGET          ; Count number of hex characters in the buffer
            jsr Char2Nyb        ; ,,
            cmp #TABLE_END      ; Once we reach a non-hex character, the
            bcs counted         ;   count is over
            iny
            bne loop
counted:    pla                 ; Backtrack to read and store the hex digits
            sta BUFPTR          ; ,,
            cpy #$02            ; Y can be 2 (one byte) or 4 (two bytes)
            beq found1          ; ,,
            cpy #$04            ; ,,
            bne getop_r         ; ,,
found2:     jsr Buff2Byte       ; Four characters were found; Put the byte value
            sta OPERAND+1       ;   of two in the high byte of the operand
found1:     jsr Buff2Byte       ; Get two characters for the operand low byte
            sta OPERAND         ; ,,
            sec                 ; Subtract the program counter address
            sbc PRGCTR          ;   from the instruction target to
            sec                 ;   get the relative branch's operand.
            sbc #$02            ; Offset by 2 to account for the instruction
            sta RB_OPERAND      ; Save the hypothetical relative branch operand
getop_r:    rts    

; Hypothesis Test
; Search through
Hypotest:   lda PRGCTR+1        ; Save the program counter from the assembler
            pha                 ;   so it can be used by the disassembler
            lda PRGCTR
            pha
            jsr ResetLang       ; Reset language table
reset:      lda #OPCODE         ; Write location to PC for hypotesting
            sta PRGCTR          ; ,,
            ldy #$00            ; Set the program counter high byte
            sty PRGCTR+1        ; ,,
            lda (LANG_PTR),y    ; A is this language entry's opcode
            cmp #TABLE_END      ; If the table has ended, leave the
            beq bad_code        ;   hypotesting routine
            sta OPCODE          ; Store it in the hypotesting location
            jsr Disasm          ; Disassemble using the opcode
            lda INSTDATA+1      ; This is a relative branch instruction, and
            and #$f0            ;   these are handled differently. See below
            cmp #RELATIVE       ;   ,,
            beq test_rel        ;   ,,
            ldy #$00
-loop:      lda DA_BUFFER,y     ; Compare the assembly with the disassembly
            cmp A_BUFFER,y      ;   in the buffer
            bne differ          ; If any bytes don't match, then quit
            iny
            cpy BUFFER
            bne loop            ; Loop until the buffer is done
match:      lda PRGCTR          ; Set the FUNCTION location to the number of
            sec                 ;   bytes that need to be transcribed
            sbc #OPCODE         ;   ,,
            sta FUNCTION        ;   ,,
            pla                 ; Restore the program counter so that the
            sta PRGCTR          ;   instruction is transcribed to the
            pla                 ;   right place
            sta PRGCTR+1        ;   ,,
            sec                 ; Set Carry flag to indicate success
            rts
differ:     jsr AdvLang         ; Advance the counter
            jmp reset
test_rel:   ldy #$02            ; Here, relative branching instructions are
-loop:      lda DA_BUFFER,y     ;   handled. Only the first three characters
            cmp A_BUFFER,y      ;   are compared. If there's a match on the
            bne differ          ;   instruction name, then move the computed
            dey                 ;   relative operand into the regular operand
            bpl loop            ;   low byte, and then treat this as a regular
            lda RB_OPERAND      ;   match after that
            sta OPERAND         ;   ,,
            jmp match           ;   ,,
bad_code:   pla                 ; Pull the program counter off the stack, but
            pla                 ;   there's no need to do anything with it
            clc                 ;   because we're giving up.
            rts
            
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
; MEMORY DUMP COMPONENTS
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
Memory:     lda #$00
            sta BUFFER
            lda #MCHAR          ; Start each line with the wedge character, so
            jsr BuffWrt         ;   the user can chain commands
            jsr Address
            ldy #$00
-loop:      lda (PRGCTR),y
            jsr Hex
            jsr Space
            iny
            cpy #$04
            bne loop
            tya
            clc
            adc PRGCTR
            sta PRGCTR
            lda #$00
            adc PRGCTR+1
            sta PRGCTR+1
            lda #$0d
            jsr BuffWrt
            rts
                                    
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
; SUBROUTINES
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; 
; Look Up Opcode             
Lookup:     sta INSTDATA        ; Store the requested opcode for lookup
            jsr ResetLang       ; Reset language table
-loop:      ldy #$00            ; Look at the first of three bytes in a table
            lda (LANG_PTR),y
            cmp #TABLE_END
            beq not_found
            cmp INSTDATA
            beq found
            jsr AdvLang         ; Not found; advance to next entry and look
            bne loop            ;   again
not_found:  clc                 ; Opcode not found; clear Carry flag to
            rts                 ;   indicate unknown opcode
found:      iny                 ; The opcode has been found; store the
            lda (LANG_PTR),y    ;   mnemonic and addressing mode information
            sta INSTDATA        ;   to draw the instruction
            iny                 ;   ,,
            lda (LANG_PTR),y    ;   ,,
            sta INSTDATA+1      ;   ,,
            sec                 ; Set Carry flag to indicate successful lookup
            rts   
            
; Reset Language Table            
ResetLang:  lda #<LangTable
            sta LANG_PTR
            lda #>LangTable
            sta LANG_PTR+1
            rts
            
; Advance Language Table
; to next entry
AdvLang:    lda #$03
            clc
            adc LANG_PTR
            sta LANG_PTR
            lda #$00
            adc LANG_PTR+1
            sta LANG_PTR+1 
            rts

; Buffer to Byte
; Y is the index of the first character of the byte in the text
; buffer, to be returned as a byte in the Accumulator
Buff2Byte:  jsr CHRGET
            jsr Transcribe
            jsr Char2Nyb        ; The first nybble at the index is
            asl                 ;   the high one, multipled by 16
            asl                 ;   ,,
            asl                 ;   ,,
            asl                 ;   ,,
            sta WORK
            jsr CHRGET          ; Get the next character, which is
            jsr Transcribe
            jsr Char2Nyb        ;   the low nybble, and combine the
            ora WORK            ;   nybbles
            rts
       
; Character to Nybble
; A is the character in the text buffer to be converted into a nybble
Char2Nyb:   ldx #$0f
-loop:      cmp HexDigit,x
            beq found_dig
            dex
            bpl loop
            lda #TABLE_END
            rts
found_dig:  txa
            rts            

; Next Program Counter
; Advance Program Counter by one byte, and return its value
NextValue:  inc PRGCTR
            bne next_r
            inc PRGCTR+1
next_r:     ldy #$00
            lda (PRGCTR),y
            rts

; Show Hex Prefix
HexPrefix:  lda #"$"
            jsr BuffWrt
            rts

; Show Space           
Space:      lda #" "
            jsr BuffWrt
            rts
            
; Write Address to Buffer            
Address:    lda PRGCTR+1        ; Show the address
            jsr Hex             ; ,,
            lda PRGCTR          ; ,,
            jsr Hex             ; ,,
            jsr Space
            rts

; Show Hex Byte
Hex:        pha
            lsr
            lsr
            lsr
            lsr
            tax
            lda HexDigit,x
            jsr BuffWrt
            pla
            and #$0f
            tax
            lda HexDigit,x
            jsr BuffWrt
            rts
 
; Show 8-bit Parameter           
Param_8:    jsr HexPrefix
            jsr NextValue 
            jsr Hex            
            rts
            
; Show 16-Bit Parameter            
Param_16:   jsr HexPrefix
            jsr NextValue 
            pha
            jsr NextValue 
            jsr Hex
            pla
            jsr Hex
            rts
            
BuffWrt:    sta CHARAC          ; Save temporary character
            lda #ACHAR          ; If wAx is in Assembler mode, then
            cmp FUNCTION        ;   ignore spaces in the buffer
            bne write_ok        ;   ,,
            lda #" "            ;   ,,
            cmp CHARAC          ;   ,,
            beq write_r         ;   ,,
write_ok:   tya                 ; Save registers
            pha                 ; ,,
            txa                 ; ,,
            pha                 ; ,,
            ldx BUFFER          ; Write to the next buffer location
            lda CHARAC          ; ,,
            sta DA_BUFFER,x     ; ,,
            inc BUFFER          ; ,,
            pla                 ; Restore registers
            tax                 ; ,,
            pla                 ; ,,
            tay                 ; ,,
write_r:    rts 

; Transcribe to Buffer
; Add A to assembler buffer, and advance buffer counter
Transcribe: ldx BUFFER
            sta A_BUFFER,x
            inc BUFFER
            rts 
            
PrintBuff:  lda #$00            ; End the buffer with 0
            jsr BuffWrt         ; ,,
            lda #<DA_BUFFER     ; Print the line
            ldy #>DA_BUFFER     ; ,,
            jsr PRTSTR          ; ,,
            rts            
            
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
; BREAK ROUTINE
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
Break:      pha                 ; Right to left in the table: Accumulator
            tya                 ; Y
            pha
            txa                 ; X
            pha
            tsx                 ; Stack
            txa
            clc                 ; For the stack register, compensate for the
            adc #$04            ;   four bytes that the report used
            pha
            php                 ; Processor status
            lda #$00            ; Clear the buffer
            sta BUFFER
            lda #<Registers     ; Print register indicator bar
            ldy #>Registers     ; ,,
            jsr PRTSTR          ; ,,
            ldy #$05            ; Pull five values off the stack and add
-loop:      pla                 ;   each one to the buffer
            jsr Hex             ;   ,,
            jsr Space           ;   ,,
            dey                 ;   ,,
            bne loop            ;   ,,
            jsr PrintBuff       ; Print the buffer
            jmp ($C002)
            
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;  
; DATA
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Each instruction is encoded as three bytes.
; (1) The first byte is the 6502 opcode of the instruction
; (2) The second byte is the position of the first two characters of the 
;     instruction in the Tuple table
; (3) The third byte's low nybble is the position of the third character of
;     the instruction in the Char3 table. The high nybble is the addressing
;     mode of the insruction, as shown in the Constants labels at the top
;     of the source code
;
LangTable:  .byte $69,$09,$a1   ; ADC #oper
            .byte $65,$09,$71   ; ADC oper
            .byte $75,$09,$81   ; ADC oper,X
            .byte $6d,$09,$41   ; ADC oper
            .byte $7d,$09,$51   ; ADC oper,X
            .byte $79,$09,$61   ; ADC oper,Y
            .byte $61,$09,$21   ; ADC (oper,X)
            .byte $71,$09,$31   ; ADC (oper),Y
            .byte $29,$06,$a2   ; AND #oper
            .byte $25,$06,$72   ; AND oper
            .byte $35,$06,$82   ; AND oper,X
            .byte $2d,$06,$42   ; AND oper
            .byte $3d,$06,$52   ; AND oper,X
            .byte $39,$06,$62   ; AND oper,Y
            .byte $21,$06,$22   ; AND (oper,X)
            .byte $31,$06,$32   ; AND (oper),Y
            .byte $0a,$00,$b6   ; ASL A
            .byte $06,$00,$76   ; ASL oper
            .byte $16,$00,$86   ; ASL oper,X
            .byte $0e,$00,$46   ; ASL oper
            .byte $1e,$00,$56   ; ASL oper,X
            .byte $90,$19,$c1   ; BCC oper
            .byte $b0,$19,$ca   ; BCS oper
            .byte $f0,$28,$c8   ; BEQ oper
            .byte $24,$25,$7b   ; BIT oper
            .byte $2c,$25,$4b   ; BIT oper
            .byte $30,$10,$c4   ; BMI oper
            .byte $d0,$1d,$c3   ; BNE oper
            .byte $10,$0c,$c6   ; BPL oper
            .byte $00,$2c,$b5   ; BRK
            .byte $50,$2a,$c1   ; BVC oper
            .byte $70,$2a,$ca   ; BVS oper
            .byte $18,$1a,$b1   ; CLC
            .byte $d8,$1a,$b2   ; CLD
            .byte $58,$1a,$b4   ; CLI
            .byte $b8,$1a,$bc   ; CLV
            .byte $c9,$14,$a7   ; CMP #oper
            .byte $c5,$14,$77   ; CMP oper
            .byte $d5,$14,$87   ; CMP oper,X
            .byte $cd,$14,$47   ; CMP oper
            .byte $dd,$14,$57   ; CMP oper,X
            .byte $d9,$14,$67   ; CMP oper,Y
            .byte $c1,$14,$27   ; CMP (oper,X)
            .byte $d1,$14,$37   ; CMP (oper),Y
            .byte $e0,$16,$ad   ; CPX #oper
            .byte $e4,$16,$7d   ; CPX oper
            .byte $ec,$16,$4d   ; CPX oper
            .byte $c0,$16,$ae   ; CPY #oper
            .byte $c4,$16,$7e   ; CPY oper
            .byte $cc,$16,$4e   ; CPY oper
            .byte $c6,$0a,$71   ; DEC oper
            .byte $d6,$0a,$81   ; DEC oper,X
            .byte $ce,$0a,$41   ; DEC oper
            .byte $de,$0a,$51   ; DEC oper,X
            .byte $ca,$0a,$bd   ; DEX
            .byte $88,$0a,$be   ; DEY
            .byte $49,$02,$a9   ; EOR #oper
            .byte $45,$02,$79   ; EOR oper
            .byte $55,$02,$89   ; EOR oper,X
            .byte $4d,$02,$49   ; EOR oper
            .byte $5d,$02,$59   ; EOR oper,X
            .byte $59,$02,$69   ; EOR oper,Y
            .byte $41,$02,$29   ; EOR (oper,X)
            .byte $51,$02,$39   ; EOR (oper),Y
            .byte $e6,$26,$71   ; INC oper
            .byte $f6,$26,$81   ; INC oper,X
            .byte $ee,$26,$41   ; INC oper
            .byte $fe,$26,$51   ; INC oper,X
            .byte $e8,$26,$bd   ; INX
            .byte $c8,$26,$be   ; INY
            .byte $4c,$1f,$47   ; JMP oper
            .byte $6c,$1f,$17   ; JMP (oper)
            .byte $20,$2f,$49   ; JSR oper
            .byte $a9,$1b,$a0   ; LDA #oper
            .byte $a5,$1b,$70   ; LDA oper
            .byte $b5,$1b,$80   ; LDA oper,X
            .byte $ad,$1b,$40   ; LDA oper
            .byte $bd,$1b,$50   ; LDA oper,X
            .byte $b9,$1b,$60   ; LDA oper,Y
            .byte $a1,$1b,$20   ; LDA (oper,X)
            .byte $b1,$1b,$30   ; LDA (oper),Y
            .byte $a2,$1b,$ad   ; LDX #oper
            .byte $a6,$1b,$7d   ; LDX oper
            .byte $b6,$1b,$9d   ; LDX oper,Y
            .byte $ae,$1b,$4d   ; LDX oper
            .byte $be,$1b,$6d   ; LDX oper,Y
            .byte $a0,$1b,$ae   ; LDY #oper
            .byte $a4,$1b,$7e   ; LDY oper
            .byte $b4,$1b,$8e   ; LDY oper,X
            .byte $ac,$1b,$4e   ; LDY oper
            .byte $bc,$1b,$5e   ; LDY oper,X
            .byte $4a,$0e,$b9   ; LSR A
            .byte $46,$0e,$79   ; LSR oper
            .byte $56,$0e,$89   ; LSR oper,X
            .byte $4e,$0e,$49   ; LSR oper
            .byte $5e,$0e,$59   ; LSR oper,X
            .byte $ea,$07,$b7   ; NOP
            .byte $09,$03,$a0   ; ORA #oper
            .byte $05,$03,$70   ; ORA oper
            .byte $15,$03,$80   ; ORA oper,X
            .byte $0d,$03,$40   ; ORA oper
            .byte $1d,$03,$50   ; ORA oper,X
            .byte $19,$03,$60   ; ORA oper,Y
            .byte $01,$03,$20   ; ORA (oper,X)
            .byte $11,$03,$30   ; ORA (oper),Y
            .byte $48,$17,$b0   ; PHA
            .byte $08,$17,$b7   ; PHP
            .byte $68,$0d,$b0   ; PLA
            .byte $28,$0d,$b7   ; PLP
            .byte $2a,$2d,$b6   ; ROL A
            .byte $26,$2d,$76   ; ROL oper
            .byte $36,$2d,$86   ; ROL oper,X
            .byte $2e,$2d,$46   ; ROL oper
            .byte $3e,$2d,$56   ; ROL oper,X
            .byte $6a,$2d,$b9   ; ROR A
            .byte $66,$2d,$79   ; ROR oper
            .byte $76,$2d,$89   ; ROR oper,X
            .byte $6e,$2d,$49   ; ROR oper
            .byte $7e,$2d,$59   ; ROR oper,X
            .byte $40,$04,$b4   ; RTI
            .byte $60,$04,$ba   ; RTS
            .byte $e9,$0f,$a1   ; SBC #oper
            .byte $e5,$0f,$71   ; SBC oper
            .byte $f5,$0f,$81   ; SBC oper,X
            .byte $ed,$0f,$41   ; SBC oper
            .byte $fd,$0f,$51   ; SBC oper,X
            .byte $f9,$0f,$61   ; SBC oper,Y
            .byte $e1,$0f,$21   ; SBC (oper,X)
            .byte $f1,$0f,$31   ; SBC (oper),Y
            .byte $38,$01,$b1   ; SEC
            .byte $f8,$01,$b2   ; SED
            .byte $78,$01,$b4   ; SEI
            .byte $85,$22,$70   ; STA oper
            .byte $95,$22,$80   ; STA oper,X
            .byte $8d,$22,$40   ; STA oper
            .byte $9d,$22,$50   ; STA oper,X
            .byte $99,$22,$60   ; STA oper,Y
            .byte $81,$22,$20   ; STA (oper,X)
            .byte $91,$22,$30   ; STA (oper),Y
            .byte $86,$22,$7d   ; STX oper
            .byte $96,$22,$9d   ; STX oper,Y
            .byte $8e,$22,$4d   ; STX oper
            .byte $84,$22,$7e   ; STY oper
            .byte $94,$22,$8e   ; STY oper,X
            .byte $8c,$22,$4e   ; STY oper
            .byte $aa,$05,$bd   ; TAX
            .byte $a8,$05,$be   ; TAY
            .byte $ba,$21,$bd   ; TSX
            .byte $8a,$12,$b0   ; TXA
            .byte $9a,$12,$ba   ; TXS
            .byte $98,$23,$b0   ; TYA
            .byte TABLE_END     ; End of 6502 table

Tuplet:     .asc "ASEORTANOADEBPLSBMTXCMCPHBCLDBNJMTSTYBINBEBVBROJS"
Char3:      .asc "ACDEIKLPQRSTVXY"
HexDigit:   .asc "0123456789ABCDEF"
Intro:      .asc $0d,"WAX ON",$00
Registers:  .asc $0d,"P: S: X: Y: A:",$0d,$00
Breakpoint: .asc $00,$00,$00