;*********************************************************************
;                                                                     
;                           Objective Caml                            
;
;            Xavier Leroy, projet Cristal, INRIA Rocquencourt         
;
;  Copyright 1996 Institut National de Recherche en Informatique et   
;  Automatique.  Distributed only by permission.                      
;
;*********************************************************************

; $Id$

; Asm part of the runtime system, Intel 386 processor, Intel syntax

	.386
	.MODEL FLAT

        EXTERN  _garbage_collection: PROC
        EXTERN  _mlraise: PROC
        EXTERN  _caml_apply2: PROC
        EXTERN  _caml_apply3: PROC
        EXTERN  _caml_program: PROC
        EXTERN  _young_limit: DWORD
        EXTERN  _young_ptr: DWORD
        EXTERN	_caml_bottom_of_stack: DWORD
        EXTERN	_caml_last_return_address: DWORD
        EXTERN	_caml_gc_regs: DWORD
	EXTERN	_caml_exception_pointer: DWORD

; Allocation 

        .CODE
        PUBLIC  _caml_alloc1
        PUBLIC  _caml_alloc2
        PUBLIC  _caml_alloc3
        PUBLIC  _caml_alloc
	PUBLIC  _caml_call_gc

_caml_call_gc:
    ; Record lowest stack address and return address 
        mov	eax, [esp]
        mov     _caml_last_return_address, eax
        lea     eax, [esp+4]
        mov     _caml_bottom_of_stack, eax
    ; Save all regs used by the code generator 
L105:   push    ebp
        push    edi
        push    esi
        push    edx
        push    ecx
        push    ebx
        push    eax
        mov     _caml_gc_regs, esp
    ; Call the garbage collector 
        call	_garbage_collection
    ; Restore all regs used by the code generator 
	pop     eax
        pop     ebx
        pop     ecx
        pop     edx
        pop     esi
        pop     edi
        pop     ebp
    ; Return to caller 
        ret	

        ALIGN  4
_caml_alloc1:
        mov	eax, _young_ptr
        sub	eax, 8
        mov	_young_ptr, eax
        cmp	eax, _young_limit
        jb	L100
        ret	
L100:   mov	eax, [esp]
        mov     _caml_last_return_address, eax
        lea     eax, [esp+4]
        mov     _caml_bottom_of_stack, eax
        call    L105
        jmp     _caml_alloc1

        ALIGN  4
_caml_alloc2:
        mov	eax, _young_ptr
        sub	eax, 12
        mov	_young_ptr, eax
        cmp	eax, _young_limit
        jb	L101
        ret	
L101:   mov	eax, [esp]
        mov     _caml_last_return_address, eax
        lea     eax, [esp+4]
        mov     _caml_bottom_of_stack, eax
        call    L105
        jmp     _caml_alloc2

        ALIGN  4
_caml_alloc3:
        mov	eax, _young_ptr
        sub	eax, 16
        mov	_young_ptr, eax
        cmp	eax, _young_limit
        jb	L102
        ret	
L102:   mov	eax, [esp]
        mov     _caml_last_return_address, eax
        lea     eax, [esp+4]
        mov     _caml_bottom_of_stack, eax
        call    L105
        jmp     _caml_alloc3

        ALIGN  4
_caml_alloc:
        sub     eax, _young_ptr         ; eax = size - young_ptr
        neg     eax                     ; eax = young_ptr - size
        cmp     eax, _young_limit
        jb      L103
        mov     _young_ptr, eax
        ret
L103:   sub     eax, _young_ptr         ; eax = - size
        neg     eax                     ; eax = size
        push    eax                     ; save desired size
        sub     _young_ptr, eax         ; must update young_ptr
        mov	eax, [esp+4]
        mov     _caml_last_return_address, eax
        lea     eax, [esp+8]
        mov     _caml_bottom_of_stack, eax
        call    L105
        pop     eax                     ; recover desired size
        jmp     _caml_alloc

; Call a C function from Caml 

        PUBLIC  _caml_c_call
        ALIGN  4
_caml_c_call:
    ; Record lowest stack address and return address 
        mov	edx, [esp]
        mov	_caml_last_return_address, edx
        lea	edx, [esp+4]
        mov	_caml_bottom_of_stack, edx
    ; Call the function (address in %eax) 
        jmp	eax

; Start the Caml program 

        PUBLIC  _caml_start_program
        ALIGN  4
_caml_start_program:
    ; Save callee-save registers 
        push	ebx
        push	esi
        push	edi
        push	ebp
    ; Initial code pointer is caml_program
        mov     esi, offset _caml_program

; Code shared between caml_start_program and callback*

L106:
    ; Build a callback link 
        push    _caml_gc_regs
        push	_caml_last_return_address
        push	_caml_bottom_of_stack
    ; Build an exception handler 
        push	L108
        push	_caml_exception_pointer
        mov	_caml_exception_pointer, esp
    ; Call the Caml code 
        call	esi
L107:
    ; Pop the exception handler 
        pop	_caml_exception_pointer
        pop	esi    		; dummy register 
L109:
    ; Pop the callback link, restoring the global variables
    ; used by caml_c_call
        pop	_caml_bottom_of_stack
        pop	_caml_last_return_address
        pop     _caml_gc_regs
    ; Restore callee-save registers.
        pop	ebp
        pop	edi
        pop	esi
        pop	ebx
    ; Return to caller. 
        ret	
L108:
    ; Exception handler
    ; Mark the bucket as an exception result and return it
        or      eax, 2
        jmp     L109

; Raise an exception from C 

        PUBLIC  _raise_caml_exception
        ALIGN  4
_raise_caml_exception:
        mov	eax, [esp+4]
        mov	esp, _caml_exception_pointer
        pop	_caml_exception_pointer
        ret	

; Callback from C to Caml 

        PUBLIC  _callback_exn
        ALIGN  4
_callback_exn:
    ; Save callee-save registers 
        push	ebx
        push	esi
        push	edi
        push	ebp
    ; Initial loading of arguments 
        mov	ebx, [esp+20]   ; closure 
        mov	eax, [esp+24]   ; argument 
        mov	esi, [ebx]      ; code pointer
        jmp     L106

        PUBLIC  _callback2_exn
        ALIGN  4
_callback2_exn:
    ; Save callee-save registers 
        push	ebx
        push	esi
        push	edi
        push	ebp
    ; Initial loading of arguments 
        mov	ecx, [esp+20]   ; closure 
        mov	eax, [esp+24]   ; first argument 
        mov	ebx, [esp+28]   ; second argument 
        mov	esi, offset _caml_apply2   ; code pointer 
        jmp	L106

        PUBLIC  _callback3_exn
        ALIGN	4
_callback3_exn:
    ; Save callee-save registers 
        push	ebx
        push	esi
        push	edi
        push	ebp
    ; Initial loading of arguments 
        mov	edx, [esp+20]   ; closure 
        mov	eax, [esp+24]   ; first argument 
        mov	ebx, [esp+28]   ; second argument 
        mov	ecx, [esp+32]   ; third argument 
        mov	esi, offset _caml_apply3   ; code pointer 
        jmp	L106

        .DATA
        PUBLIC  _system_frametable
_system_frametable LABEL DWORD
        DWORD   1               ; one descriptor 
        DWORD   L107            ; return address into callback 
        WORD    -1              ; negative frame size => use callback link 
        WORD    0               ; no roots here 

        END
