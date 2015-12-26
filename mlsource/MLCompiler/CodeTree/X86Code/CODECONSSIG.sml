(*
    Copyright (c) David C.J. Matthews 2015

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License version 2.1 as published by the Free Software Foundation.
    
    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.
    
    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*)

signature CODECONSSIG =
sig
    type code
    eqtype reg
    val regClosure:  reg
    val regStackPtr: reg
    datatype argType = ArgGeneral | ArgFP
    val argRegs: argType list -> reg option list
    val resultReg: argType -> reg

    structure RegSet:
    sig
        eqtype regSet
        val singleton: reg -> regSet
        val allRegisters: regSet
        val generalRegisters: regSet
        val floatingPtRegisters: regSet
        val noRegisters: regSet
        val regSetUnion: regSet * regSet -> regSet
        val inSet: reg * regSet -> bool
        val listToSet: reg list -> regSet
    end

    datatype regHint = UseReg of RegSet.regSet | NoHint | NoResult
    type operation
    type operations = operation list
    type forwardLabel
    type backwardLabel

    val activeRegister: reg -> operations
    val returnFromFunction: int -> operations
    val resetStack: int -> operations
    val raiseException: operations
    val pushRegisterToStack: reg -> operations
    val pushCurrentHandler: operations
    val storeToHandler: reg -> operations
    val allocStore: { size: int, flags: Word8.word, output: reg } -> operations
    val allocationComplete: operations
    val backJumpLabel: unit -> operations * backwardLabel
    val forwardJumpLabel: forwardLabel -> operations
    val indexedCase:
            { testReg: reg, workReg: reg, minCase: word, maxCase: word,
              isArbitrary: bool, isExhaustive: bool } -> operations * forwardLabel list * forwardLabel
    
    datatype callKinds =
        Recursive
    |   ConstantClosure of Address.machineWord
    |   ConstantCode of Address.machineWord
    |   CodeFun of code
    |   FullCall
    
    val callFunction: callKinds -> operations
    val jumpToFunction: callKinds  -> operations

    val codeCreate: bool * string * Address.machineWord * Universal.universal list -> code  (* makes the initial segment. *)
    val copyCode: code * operations * int * RegSet.regSet * bool -> Address.address

    (*val codeAddress: code -> address option*)
    val addCompletionHook: code * (code * Address.machineWord -> unit) -> unit

    type regSet = RegSet.regSet
    type machineWord = Address.machineWord
    type ttab
    type loopPush
    type addrs
    type savedState

    val ttabCreate: int * Universal.universal list -> ttab

    (* Register allocation *)
    val getRegister:    ttab * reg -> operation list
    val getRegisterInSet: ttab * regSet -> reg * operation list
    val freeRegister:   ttab * reg -> operation list
    val addRegUse:      ttab * reg -> operation list
    val removeRegistersFromCache: ttab * regSet -> operation list

    (* Stack handling *)
    eqtype stackIndex

    val noIndex: stackIndex

    (* Push entries *)
    val pushReg:      ttab * reg  -> stackIndex;
    val pushStack:    ttab * int  -> stackIndex
    val pushConst:    ttab * machineWord -> stackIndex
    val pushCodeRef:  ttab * code -> stackIndex;
    val pushAllBut:   ttab * ((stackIndex -> unit) -> unit) * regSet -> operation list
    val pushNonArguments: ttab * stackIndex list * regSet -> reg list * operation list
    val pushSpecificEntry: ttab * stackIndex -> operation list
    val incsp:        ttab -> stackIndex;
    val decsp:        ttab*int -> unit;
    val reserveStackSpace: ttab * int -> stackIndex * operation list

    (* Code entries *)
    val loadEntryToSet:    ttab * stackIndex * regSet * bool -> reg * stackIndex * operation list
    val loadToSpecificReg: ttab * reg * stackIndex * bool -> stackIndex * operation list
    val lockRegister:      ttab * reg -> unit
    val unlockRegister:    ttab * reg -> operation list
    val loadIfArg:         ttab * stackIndex -> stackIndex * operation list
    val indirect:          int * stackIndex * ttab -> stackIndex * operation list
    val moveToVec:         stackIndex * stackIndex * int * ttab -> operation list
    val ensureNoAllocation: ttab * stackIndex -> stackIndex * operation list

    val removeStackEntry: ttab*stackIndex -> operation list

    val resetButReload:   ttab * int -> operation list
    val pushValueToStack: ttab * stackIndex * int -> stackIndex * operation list
    val storeInStack:     ttab * stackIndex * int -> stackIndex * operation list
    val realstackptr:     ttab -> int
    val maxstack:         ttab -> int
    val parameterInRegister: reg * int * ttab -> stackIndex
    val incrUseCount:     ttab * stackIndex * int -> operation list

    val setLifetime:      ttab * stackIndex * int -> unit

    type stackMark
    val markStack: ttab -> stackMark
    val unmarkStack: ttab * stackMark -> unit

    type labels;

    val noJump: labels
    val isEmptyLabel: labels -> bool

    datatype mergeResult = NoMerge | MergeIndex of stackIndex;

    val unconditionalBranch: mergeResult * ttab -> labels * operation list
    val makeLabels: mergeResult * forwardLabel * savedState -> labels
    val jumpBack: backwardLabel * ttab -> operation list

    val fixup: labels * ttab -> operation list
    val merge: labels * ttab * mergeResult * stackMark -> mergeResult * operation list

    type handler;

    val pushAddress: ttab * int -> stackIndex * handler * operation list
    val fixupH:      handler * int * ttab -> operation list
    val reloadHandler: ttab * stackIndex -> operation list

    val exiting: ttab -> unit
    val haveExited: ttab -> bool

    val saveState : ttab -> savedState
    val compareLoopStates: ttab * savedState * stackIndex list -> regSet * loopPush list
    val restoreLoopState: ttab * savedState * regSet * loopPush list -> operation list

    (* Temporary checking that the stack has been emptied. *)
    val checkBlockResult: ttab * mergeResult -> unit

    val chooseRegister : ttab -> reg option

    val getRegisterSetForFunction: machineWord -> regSet
    val addModifiedRegSet: ttab * regSet -> unit

    val getModifedRegSet: ttab -> regSet

    datatype argdest = ArgToRegister of reg | ArgToStack of int | ArgDiscard
    val getLoopDestinations: stackIndex list * ttab -> argdest list * operation list

    val callCode: stackIndex * bool * ttab -> operation list
    val jumpToCode: stackIndex * bool * ttab -> operation list

    (* Get constants or code refs, which are really constants. *)
    datatype constEntry = ConstLit of machineWord | ConstCode of code | NotConst

    val isConstant: stackIndex * ttab -> constEntry
    val isRegister: stackIndex * ttab -> reg option
    val isContainer: stackIndex * ttab -> bool

    val createStackClosure: ttab * stackIndex list -> stackIndex * operation list
    val setRecursiveClosureEntry: stackIndex * stackIndex * int * ttab -> operation list
 
    val threadSelf: ttab * regHint -> operation list * mergeResult

    val vectorLength: stackIndex * ttab * regHint -> operation list * mergeResult
    and vectorFlags: stackIndex * ttab * regHint -> operation list * mergeResult
    and getFirstLong: stackIndex * ttab * regHint -> operation list * mergeResult
    and stringLength: stackIndex * ttab * regHint -> operation list * mergeResult
    and atomicIncrement: stackIndex * ttab * regHint -> operation list * mergeResult
    and atomicDecrement: stackIndex * ttab * regHint -> operation list * mergeResult
    and lockVector: stackIndex * ttab * regHint -> operation list * mergeResult
    and absoluteReal: stackIndex * ttab * regHint -> operation list * mergeResult
    and negativeReal: stackIndex * ttab * regHint -> operation list * mergeResult
    and squareRootReal: stackIndex * ttab * regHint -> operation list * mergeResult
    and sineReal: stackIndex * ttab * regHint -> operation list * mergeResult
    and cosineReal: stackIndex * ttab * regHint -> operation list * mergeResult
    and arctanReal: stackIndex * ttab * regHint -> operation list * mergeResult
    and integerToReal: stackIndex * ttab * regHint -> operation list * mergeResult

    val setStringLength:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and addInteger:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and subtractInteger:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and multiplyInteger:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and addWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and subtractWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and andWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and orWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and xorWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and upShiftWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and downShiftWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and downShiftArithmeticWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and multiplyWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and divideWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and modulusWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and loadByte:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and loadWord:
        'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and addReal: stackIndex * stackIndex * ttab * regHint -> operation list * mergeResult
    and subtractReal: stackIndex * stackIndex * ttab * regHint -> operation list * mergeResult
    and multiplyReal: stackIndex * stackIndex * ttab * regHint -> operation list * mergeResult
    and divideReal: stackIndex * stackIndex * ttab * regHint -> operation list * mergeResult

    val allocateStore:
        'a * 'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and storeWord:
        'a * 'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and storeByte:
        'a * 'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option

    val moveBytes:
        'a * 'a * 'a * 'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option
    and moveWords:
        'a * 'a * 'a * 'a * 'a * ttab * regHint * ('a -> Address.machineWord option) * ('a -> stackIndex)  -> (operation list * mergeResult) option

    val notEqualWord: stackIndex * stackIndex * ttab -> labels * operation list
    and equalWord: stackIndex * stackIndex * ttab -> labels * operation list
    and greaterOrEqualWord: stackIndex * stackIndex * ttab -> labels * operation list
    and greaterThanWord: stackIndex * stackIndex * ttab -> labels * operation list
    and lessOrEqualWord: stackIndex * stackIndex * ttab -> labels * operation list
    and lessThanWord: stackIndex * stackIndex * ttab -> labels * operation list
    and notEqualInt: stackIndex * stackIndex * ttab -> labels * operation list
    and equalInt: stackIndex * stackIndex * ttab -> labels * operation list
    and greaterOrEqualInt: stackIndex * stackIndex * ttab -> labels * operation list
    and greaterThanInt: stackIndex * stackIndex * ttab -> labels * operation list
    and lessOrEqualInt: stackIndex * stackIndex * ttab -> labels * operation list
    and lessThanInt: stackIndex * stackIndex * ttab -> labels * operation list
    and notEqualReal: stackIndex * stackIndex * ttab -> labels * operation list
    and equalReal: stackIndex * stackIndex * ttab -> labels * operation list
    and greaterOrEqualReal: stackIndex * stackIndex * ttab -> labels * operation list
    and greaterThanReal: stackIndex * stackIndex * ttab -> labels * operation list
    and lessOrEqualReal: stackIndex * stackIndex * ttab -> labels * operation list
    and lessThanReal: stackIndex * stackIndex * ttab -> labels * operation list
 
    val testShortInt: stackIndex * ttab -> labels * operation list
    and testNotShortInt: stackIndex * ttab -> labels * operation list
    
    val testByteVecEq: stackIndex * stackIndex * stackIndex * stackIndex * stackIndex * ttab -> labels * operation list
    and testByteVecNe: stackIndex * stackIndex * stackIndex * stackIndex * stackIndex * ttab -> labels * operation list

    structure Sharing:
    sig
        type code           = code
        and  reg            = reg
        and  addrs          = addrs
        and  operation      = operation
        and  regHint        = regHint
        and  regSet         = RegSet.regSet
        and  backwardLabel  = backwardLabel
        and  forwardLabel  = forwardLabel
    end
end;
