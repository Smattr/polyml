(*
    Copyright (c) 2013 David C.J. Matthews

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License as published by the Free Software Foundation; either
    version 2.1 of the License, or (at your option) any later version.
    
    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.
    
    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*)

(*
    This is a cut-down version of the optimiser which simplifies the code but
    does not appply any heuristics.  It follows chained bindings, in particular
    through tuples, folds constants expressions involving built-in functions,
    expands inline functions that have previously been marked as inlineable.
    It does not detect small functions that can be inlined nor does it
    code-generate functions without free variables.
*)

functor CODETREE_SIMPLIFIER(
    structure BASECODETREE: BaseCodeTreeSig

    structure CODETREE_FUNCTIONS: CodetreeFunctionsSig

    sharing
        BASECODETREE.Sharing
    =   CODETREE_FUNCTIONS.Sharing
) :
    sig
        type codetree
        val simplifier: codetree * int -> codetree * int
        structure Sharing: sig type codetree = codetree end
    end
=
struct
    open BASECODETREE
    open Address
    open CODETREE_FUNCTIONS

    exception InternalError = Misc.InternalError

    exception RaisedException

    type simpContext =
    {
        lookupAddr: loadForm -> envGeneral * envSpecial,
        enterAddr: int * (envGeneral * envSpecial) -> unit,
        nextAddress: unit -> int
    }

    (* Function to build a closure.  Items are added to the closure if they are not already there. *)
    fun rebuildClosure (closureList: (loadForm * int) list ref) (ext: loadForm): loadForm =
        case (List.find (fn (l, _) => l = ext) (!closureList), ! closureList) of
            (SOME(_, n), _) => (* Already there *) LoadClosure n
        |   (NONE, []) => (* Not there - first *) (closureList := [(ext, 0)]; LoadClosure 0)
        |   (NONE, cl as (_, n) :: _) => (closureList := (ext, n+1) :: cl; LoadClosure(n+1))

    fun envGeneralToCodetree(EnvGenLoad ext) = Extract ext
    |   envGeneralToCodetree(EnvGenConst w) = Constnt w

    fun mkDec (laddr, res) = Declar{value = res, addr = laddr, use=[]}

    fun mkEnv([], exp) = exp
    |   mkEnv(decs, exp as Extract(LoadLocal loadAddr)) =
        (
            (* A common case is where we have a binding as the last item
               and then a load of that binding.  Reduce this so other
               optimisations are possible.
               This is still something of a special case that could/should
               be generalised. *)
            case List.last decs of
                Declar{addr=decAddr, value, ... } =>
                    if loadAddr = decAddr
                    then mkEnv(List.take(decs, List.length decs - 1), value)
                    else Newenv(decs, exp)
            |   _ => Newenv(decs, exp)
        )
    |   mkEnv(decs, exp) = Newenv(decs, exp)

    fun isConstnt(Constnt _) = true
    |   isConstnt(ConstntWithInline _) = true
    |   isConstnt _ = false

    (* Wrap up the general, bindings and special value as a codetree node.  The
       special entry is discarded except for Constnt entries which are converted
       to ConstntWithInline.  That allows any inlineable code to be carried
       forward to later passes. *)
    fun specialToGeneral(g, b as _ :: _, s) = mkEnv(b, specialToGeneral(g, [], s))
    |   specialToGeneral(Constnt w, [], s as EnvSpecTuple _) = ConstntWithInline(w, s)
    |   specialToGeneral(Constnt w, [], s as EnvSpecInlineFunction _) = ConstntWithInline(w, s)
    |   specialToGeneral(g, [], _) = g

    (* Call and RTS function to fold constants.  The function must be safe to evaluate "early". *)
    fun callRTSFunction(rtsCall: machineWord, argList) =
    let
        exception Interrupt = Thread.Thread.Interrupt
        val _ = (isIoAddress(toAddress rtsCall) andalso earlyRtsCall rtsCall)
                    orelse raise InternalError "not early rts"

        (* Turn the arguments into a vector.  *)
        val argVector =
            case makeConstVal(Recconstr argList) of
                Constnt w => w
            |   _ => raise InternalError "makeConstVal: Not constant"

        (* Call the function.  If it raises an exception (e.g. divide
           by zero) generate code to raise the exception at run-time.
           We don't do that for Interrupt which we assume only arises
           by user interaction and not as a result of executing the
           code so we reraise that exception immediately. *)
    in
        Constnt (call(toAddress rtsCall, argVector))
            handle exn as Interrupt => raise exn (* Must not handle this *)
            | exn => Raise (Constnt(toMachineWord exn))
    end

    fun simplify(c, s) = mapCodetree (simpGeneral s) c

    (* Process the codetree to return a codetree node.  This is used
       when we don't want the special case. *)
    and simpGeneral { lookupAddr, ...} (Extract ext) =
        let
            val (gen, spec) = lookupAddr ext
        in
            SOME(specialToGeneral(envGeneralToCodetree gen, [], spec))
        end

    |   simpGeneral context (Newenv envArgs) =
            SOME(specialToGeneral(simpNewenv(envArgs, context)))

    |   simpGeneral context (Lambda lambda) =
            SOME(Lambda(#1(simpLambda(lambda, context, NONE, NONE))))

    |   simpGeneral context (Eval {function, argList, resultType}) =
            SOME(specialToGeneral(simpFunctionCall(function, argList, resultType, context)))

    |   simpGeneral context (Cond(condTest, condThen, condElse)) =
            SOME(specialToGeneral(simpIfThenElse(condTest, condThen, condElse, context)))

    |   simpGeneral context (Recconstr entries) =
            SOME(specialToGeneral(simpTuple(entries, context)))

    |   simpGeneral context (Indirect{ base, offset, isVariant }) =
            SOME(specialToGeneral(simpFieldSelect(base, offset, isVariant, context)))

    |   simpGeneral context (SetContainer{container, tuple, size}) =
            (* Push the set-container down the tree and then process it. If we've
               expanded an inline function we want to be able to find any
               tuple we're creating. *)
            let
                val optCont = simplify(container, context)
                and optTuple = simplify(tuple, context)

                val () =
                    case optCont of
                        Extract(LoadLocal _) => () (* Local *)
                    |   Extract(LoadArgument _) => () (* Local argument *)
                    |   _ => raise InternalError "optimise: SetContainer - not local"
                
                (* If the "tuple" is an expanded inline function it may well
                   contain an if-expression.  If both branches were tuples
                   we will have expanded it already and the result will be
                   a TupleFromContainer. *)
                fun pushSetContainer(Cond(ifpt, thenpt, elsept), decs): codetree =
                    mkEnv(List.rev decs,
                           Cond(ifpt, pushSetContainer(thenpt, []), pushSetContainer(elsept, [])))

                |   pushSetContainer(Newenv(envDecs, envExp), decs) =
                        pushSetContainer(envExp, List.rev envDecs @ decs)

                |   pushSetContainer(TupleFromContainer(ext as Extract(LoadLocal innerAddr), innerSize), decs) =
                    (* If the inner container is declared among the decs we have here we can replace
                       the declaration and remove the inner container by replacing it by
                       a reference to the outer. *)
                    if List.exists (fn (Declar{addr, ...}) => addr = innerAddr | _ => false) decs
                    then
                    let
                        val _ = innerSize = size orelse raise InternalError "pushSetContainer: different sizes"
                        fun changeDec (d as Declar{addr, ...}) = if addr = innerAddr then mkDec(addr, optCont) else d
                        |   changeDec d = d 
                        (* Sometimes the TupleFromContainer is preceded by some
                           Declar entries.  We need to remove them so that the
                           last entry in the list is the NullBinding that contains the
                           code that sets the container, usually as the result of
                           passing it as an argument to a function.  For some reason
                           just adding a dummy CodeZero at the end results in a
                           reference to a non-local container.  I don't understand this. *)
                        fun removeFinalDecs(Declar _ :: tl) = removeFinalDecs tl
                        |   removeFinalDecs(RecDecs _ :: tl) = removeFinalDecs tl
                        |   removeFinalDecs(NullBinding c :: tl) = (List.rev tl, c)
                        |   removeFinalDecs [] = raise InternalError "removeFinalDecs: Empty"
                    in
                        mkEnv(removeFinalDecs(List.map changeDec decs))
                    end
                    else (* We can't replace it. Instead just copy the inner container to the outer, *)
                        mkEnv(List.rev decs, mkSetContainer(optCont, ext, size))

                |   pushSetContainer(tuple, decs) =
                        mkEnv(List.rev decs, mkSetContainer(optCont, tuple, size))
              
            in
                SOME(pushSetContainer(optTuple, []))
            end

    |   simpGeneral (context as { enterAddr, nextAddress, ...}) (BeginLoop{loop, arguments, ...}) =
        let
            (* To see if we really need the loop first try simply binding the
               arguments and process it.  It's often the case that if one
               or more arguments is a constant that the looping case will
               be eliminated.
               It would be possible to look more carefully and eliminate
               arguments that do not change round the loop. *)
            val withoutBeginLoop =
                simplify(mkEnv(List.map (Declar o #1) arguments, loop), context)
            (* Check if the Loop instruction is there.  This assumes that these
               are the only tail-recursive cases. *)
            fun hasLoop (Loop _) = true
            |   hasLoop (Newenv(_, exp)) = hasLoop exp
            |   hasLoop (Cond(_, t, e)) = hasLoop t orelse hasLoop e
            |   hasLoop (Handle {handler, ...}) = hasLoop handler
            |   hasLoop _ = false
        in
            if not (hasLoop withoutBeginLoop)
            then SOME withoutBeginLoop
            else
            let
                (* We need the BeginLoop. Create new addresses for the arguments. *)
                fun declArg({addr, value, use, ...}, typ) =
                    let
                        val newAddr = nextAddress()
                    in
                        enterAddr(addr, (EnvGenLoad(LoadLocal newAddr), EnvSpecNone));
                        ({addr = newAddr, value = simplify(value, context), use = use }, typ)
                    end
                 val declArgs = map declArg arguments
                 val beginBody = simplify(loop, context)
            in
                SOME(BeginLoop {loop=beginBody, arguments=declArgs})
            end
        end

    |   simpGeneral context (TagTest{test, tag, maxTag}) =
        (
            case simplify(test, context) of
                Constnt testResult =>
                    if isShort testResult andalso toShort testResult = tag
                    then SOME CodeTrue
                    else SOME CodeFalse
            |   sTest => SOME(TagTest{test=sTest, tag=tag, maxTag=maxTag})
        )

    |   simpGeneral _ _ = NONE

    (* Where we have an Indirect or Eval we want the argument as either a tuple or
       an inline function respectively if that's possible.  Getting that also involves
       various other cases as well. Because a binding may later be used in such a
       context we treat any binding in that way as well. *)
    and simpSpecial (Extract ext, { lookupAddr, ...}) =
        let
            val (gen, spec) = lookupAddr ext
        in
            (envGeneralToCodetree gen, [], spec)
        end

    |   simpSpecial (Newenv envArgs, context) = simpNewenv(envArgs, context)

    |   simpSpecial (Lambda lambda, context) =
        let
            val (gen, spec) = simpLambda(lambda, context, NONE, NONE)
        in
            (Lambda gen, [], spec)
        end

    |   simpSpecial (Eval {function, argList, resultType}, context) =
            simpFunctionCall(function, argList, resultType, context)

    |   simpSpecial (Cond(condTest, condThen, condElse), context) =
            simpIfThenElse(condTest, condThen, condElse, context)

    |   simpSpecial (Recconstr entries, context) = simpTuple(entries, context)

    |   simpSpecial (Indirect{ base, offset, isVariant }, context) = simpFieldSelect(base, offset, isVariant, context)

    |   simpSpecial (c: codetree, s: simpContext): codetree * codeBinding list * envSpecial =
        let
            (* Anything else - copy it and then split it into the fields. *)
            fun split(Newenv(l, e)) =
                let
                    (* Pull off bindings. *)
                    val (c, b, s) = split e
                in
                    (c, l @ b, s)
                end
            |   split(ConstntWithInline(m, s)) = (Constnt m, [], s)
            |   split c = (c, [], EnvSpecNone)
        in
            split(simplify(c, s))
        end

    (* Process a Newenv.  We need to add the bindings to the context. *)
    and simpNewenv((envDecs, envExp), context as { enterAddr, nextAddress, ...}) =
    let
        fun copyDecs [] =
            (* End of the list - process the result expression. *)
            simpSpecial(envExp, context)
        
        |   copyDecs (Declar{addr, value, ...} :: vs) =
            (
                case simpSpecial(value, context) of
                    (* If this raises an exception stop here. *)
                    vBinding as (Raise _, _, _) => vBinding

                |   vBinding =>
                    let
                        (* Add the declaration to the table. *)
                        val (optV, dec) = makeNewDecl(vBinding, context)
                        val () = enterAddr(addr, optV)                  
                        (* Deal with the rest of the block. *)
                        val (rGen, rDecs, rSpec) = copyDecs vs
                    in
                        (rGen, dec @ rDecs, rSpec)
                    end
            )

        |   copyDecs(NullBinding v :: vs) = (* Not a binding - process this and the rest.*)
            (
                case simpSpecial(v, context) of
                    (* If this raises an exception stop here. *)
                    vBinding as (Raise _, _, _) => vBinding

                |   (cGen, cDecs, _) =>
                    let
                        val (rGen, rDecs, rSpec) = copyDecs vs
                    in
                        (rGen, cDecs @ (NullBinding cGen :: rDecs), rSpec)
                    end
            )

        |   copyDecs(RecDecs mutuals :: vs) =
            (* Mutually recursive declarations. Any of the declarations may
               refer to any of the others. They should all be lambdas.

               The front end generates functions with more than one argument
               (either curried or tupled) as pairs of mutually recursive
               functions.  The main function body takes its arguments on
               the stack (or in registers) and the auxiliary inline function,
               possibly nested, takes the tupled or curried arguments and
               calls it.  If the main function is recursive it will first
               call the inline function which is why the pair are mutually
               recursive.
               As far as possible we want to use the main function since that
               uses the least memory.  Specifically, if the function recurses
               we want the recursive call to pass all the arguments if it
               can. *)
            let
                (* Reorder the function so the explicitly-inlined ones come first.
                   Their code can then be inserted into the main functions. *)
                local
                    val (inlines, nonInlines) =
                        List.partition (
                            fn {lambda = { isInline=MaybeInline, ...}, ... } => true | _ => false) mutuals
                in
                    val orderedDecs = inlines @ nonInlines
                end

                (* Go down the functions creating new addresses for them and entering them in the table. *)
                val addresses =
                    map (fn {addr, ... } =>
                        let
                            val decAddr = nextAddress()
                        in
                            enterAddr (addr, (EnvGenLoad(LoadLocal decAddr), EnvSpecNone));
                            decAddr
                        end)
                    orderedDecs

                fun processFunction({ lambda, addr, ... }, newAddr) =
                let
                    val (gen, spec) = simpLambda(lambda, context, SOME addr, SOME newAddr)
                    (* Update the entry in the table to include any inlineable function. *)
                    val () = enterAddr (addr, (EnvGenLoad (LoadLocal newAddr), spec))
                in
                    {addr=newAddr, lambda=gen, use=[]}
                end
                
                val rlist = ListPair.map processFunction (orderedDecs, addresses)
                
                (* In general any mutually recursive declaration can refer to any
                   other.  It's better to partition the recursive declarations into
                   strongly connected components i.e. those that actually refer
                   to each other.  *)
                local
                    val startAddress = hd addresses (* Must be at least one *)
                    val lastAddress = startAddress + List.length addresses
                    (* *)
                    val mapArray = Array.array(lastAddress - startAddress, NONE)
                    
                    fun updateMin(addr, try) =
                    let
                        val off = addr - startAddress
                        val { lowLink, index } = valOf(Array.sub(mapArray, off))
                    in
                        Array.update(mapArray, off, SOME{ index = index, lowLink = Int.min(lowLink, try) })
                    end

                    fun strongcomponent(item as {addr, lambda = { closure, ...}, ...}, (thisIndex, stack, resList)) =
                    let
                        val newStack = item :: stack
                        val v = addr - startAddress
                        (* Mark this item as processed. *)
                        val () = Array.update(mapArray, v, SOME{index = thisIndex, lowLink = thisIndex})

                        (* Process links that refer to other items *)
                        fun processLink(LoadLocal a, args as (_, stack, _)) =
                            if a >= startAddress andalso a < lastAddress
                            then
                            let
                                val w = a - startAddress
                            in
                                case Array.sub(mapArray, w) of
                                    NONE => (*  Not yet processed. *)
                                    let
                                        val result = strongcomponent(List.nth(rlist, w), args);
                                    in
                                        updateMin(addr, #lowLink(valOf(Array.sub(mapArray, w))));
                                        result
                                    end
                                |   SOME _ =>
                                    (
                                        if List.exists(fn{addr, ...} => a = addr) stack (* On the stack so in the current SCC *)
                                        then updateMin(addr, #index(valOf(Array.sub(mapArray, w))))
                                        else ();
                                        args
                                    )
                            end
                            else args
                        |   processLink (_, args) = args
                        
                        val (nextIndex, stack', subRes) = List.foldl processLink (thisIndex+1, newStack, resList) closure
                    in
                        (* Process references from this function. *)
                        if #lowLink(valOf(Array.sub(mapArray, v))) = thisIndex (* This is the minimum *)
                        then (* Create an SCC *)
                        let
                            fun popItems([], _) = raise InternalError "stack empty"
                            |   popItems((item as {addr=a, ...}) :: r, l) =
                                    if a = addr
                                    then (r, item :: l)
                                    else popItems(r, item :: l)
                            val (newStack, scc) = popItems(stack', [])
                            val out = RecDecs scc
                        in
                            (nextIndex, newStack, out :: subRes)
                        end
                        else (nextIndex, stack', subRes)
                    end

                    (* Process items that have not yet been reached *)
                    fun processUnprocessed (item as {addr, ...}, args) =
                        case Array.sub(mapArray, addr-startAddress) of 
                            NONE => strongcomponent(item, args) | _ => args
                in
                    val (_, _, result) = List.foldl processUnprocessed (0, [], []) rlist;
                    val recBindings = List.rev result
                end

                (* Deal with the rest of the block *)
                val (rGen, rDecs, rSpec) = copyDecs vs
            in
                (* and put these declarations onto the list. *)
                (rGen, recBindings @ rDecs, rSpec)
            end
    in
        copyDecs envDecs
    end

    (* Prepares a binding for entry into a look-up table.  Returns the entry
       to put into the table together with any bindings that must be made.
       If the general part of the optVal is a constant we can just put the
       constant in the table. If it is a load (Extract) it is just renaming
       an existing entry so we can return it.  Otherwise we have to make
       a new binding and return a load (Extract) entry for it. *)
    and makeNewDecl((Constnt w, decs, spec), _) = ((EnvGenConst w, spec), decs)
                (* No need to create a binding for a constant. *)

    |   makeNewDecl((Extract ext, decs, spec), _) = ((EnvGenLoad ext, spec), decs)
                (* Binding is simply giving a new name to a variable
                   - can ignore this declaration. *) 

    |   makeNewDecl((gen, decs, spec), { nextAddress, ...}) =
        let (* Create a binding for this value. *)
            val newAddr = nextAddress()
        in
            ((EnvGenLoad(LoadLocal newAddr), spec), decs @ [mkDec(newAddr, gen)])
        end

    and simpLambda(original as {isInline=OnlyInline, closure=[], ...}, _, _, _) =
        (* Functors are marked as "OnlyInline" unless Compiler.inlineFunctor is false.  There's no point
           in processing them; unlike a normal function they can only ever be called.  Almost always
           the closure will be empty since free variables will come from previous topdecs and will
           be constants,  The exception is if a structure and a functor using the structure appear
           in the same topdec (no semicolon between them).  In that case we can't leave it.  We
           would have to update the closure even if we leave the body untouched but we could
           have closure entries that are constants.
           e.g. structure S = struct val x = 1 end functor F() = struct open S end *)
        (
            original,
            EnvSpecInlineFunction(original, fn _ => raise InternalError "empty closure")
        )

    |   simpLambda(original as {body, isInline, name, argTypes, resultType, closure, localCount, ...},
                  { lookupAddr, ... }, myOldAddrOpt, myNewAddrOpt) =
        let
            (* A new table for the new function. *)
            val oldAddrTab = Array.array (localCount, NONE)

            val optClosureList = ref []

            local
                fun localOldAddr (LoadLocal addr) = valOf(Array.sub(oldAddrTab, addr))
                |   localOldAddr (ext as LoadArgument _) = (EnvGenLoad ext, EnvSpecNone)
                |   localOldAddr (ext as LoadRecursive) = (EnvGenLoad ext, EnvSpecNone)
                |   localOldAddr (LoadClosure addr) =
                    let
                        val oldEntry = List.nth(closure, addr)
                        (* If the entry in the closure is our own address this is recursive. *)
                        fun isRecursive(EnvGenLoad(LoadLocal a), SOME b) = a = b
                        |   isRecursive _ = false
                    in
                        if isRecursive(EnvGenLoad oldEntry, myOldAddrOpt) then (EnvGenLoad LoadRecursive, EnvSpecNone)
                        else
                        let
                            val newEntry = lookupAddr oldEntry
                            val makeClosure = rebuildClosure optClosureList

                            fun convertResult(genEntry, specEntry) =
                                (* If after looking up the entry we get our new address it's recursive. *)
                                if isRecursive(genEntry, myNewAddrOpt)
                                then (EnvGenLoad LoadRecursive, EnvSpecNone)
                                else
                                let
                                    val newGeneral =
                                        case genEntry of
                                            EnvGenLoad ext => EnvGenLoad(makeClosure ext)
                                        |   EnvGenConst w => EnvGenConst w
                                    (* Have to modify the environment here so that if we look up free variables
                                       we add them to the closure. *)
                                    fun convertEnv env args = convertResult(env args)
                                    val newSpecial =
                                        case specEntry of
                                            EnvSpecTuple(size, env) => EnvSpecTuple(size, convertEnv env)
                                        |   EnvSpecInlineFunction(spec, env) => EnvSpecInlineFunction(spec, convertEnv env)
                                        |   EnvSpecNone => EnvSpecNone
                                in
                                    (newGeneral, newSpecial)
                                end
                        in
                            convertResult newEntry
                        end
                    end

                and setTab (index, v) = Array.update (oldAddrTab, index, SOME v)
            in
                val newAddressAllocator = ref 0

                fun mkAddr () = 
                    ! newAddressAllocator before newAddressAllocator := ! newAddressAllocator + 1

                val newCode =
                    simplify (body,
                    {
                        enterAddr = setTab, lookupAddr = localOldAddr,
                        nextAddress=mkAddr
                    })
            end

            val closureAfterOpt = List.foldl (fn ((ext, _), l) => ext :: l) [] (!optClosureList)

            val localCount = ! newAddressAllocator

            val copiedLambda =
                {
                    body          = newCode,
                    isInline      = isInline,
                    name          = name,
                    closure       = closureAfterOpt,
                    argTypes      = argTypes,
                    resultType    = resultType,
                    localCount    = localCount
                }
         in
            case isInline of
                MaybeInline => (* Explicitly inlined functions. *)
                    (* These are usually auxiliary functions that produce the "standard"
                       version of a function and contain a call to the function with multiple
                       arguments.  The idea of these is that we want this function to be
                       expanded inline wherever it is used so that the call to the
                       "standard" (e.g. curried) function is replaced by a call to the
                       more efficient version.
                       We need to return a valid "general" version to keep the back-end
                       happy and provide some code if the standard version is ever used
                       in a context other than a call.  The "special" result we return
                       is the original code with a suitable environment.  Typically
                       we will have called optimiseLambda from the MutualDecs case and
                       we may not yet have processed the main function that this calls.
                       It is tempting to iterate over the environment at this point to
                       produce a vector of (general, special) pairs but that's not a good
                       idea because we may update the outer environment array with some
                       inlineable code for the main function.
                       We can't return the processed code because we would lose the
                       ability to pick up any inline code for the main function. Also
                       we may turn this function into a recursive function if the main
                       function is recursive. *)
                    (
                        copiedLambda,
                        EnvSpecInlineFunction(original, fn addr => lookupAddr(List.nth(closure, addr)))
                    )

            |   OnlyInline =>
                    (* Used for functors.  We may not really need a general value here. *)
                    (
                        copiedLambda,
                        EnvSpecInlineFunction(original, fn addr => lookupAddr(List.nth(closure, addr)))
                    )

            |   _ => (* Normal function. *) (copiedLambda, EnvSpecNone)
        end

    and simpFunctionCall(function, argList, resultType, context) =
    let
        (* Function call - This may involve inlining the function.  We may
           also be able to call the function immediately if it is a simple
           built-in function and the arguments are constants. *)

        (* Get the function to be called and see if it is inline or
           a lambda expression. *)
        val funct as (genFunct, decsFunct, specFunct) = simpSpecial(function, context)
    in
        case (specFunct, genFunct) of
            (EnvSpecInlineFunction({body=lambdaBody, localCount, ...}, functEnv), _) =>
            let
                val (_, functDecs, _) = funct
                and original = function
                and { nextAddress, lookupAddr, enterAddr, ...} = context

                (* Expand a function inline, either one marked explicitly to be inlined or one detected as "small". *)
                (* Calling inline proc or a lambda expression which is just called.
                   The function is replaced with a block containing declarations
                   of the parameters.  We need a new table here because the addresses
                   we use to index it are the addresses which are local to the function.
                   New addresses are created in the range of the surrounding function. *)
                val localVec = Array.array(localCount, NONE)

                local
                    (* Process the arguments.  We have to make a special check here that we are not passing in the function
                       we are trying to expand.  This could result in an infinitely recursive expansion.  It is only
                       going to happen in very special circumstances such as a definition of the Y combinator.  If we
                       do encounter this function we strip the "special" entry so any application will always result
                       in a function call. *)
                    val stripRecursiveInline =
                        case original of
                            Extract extOrig =>
                                (
                                fn ext =>
                                    if ext = extOrig
                                    then (#1(lookupAddr ext), EnvSpecNone)
                                    else lookupAddr ext
                                )
                        |   _ => lookupAddr

                    val argContext =
                        { lookupAddr=stripRecursiveInline, enterAddr = enterAddr, nextAddress = nextAddress}

                    val (params, bindings) =
                        ListPair.unzip(
                            List.map (fn (h, _) => makeNewDecl(simpSpecial(h, argContext), context)) argList)

                    val paramVec = Vector.fromList params
                in
                    fun getParameter n = Vector.sub(paramVec, n)

                    (* Bindings necessary for the arguments *)
                    val copiedArgs = List.foldr (op @) [] bindings
                end

                local
                    fun localOldAddr(LoadLocal addr) = valOf(Array.sub(localVec, addr))
                    |   localOldAddr(LoadArgument addr) = getParameter addr
                    |   localOldAddr(LoadClosure closureEntry) = functEnv closureEntry
                    |   localOldAddr LoadRecursive = raise InternalError "localOldAddr: LoadRecursive"

                    fun setTabForInline (index, v) = Array.update (localVec, index, SOME v)
                in
                    val (cGen, cDecs, cSpec) =
                         simpSpecial(lambdaBody,
                          {lookupAddr=localOldAddr, enterAddr=setTabForInline, nextAddress=nextAddress})
                end

            in
                (cGen, functDecs @ (copiedArgs @ cDecs), cSpec)
            end

        |   (_, gen as Constnt w) => (* Not inlinable - constant function. *)
            let
                val copiedArgs = map (fn (arg, argType) => (simplify(arg, context), argType)) argList
                (* If the function is an RTS call that is safe to evaluate immediately and all the
                   arguments are constants evaluate it now. *)
                val evCopiedCode = 
                    if isIoAddress(toAddress w) andalso earlyRtsCall w andalso List.all (isConstnt o #1) copiedArgs
                    then callRTSFunction(w, List.map #1 copiedArgs)
                    else Eval {function = gen, argList = copiedArgs, resultType=resultType}
            in
                (evCopiedCode, decsFunct, EnvSpecNone)
            end

        |   (_, gen) => (* Anything else. *)
            let
                val copiedArgs = map (fn (arg, argType) => (simplify(arg, context), argType)) argList
                val evCopiedCode = 
                    Eval {function = gen, argList = copiedArgs, resultType=resultType}
            in
                (evCopiedCode, decsFunct, EnvSpecNone)
            end
    end

    and simpIfThenElse(condTest, condThen, condElse, context) =
    (* If-then-else.  The main simplification is if we have constants in the
       test or in both the arms. *)
    let
        val word0 = toMachineWord 0
        val word1 = toMachineWord 1
  
        val False = word0
        val True  = word1
    in
        case simpSpecial(condTest, context) of
            (* If the test is a constant we can return the appropriate arm and
               ignore the other.  *)
            (Constnt testResult, bindings, _) =>
                let
                    val arm = 
                        if wordEq (testResult, False) (* false - return else-part *)
                        then condElse (* if false then x else y == y *)
                        (* if true then x else y == x *)
                        else condThen
                    val (c, b, s) = simpSpecial(arm, context)
                in
                    (c, bindings @ b, s)
                end
        |   test =>
            let
                val simpTest = specialToGeneral test
                local
                    open RuntimeCalls
                    val ioOp : int -> machineWord = RunCall.run_call1 POLY_SYS_io_operation
                    val rtsFunction = Constnt o ioOp

                    fun mkEval (ct, clist)   =
                    Eval {
                        function = ct,
                        argList = List.map(fn c => (c, GeneralType)) clist,
                        resultType=GeneralType
                    }
                in
                    fun mkNot arg = mkEval (rtsFunction POLY_SYS_not_bool, [arg])
                end
            in
                case (simpSpecial(condThen, context), simpSpecial(condElse, context)) of
                    ((thenConst as Constnt thenVal, [], _), (elseConst as Constnt elseVal, [], _)) =>
                        (* Both arms return constants.  This situation can arise in
                           situations where we have andalso/orelse where the second
                           "argument" has been reduced to a constant. *)
                        if wordEq (thenVal, elseVal)
                        then (* Include the test in the decs in case it has side-effects. *)
                            (thenConst (* or elseConst *), [NullBinding simpTest], EnvSpecNone)
              
                        (* if x then true else false == x *)
                        else if wordEq (thenVal, True) andalso wordEq (elseVal, False)
                        then (simpTest, [], EnvSpecNone)
          
                        (* if x then false else true == not x  *)
                        else if wordEq (thenVal, False) andalso wordEq (elseVal, True)
                        then (mkNot simpTest, [], EnvSpecNone)
          
                        else (* can't optimise *) (Cond (simpTest, thenConst, elseConst), [], EnvSpecNone)

                        (* Rewrite "if x then raise y else z" into "(if x then raise y else (); z)"
                           The advantage is that any tuples in z are lifted outside the "if". *)
                |   (thenPart as (Raise _, _, _), (elsePart, elseBindings, elseSpec)) =>
                        (* then-part raises an exception *)
                        (elsePart, NullBinding(Cond (simpTest, specialToGeneral thenPart, CodeZero)) :: elseBindings, elseSpec)

                |   ((thenPart, thenBindings, thenSpec), elsePart as (Raise _, _, _)) =>
                        (* else part raises an exception *)
                        (thenPart, NullBinding(Cond (simpTest, CodeZero, specialToGeneral elsePart)) :: thenBindings, thenSpec)

                |   (thenPart, elsePart) => (Cond (simpTest, specialToGeneral thenPart, specialToGeneral elsePart), [], EnvSpecNone)
            end
    end

    (* Tuple construction.  Tuples are also used for datatypes and structures (i.e. modules) *)
    and simpTuple(entries, context) =
     (* The main reason for optimising record constructions is that they
        appear as tuples in ML. We try to ensure that loads from locally
        created tuples do not involve indirecting from the tuple but can
        get the value which was put into the tuple directly. If that is
        successful we may find that the tuple is never used directly so
        the use-count mechanism will ensure it is never created. *)
    let
        val tupleSize = List.length entries
        (* The record construction is treated as a block of local
           declarations so that any expressions which might have side-effects
           are done exactly once. *)
        val (fieldEntries, bindings) =
            ListPair.unzip(List.map(fn h => makeNewDecl(simpSpecial(h, context), context)) entries)

        (* Make sure we include any inline code in the result.  If this tuple is
           being "exported" we will lose the "special" part. *)
        fun envResToCodetree(EnvGenLoad ext, _) = Extract ext
        |   envResToCodetree(EnvGenConst w, EnvSpecNone) = Constnt w
        |   envResToCodetree(EnvGenConst w, spec) = ConstntWithInline(w, spec)

        val generalFields = List.map envResToCodetree fieldEntries

        val genRec =
            if List.all isConstnt generalFields
            then makeConstVal(Recconstr generalFields)
            else Recconstr generalFields

        val allBindings = List.foldr(op @) [] bindings
        
        val specRec = EnvSpecTuple(tupleSize, fn addr => List.nth(fieldEntries, addr))
    in
        (genRec, allBindings, specRec)
    end

    and simpFieldSelect(base, offset, isVariant, context) =
    let
        val (genSource, decSource, specSource) = simpSpecial(base, context)
    in
        (* Try to do the selection now if possible. *)
        case specSource of
            EnvSpecTuple(_, recEnv) =>
            let
                (* The "special" entry we've found is a tuple.  That means that
                   we are taking a field from a tuple we made earlier and so we
                   should be able to get the original code we used when we made
                   the tuple.  That might mean the tuple is never used and
                   we can optimise away the construction of it completely. *)
                val (newGen, newSpec) = recEnv offset
            in
                (envGeneralToCodetree newGen, decSource, newSpec)
            end
                   
        |   _ => (* No special case possible. If the tuple is a constant mkInd/mkVarField
                    will do the selection immediately. *)
                ((if isVariant then mkVarField else mkInd) (offset, genSource), decSource, EnvSpecNone)
    end

    fun simplifier(c, numLocals) =
    let
        val localAddressAllocator = ref 0
        val addrTab = Array.array(numLocals, NONE)
        
        fun lookupAddr (LoadLocal addr) = valOf(Array.sub(addrTab, addr))
        |   lookupAddr _ = raise InternalError "top level reached"

        and enterAddr (addr, tab) = Array.update (addrTab, addr, SOME tab)

        fun mkAddr () = 
            ! localAddressAllocator before localAddressAllocator := ! localAddressAllocator + 1
        val code =
            simplify(c,
                {lookupAddr = lookupAddr, enterAddr = enterAddr, nextAddress = mkAddr})
    in
        (code, ! localAddressAllocator)
        (*(c, numLocals)*)
    end

    structure Sharing = struct type codetree = codetree end
end;