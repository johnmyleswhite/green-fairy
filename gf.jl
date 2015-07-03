#= TODO

- make the canonicalized ccall homogenous
- figure out what to do with :& arguments

- support kwcall

- support topmod !== Base


- exceptions :
  - use jl_rethrow instead of Base.rethrow
  - mark may_throw intrinsics correctly
  - mark method error thrown correctly

- think about on-the-fly code mutation (inlining, actual constprop, ...)
  - would be super cool : figure out that a pc has converged before all its succ (reverse preorder), compute inlining cost model, inline, continue without invalidating any inference data

- think about implementing type_goto :-(

=#

module GreenFairy
const USE_UC = true
const TOP_SYM = USE_UC ? "⊤" : "top"
const BOT_SYM = USE_UC ? "⊥" : "bot"
const _ELLIPS = "..."
function show_limit(io::IO, x; limit = 80)
    buf = IOBuffer()
    show(buf, x)
    if position(buf) > limit
        seek(buf, limit-length(_ELLIPS))
        write(buf, _ELLIPS)
        truncate(buf, limit)
    end
    seekstart(buf)
    write(io, takebuf_string(buf))
end
show_limit(x; kw...) = show_limit(STDOUT, x; kw...)

typealias LocalName Union(Symbol,GenSym)
# static data about a function
include("dom.jl")
type Code
    mod :: Module
    name :: Symbol
    body :: Vector{Any}
    call_args :: Vector{Vector{Int}}
    label_pc :: Vector{Int} # label+1 => pc
    locals :: Set{LocalName}
    args :: Vector{Symbol}
    isva :: Bool
    tvar_mapping
    capt :: Vector{Symbol}
    decl_types :: Dict{LocalName,Any}
end

import Base.convert
using Base.Collections
# ========== Lattice stuff
abstract Lattice
istop{L<:Lattice}(x::L) = x === top(L)
isbot{L<:Lattice}(x::L) = x === bot(L)
<=(::Lattice,::Lattice) = error("<= must be defined")
==(x::Lattice,y::Lattice) = x<=y && y<=x
# the one and only 3-element complete lattice
immutable L3 <: Lattice
    v :: Int8
end
const L3e = L3(0)
top(::Type{L3}) = L3(1 % Int8)
bot(::Type{L3}) = L3(-1 % Int8)
isbot(x::L3) = x.v == Int8(-1)
istop(x::L3) = x.v == Int8(1)
<=(x::L3,y::L3) = x.v <= y.v
Base.show(io::IO, x::L3) = print(io, istop(x) ? TOP_SYM : isbot(x) ? BOT_SYM : "L3.e")

abstract TagLattice <: Lattice
istop(x::TagLattice) = istop(x.tag)
isbot(x::TagLattice) = isbot(x.tag)
Base.show(io::IO, x::TagLattice) = (istop(x) | isbot(x)) ? show(io, x.tag) : (print(io, "const(");show_limit(io,x.v);print(io,")"))
<=(x::TagLattice,y::TagLattice) = (istop(y) || isbot(x) || x.tag == y.tag == L3e && y.v===x.v)
function join{T<:TagLattice}(x::T,y::T)
    x <= y && return y
    y <= x && return x
    top(T)
end

# ========== Const
immutable Const <: TagLattice
    tag :: L3
    v :: Any
    Const(tag::L3,v::ANY) = new(tag,v)
end
Const(v::ANY) = Const(L3e, v)
top(::Type{Const}) = Const(top(L3), ())
bot(::Type{Const}) = Const(bot(L3), ())
==(x::Const,y::Const) = x.tag == y.tag && (x.tag != L3e || x.v === y.v)
function meet(x::Const,y::Const)
    isbot(x) && return x
    isbot(y) && return y
    istop(x) && return y
    istop(y) && return x
    x == y && return x
    return bot(Const)
end

immutable ConstCode{EnvT} <: TagLattice
    tag :: L3
    v :: Code
    env :: Tuple{Vararg{EnvT}}
    ConstCode(tag::L3) = new(tag)
    ConstCode(tag::L3,v::Code,env::Tuple{Vararg{EnvT}}) = new(tag,v,env)
    ConstCode(tag::L3,v::Code,::Tuple{}) = new(tag,v,())
end
ConstCode{E}(::Type{E},v::Code,::Tuple{}) = ConstCode{E}(L3e, v, ())
ConstCode{E}(::Type{E},v::Code,env::Tuple{Vararg{E}}) = ConstCode{E}(L3e, v, env)
top{E}(::Type{ConstCode{E}}) = ConstCode{E}(top(L3))
bot{E}(::Type{ConstCode{E}}) = ConstCode{E}(bot(L3))
==(x::ConstCode,y::ConstCode) = x.tag == y.tag && (x.tag != L3e || x.v === y.v)

# ========== Sign
immutable Sign <: Lattice
    tag :: L3
    s :: Int8
end
Sign(s::Int) = Sign(L3e, s%Int8)
top(::Type{Sign}) = Sign(top(L3), 0)
bot(::Type{Sign}) = Sign(bot(L3), 0)
istop(x::Sign) = istop(x.tag)
isbot(x::Sign) = isbot(x.tag)
Base.show(io::IO, x::Sign) = (istop(x) | isbot(x)) ? show(io, x.tag) : print(io, "sign(", x.s > 0 ? "+" : x.s < 0 ? "-" : "0", ")")
<=(x::Sign,y::Sign) = istop(y) || isbot(x) || x.tag == y.tag == L3e && x.s == y.s
==(x::Sign,y::Sign) = x.tag == y.tag && (x.tag != L3e || x.s == y.s)
function join(x::Sign,y::Sign)
    x <= y && return y
    y <= x && return x
    top(Sign)
end
meet(x,y) = x <= y ? x : y

# ========== Type

function widen(t::ANY) #TODO better this
    if isa(t,UnionType)
        ut = t::UnionType
        n = length(ut.types)
        if n == 0
            ut
        else
            r = Array(Any, n)
            for i=1:n
                r[i] = widen(ut.types[i])
            end
            Union(r...)
        end
    elseif t <: Tuple
        tt = t::DataType
        Core.Inference.limit_tuple_depth(Core.Inference.limit_tuple_type(tt))
    elseif isa(t,DataType) && t.name === Type.name
        Type
    elseif isa(t,TypeVar)
        tv = t::TypeVar
        tv.ub
    else
        t
    end
end

immutable Ty <: Lattice
    ty :: Type
    Ty(t::ANY) = (tt = widen(t)::Type; new(tt))
end
top(::Type{Ty}) = Ty(Any)
bot(::Type{Ty}) = Ty(Union())
istop(t::Ty) = t.ty === Any
isbot(t::Ty) = isa(t.ty,UnionType) && length((t.ty::UnionType).types) == 0
function Base.show(io::IO, x::Ty)
    istop(x) && return print(io, TOP_SYM)
    isbot(x) && return print(io, BOT_SYM)
    print(io, "ty(", x.ty, ")")
end
<=(x::Ty,y::Ty) = x.ty <: y.ty
==(x::Ty,y::Ty) = Base.typeseq(x.ty,y.ty)
join(x::Ty,y::Ty) = Ty(Core.Inference.tmerge(x.ty,y.ty))
meet(x::Ty,y::Ty) = Ty(typeintersect(x.ty,y.ty))

immutable Kind <: TagLattice
    tag :: L3
    ub :: Ty
    Kind(tag::L3) = new(tag)
    Kind(tag::L3, ub::Ty) = new(tag,ub)
end
top(::Type{Kind}) = Kind(top(L3))
bot(::Type{Kind}) = Kind(bot(L3))
Kind(ub::Ty) = Kind(L3e, ub)
Kind(ub::TypeVar) = Kind(ub.ub)
Kind(ub::Type) = Kind(Ty(ub))
<=(x::Kind, y::Kind) = istop(y.tag) || isbot(x.tag) || (x.tag == y.tag == L3e && x.ub <= y.ub)
function join(x::Kind, y::Kind)
    (istop(x) || istop(y)) && return top(Kind)
    isbot(x) && return y
    isbot(y) && return x
    Kind(join(x.ub,y.ub))
end
function meet(x::Kind,y::Kind)
    (isbot(x) || isbot(y)) && return bot(Kind)
    istop(x) && return y
    istop(y) && return x
    Kind(meet(x.ub,y.ub))
end

    
Base.show(io::IO,k::Kind) = istop(k) ? print(io, TOP_SYM) : isbot(k) ? print(io, BOT_SYM) : print(io, "kind(", k.ub, ")")


# ========== Birth
immutable Birth <: Lattice
    tag :: L3
    fc :: Int # -1 => something in an upper frame
    pc :: Int
end
# TODO join(k:x:y,k:z:w) = k:*:*
Birth(fc::Int,pc::Int) = Birth(L3e, fc, pc)
top(::Type{Birth}) = Birth(top(L3), 0, 0)
bot(::Type{Birth}) = Birth(bot(L3), 0, 0)
istop(x::Birth) = istop(x.tag)
isbot(x::Birth) = isbot(x.tag)
Base.show(io::IO, x::Birth) = (istop(x) | isbot(x)) ? show(io, x.tag) : print(io, "birth(", x.fc, ":", x.pc, ")")
<=(x::Birth,y::Birth) = istop(y) || isbot(x) || x.tag == y.tag == L3e && x.fc == y.fc && x.pc == y.pc
function join(x::Birth,y::Birth)
    x <= y && return y
    y <= x && return x
    top(Birth)
end
meet(x,y) = x <= y ? x : y

# ========== Reduced product
# one day we may switch back to the non-staged version if the compiler gets smart enough
immutable Prod{Ls} <: Lattice
    values :: Ls
end

# this should in theory be iterated until fp for maximum precision ...
#prod{Ls}(values::Ls) = Prod(ntuple(i -> reduce(meet, map(v -> meet_ext(values[i], v), values)), length(values)))
@generated function prod{Ls}(values::Ls)
    n = length(Ls.types)
    body = []
    names = Symbol[gensym() for i = 1:n]
    for i = 1:n
        push!(body, :($(names[i]) = values[$i]))
    end
    for i = 1:n
        ni = names[i]
        for j = 1:n
            i != j || continue
            push!(body, :($ni = isbot($ni) ? $ni : meet_ext($ni, $(names[j]))))
        end
    end
    quote
        $(body...)
        Prod(tuple($(names...)))
    end
end
#top{Ls}(::Type{Prod{Ls}}) = Prod(map(T->top(T),Ls))
#bot{Ls}(::Type{Prod{Ls}}) = Prod(map(T->bot(T),Ls))
@generated function top{Ls}(::Type{Prod{Ls}})
    :(Prod(tuple($(Expr[:(top($T)) for T in Ls.types]...))))
end
@generated function bot{Ls}(::Type{Prod{Ls}})
    :(Prod(tuple($(Expr[:(bot($T)) for T in Ls.types]...))))
end
#istop(x::Prod) = all(istop, x.values)
#isbot(x::Prod) = any(isbot, x.values)
@generated isbot{Ls}(x::Prod{Ls}) = foldl((x,i) -> :($x || isbot(x.values[$i])), :(false), 1:length(Ls.types))
@generated istop{Ls}(x::Prod{Ls}) = foldl((x,i) -> :($x && istop(x.values[$i])), :(true), 1:length(Ls.types))


function Base.show(io::IO, x::Prod)
    istop(x) && return print(io, TOP_SYM)
    isbot(x) && return print(io, BOT_SYM)
    USE_UC || print(io, "meet(")
    vals = filter(v->!istop(v), x.values)
    for (i,v) in enumerate(vals)
        i == 1 || print(io, USE_UC ? " ∩ " : ", ")
        print(io, v)
    end
    USE_UC || print(io, ")")
end

#=function <={Ls}(x::Prod{Ls}, y::Prod{Ls})
    all(map(<=, x.values, y.values))
end=#
@generated function <={Ls}(x::Prod{Ls}, y::Prod{Ls})
    ex = :(true)
    for i = 1:length(Ls.types)
        ex = :($ex && (x.values[$i] <= y.values[$i]))
    end
    :(isbot(x) || $ex)
end
@generated function =={Ls}(x::Prod{Ls}, y::Prod{Ls})
    ex = :(true)
    for i = 1:length(Ls.types)
        ex = :($ex && (x.values[$i] == y.values[$i]))
    end
    :(isbot(x) && isbot(y) || $ex)
end


#=function join{Ls}(x::Prod{Ls}, y::Prod{Ls})
    Prod(map(join, x.values, y.values))
end=#
@generated function join{Ls}(x::Prod{Ls},y::Prod{Ls})
    args = Expr[:(join(x.values[$i],y.values[$i])) for i=1:length(Ls.types)]
    :(Prod(tuple($(args...))))
end

function <={L<:Lattice,Ls}(x::Prod{Ls},y::L)
    convert(L,x) <= y
end
#=function convert{L,Ls}(::Type{L},x::Prod{Ls})
    L in Ls || error("converting " * string(L) * " : " * string(x))
    x.values[findfirst(Ls,L)]
end=#
@generated function convert{L<:Lattice,Ls}(::Type{L},x::Prod{Ls})
    idx = 0
    for i = 1:length(Ls.types)
        if Ls.types[i] <: L
            idx = i
            break
        end
    end
    idx > 0 || error("converting " * string(L) * " : " * string(x))
    :(x.values[$idx])
end

@generated function meet{L,Ls}(x::Prod{Ls},y::L)
    L in Ls.types || error("meet " * string(x) * " : " * string(y))
    idx = findfirst(Ls.types,L)
    args = Expr[i == idx ? :(meet(x.values[$i],y)) : :(x.values[$i]) for i=1:length(Ls.types)]
    :(prod(tuple($(args...))))
end
@generated function meet{Ls}(x::Prod{Ls},y::Prod{Ls})
    args = Expr[:(meet(x.values[$i],y.values[$i])) for i=1:length(Ls.types)]
    :(prod(tuple($(args...))))
end
convert{L}(::Type{Prod{L}}, y::Prod{L})=y
@generated function convert{L,Ls}(::Type{Prod{Ls}},y::L)
    L in Ls.types || error("convert : ", string(Ls), " < ", string(y))
    idx = findfirst(Ls.types,L)
    args = Any[i == idx ? :(y) : :(top($(Ls.types[i]))) for i=1:length(Ls.types)]
    :(prod(tuple($(args...))))
end

#=function eval_local(p::Prod,name::LocalName)
    prod(map(v -> eval_local(v, name), p.values))
end
eval_local{T<:Lattice}(::T,::LocalName) = top(T)=#
join{Ls}(p::Prod{Ls},v::Lattice) = join(p,convert(Prod{Ls},v))

# ========== Interpreter

const GTRACE = false
const DEBUGWARN = false

immutable Up
    i :: Int
end

type Config
    join_strat :: Symbol
end
function Base.show(io::IO, c::Code)
    ln = c.body[1]
    if isa(ln, Expr) && ln.head == :line
        lns = @sprintf("%s:%d", ln.args[2], ln.args[1])
    else
        lns = string("??? (", ln, ")")
    end
    print(io, "(", module_name(c.mod), ".", c.name, " at ",lns,", ", length(c.body), " statements)")
end

# fallback for immutable lattices
function join!(v::Lattice,v2::Lattice)
    j = join(v,v2)
    j, !(j <= v)
end

function Base.countnz(B::BitArray, upto)
    n = 0
    Bc = B.chunks
    d,r = divrem(upto, 64)
    @inbounds for i = 1:d
        n += count_ones(Bc[i])
    end
    if r > 0
        msk = ~zero(UInt64) >> (64-r)
        @inbounds n += count_ones(Bc[d+1] & msk)
    end
    n
end

include("mprod.jl")

type LocalStore{V<:Lattice}
    local_names :: Vector{LocalName}
    defs :: Vector{DefStore{Set{Int}}}
    sa :: Vector{V}
    phis :: Vector{Dict{Int,V}}
    len :: Int
    code :: Code
    dtree :: DomTree
    heap :: Vector{Set{Set{Any}}}
    changed :: BitVector
end
function Base.getindex(s::LocalStore, pc)
    [ k => eval_local(s,pc,k) for k in  s.local_names ]
end
function LocalStore{V}(::Type{V}, code::Code)
    n = length(code.body)
    LocalStore(Array(LocalName,0),Array(DefStore{Set{Int}},0),V[bot(V) for i=1:n+1], Array(Dict{Int,V},0), n, code, build_dom_tree(code), [Set{Set{Any}}() for i=1:n+1], trues(n+1))
end
type Thread
    fc :: Int
    pc :: Int
    wait_on :: Vector{Int} # fc we need to continue
    cycle :: Int
    eh_stack :: Vector{Int} # pc of handler
end
Thread(f,p) = Thread(f,p,Array(Int,0),0,Array(Int,0))
immutable LocalStateDiff{V}
    name :: LocalName
    val :: V
    saval :: Int
end
type StateDiff{V,TV}
    t::Thread
    locals :: Vector{LocalStateDiff{V}}
    sa_name :: Int
    lost :: Vector{Int}
    value :: V
    thrown :: TV
    must_throw :: Bool
    heap_use
end

function eval_def{V}(s::LocalStore{V}, local_idx, pc)
    isphi = pc == 0 || (pc in s.code.label_pc)
    if isphi
        get(s.phis[local_idx], pc, bot(V))
    else
        s.sa[pc]
    end
end

function add_local!{V}(s::LocalStore{V}, name)
    push!(s.local_names, name)
    ds = DefStore(Set{Int})
    add_def!(s.code, s.dtree, ds, 0, 0)
    push!(s.defs, ds)
    push!(s.phis, Dict{Int,V}())
    length(s.local_names)
end

function propagate!{V}(s::LocalStore{V},pc::Int,next::Int,sd::StateDiff)
    chgd = false
    d = sd.locals
    for lsd in d
        if !(lsd.name in s.local_names)
            add_local!(s, lsd.name)
        end
    end
    # update phis
    lbl = findfirst(s.code.label_pc, pc)
    if lbl > 0
        for li = 1:length(s.local_names)
            k = s.local_names[li]
            # TODO only join the changed incoming edges
            if haskey(s.defs[li].phis, lbl)
                newval = eval_def(s, li, pc)
                for i in s.defs[li].phis[lbl]
                    newval = join(newval, eval_def(s, li, i))
                end
                if haskey(s.phis[li], pc) && newval <= s.phis[li][pc]
                else
                    s.phis[li][pc] = newval
                    chgd = true
                end
            end
        end
    end
    
    # do defs
    for idx = 1:length(d)
        li = findfirst(s.local_names, d[idx].name)
        @assert li > 0
        chgd |= add_def!(s.code, s.dtree, s.defs[li], pc > 0 ? pc : d[idx].saval, d[idx].saval)
    end
    if pc > 0
    for obj in s.heap[pc]
        nobj = copy(obj)
        
        if sd.sa_name in nobj
            pop!(nobj, sd.sa_name)
        end
        if sd.heap_use in nobj
            push!(nobj, sd.sa_name)
        end
        for idx = 1:length(d)
            name = d[idx].name
            li = findfirst(s.local_names, name)
            @assert li > 0
            def = find_def_fast(s.code, s.dtree, s.defs[li], pc)[2]
            heap_def = name#(name, def)
            if heap_def in nobj
                pop!(nobj, heap_def)
            end
            if d[idx].saval in nobj
                push!(nobj, heap_def)
            end
        end
        if !(nobj in s.heap[next])
            push!(s.heap[next], nobj)
            chgd = true
        end
    end
        if sd.heap_use === :new
            obj = Set{Any}([sd.sa_name])
            if !(obj in s.heap[next])
                push!(s.heap[next], obj)
                chgd = true
            end
        end
        
    end
    
    sa = sd.sa_name
    if sa > 0
        val = s.sa[sa]
        if !(sd.value <= val)
            s.sa[sa] = join(sd.value, val)
            chgd = true
        end
    end

    if chgd
        fill!(s.changed, true)
    else
        pc > 0 && (s.changed[pc] = false)
    end
    s.changed[next]
end
function eval_local!{V}(s::LocalStore{V}, sd, pc::Int, name::LocalName)
    idx = findfirst(s.local_names, name)
    if idx == 0
        bot(V)
    else
        def = nothing
        val = nothing
        try
            ds = s.defs[idx]
            def = find_def_fast(s.code, s.dtree, ds, pc)
            #println("Before def $name : $def $(sd.heap_use) at $pc")
            sd.heap_use = name#(name, def[2])
            val = eval_def(s, idx, def[2])#def[2] > 0 ? s.sa[def[2]] : bot(V)
            #end
            #@show vals
            #if all(vals .> 0)
            #    ssaval = reduce(join,map(i->s.sa[i],vals))
            #if val == locval
            #else
                #=@show pc s.code.label_pc
                @show s.defs[idx] def
                @show s.defs[idx].vals
                @show val locval
                @show s.code.dtree.front
                @show s.code=#
                #error()
            #    end
            #end

            
        catch
            println("Error while evaling $name")
            @show s.defs[idx] def s.defs[idx].vals
            @show collect(enumerate(s.code.label_pc))
            rethrow()
        end
        val
    end
end

function eval_local{V}(s::LocalStore{V}, pc::Int, name::Int)
    if name > 0
        s.sa[name]
    elseif name < 0
        error("negative name")
    else
        bot(V)
    end
end

immutable State{LV,InitT,FinalT}
    initials :: Vector{InitT}
    funs :: Vector{LocalStore{LV}} # TODO better name
    finals :: Vector{FinalT}
    lost :: Vector{Set{Int}}
end
State{V,InitT,FinalT}(::Type{V},::Type{InitT},::Type{FinalT}) = State{V,InitT,FinalT}(Array(InitT,0), Array(LocalStore{V}, 0), Array(FinalT,0), Array(Set{Int}, 0))
immutable InitialState{V} <: Lattice
    args :: Vector{V}
    capt :: Vector{V}
    tenv :: Vector{V}
    heap :: Set{Set{Any}}
end
function <={V}(s1::InitialState{V},s2::InitialState{V})
    length(s1.args) == length(s2.args) &&
    length(s1.capt) == length(s2.capt) &&
    length(s1.tenv) == length(s2.tenv) || return false

    for (a1,a2) in ((s1.args,s2.args), (s1.capt,s2.capt), (s1.tenv, s2.tenv))
        for (v1,v2) in zip(a1,a2)
            v1 <= v2 || return false
        end
    end

    for obj in s1.heap
        (obj in s2.heap) || return false
    end
    
    true
end
function ensure_filled!{V,I,F}(s::State{V,I,F}, fc::Int, code::Code, initial::InitialState)
    push!(s.initials, initial)
    push!(s.funs, LocalStore(V, code))
    push!(s.finals, bot(F))
    push!(s.lost, Set{Int}())
    @assert fc == length(s.initials) == length(s.funs) == length(s.finals) == length(s.lost)
    apply_initial!(s, initial, fc, code)
end

function apply_initial!(s::State,is::InitialState,fc::Int,code::Code)
    @assert length(is.args) == length(code.args)
    ls = s.funs[fc]
    for i = 1:length(is.args)
        li = add_local!(ls, code.args[i])
        ls.phis[li][0] = is.args[i]
    end
    for i = 1:length(is.capt)
        li = add_local!(ls, code.capt[i])
        ls.phis[li][0] = is.capt[i]
    end
    for i = 1:length(is.tenv)
        li = add_local!(ls, code.tvar_mapping[2*i-1].name)
        ls.phis[li][0] = is.tenv[i]
    end
    #@show is.heap
    ls.heap[1] = copy(is.heap)
end

eval_local(s::State, fc::Int, pc::Int, name) = eval_local(s.funs[fc], pc, name)
function propagate!{V,LV}(s::State,fc::Int,pc::Int,next::Int,sd::StateDiff{V,LV})
    chgd = false
    
    l = length(s.lost[fc])
    union!(s.lost[fc], sd.lost)
    chgd |= (l != length(s.lost[fc]))
    chgd |= propagate!(s.funs[fc],pc,next,sd)

    if next == s.funs[fc].len+1
        chgd |= propagate!(s,s.finals[fc],fc,pc,sd)
    end
    chgd
end
InitialState{V}(::Type{V}, code::Code) =
    InitialState(V[bot(V) for i = 1:length(code.args)],
                 V[bot(V) for i = 1:length(code.capt)],
                 V[bot(V) for i = 1:div(length(code.tvar_mapping), 2)],
                 Set{Set{Any}}())
type FinalState{V} <: Lattice
    ret_val :: V
    ret_sa :: Set{Int}
    thrown :: V
    must_throw :: Bool
    heap :: Set{Set{Any}}
    last_cycle :: Int
end
bot{V}(::Type{FinalState{V}}) = FinalState(bot(V),Set{Int}(),bot(V),true,Set{Set{Any}}(),0)
function Base.show(io::IO, s::FinalState)
    print(io, "(returned: ", s.ret_val, " [", Base.join(collect(s.ret_sa), ","), "] ")
    if !isbot(s.thrown)
        print(io, ", ", s.must_throw ? "must" : "may", " throw ", s.thrown)
    end
    print(io, ")")
end

function join!{V}(f::FinalState{V}, g::FinalState{V})
    f.ret_val = join(f.ret_val, g.ret_val)
    f.thrown = join(f.thrown, g.thrown)
    f.must_throw = f.must_throw & g.must_throw
    f.last_cycle = max(f.last_cycle, g.last_cycle)
    union!(f.ret_sa, g.ret_sa)
    union!(f.heap, g.heap)
    nothing
end

function propagate!(s::State,fs::FinalState,fc::Int,pc::Int,sd)
    chgd = false
    if !(sd.value <= fs.ret_val)
        fs.ret_val = join(fs.ret_val, sd.value)
        chgd = true
    end
    if !(sd.thrown <= fs.thrown)
        fs.thrown = join(fs.thrown, sd.thrown)
        chgd = true
    end
    if fs.must_throw && !sd.must_throw
        fs.must_throw &= sd.must_throw
        chgd = true
    end
    l = length(fs.ret_sa)
    push!(fs.ret_sa, pc) # TODO not sure about pc in general (exceptions ?)
    if l != length(fs.ret_sa)
        chgd = true
    end
    ls = s.funs[fc]
    code = ls.code

    for obj in ls.heap[length(code.body)+1]
        nobj = Set{Any}()
        for v in obj
            if v in fs.ret_sa || isa(v,Up)
                push!(nobj, v)
            end
        end
        if !(nobj in fs.heap)
            push!(fs.heap, nobj)
            chgd = true
        end
    end
    
    if chgd
        fs.last_cycle = sd.t.cycle+1
    end
    chgd
end
function Base.getindex(s::State, fc::Int, pc::Int)
    s.funs[fc][pc]
end


type Scheduler{ValueT,StateT}
    states :: StateT
    done :: Vector{Bool}
    threads :: Vector{Thread}
    done_threads :: Vector{Thread}
    config :: Config
    called_by :: Vector{Set{Any}}
    funs :: Vector{Code}
end

function register_fun!(sched::Scheduler, fcode::Code, initial::InitialState)
    push!(sched.funs, fcode)
    fc = length(sched.funs)
    ensure_filled!(sched.states, fc, fcode, initial)
    push!(sched.done, false)
    push!(sched.called_by, Set{Any}())
    fc
end

function Base.show(io::IO,t::Thread)
    println(io, "abstract thread ", pointer_from_objref(t), " at ",t.fc,":",t.pc, " final:")
end
fork(s,t) = fork(s,t,t.pc)
fork(s,t,pc) = fork(s,t,pc)
function fork(s::Scheduler,t::Thread,pc::Int)
    child = Thread(t.fc,pc)
    child.eh_stack = copy(t.eh_stack)
    child.cycle = t.cycle
    heappush!(s.threads, child)
    child
end

function show_dict(io::IO,s)
    ntop = 0
    nbot = 0
    for (l,v) in s
        istop(v) && (ntop += 1; continue)
        isbot(v) && (nbot += 1; continue)
        println(io, "\t", l, " : ", v)
    end
    if ntop > 0
        print(io, "\t", ntop>1?"(":"")
        i = 0
        for (l,v) in s
            istop(v) || continue
            i += 1
            print(io, l)
            ntop == i || print(io, ", ")
        end
        println(io, ntop>1?")":"", " : ", TOP_SYM)
    end
    if nbot > 0
        print(io, "\t", nbot>1?"(":"")
        i = 0
        for (l,v) in s
            isbot(v) || continue
            i += 1
            print(io, l)
            nbot == i || print(io, ", ")
        end
        println(io, nbot>1?")":"", " : ", BOT_SYM)
    end
end

meet_ext(v::Lattice, v2::Lattice) = v
meet_ext{T}(v::T,v2::T) = v
meet_ext(v::Ty, v2::Const) = istop(v2) ? v : Ty(typeof(v2.v))
meet_ext(v::Kind, v2::Const) = istop(v2) || !isa(v2.v,Type) ? v : Kind(Ty(v2.v))
meet_ext(v::Const, v2::Kind) = istop(v2) || !isleaftype(v2.ub.ty) ? v : Const(v2.ub.ty)
meet_ext(v::Sign, v2::Const) = istop(v2) || !isa(v2.v,Int) ? v : Sign(sign(v2.v))

function meet_ext(v::Const,v2::Ty)
    if isdefined(v2.ty, :instance)
        Const(v2.ty.instance)
    else
        v
    end
end

function to_signature(args)
    map(args) do a
        ca = convert(Const,a)
        if !istop(ca) && isa(ca.v,Type)
            return Type{ca.v}
        end
        ka = convert(Kind,a)
        if !istop(ka)
            ub = ka.ub.ty
            return if isleaftype(ub)
                Type{ub}
            else
                Type{TypeVar(:_,ub)}
            end
        end
        convert(Ty,a).ty
    end
end

# takes the tuple returned as first argument of _methods
function code_for_method(metht, argtypes::ANY)
    meth = metht[3]
    func = meth.func
    tenv = metht[2]
    func = if meth.isstaged
        key = (meth, argtypes, tenv)
        if !haskey(_staged_cache, key)
            try
                func = ccall(:jl_instantiate_staged, Any,(Any,Any,Any), meth, Tuple{argtypes...}, tenv)
            catch
                return top(ConstCode{Ty})
            end                
            _staged_cache[key] = func
        else
            _staged_cache[key] :: Function
        end
    else
        func
    end
    ConstCode(Ty, code_from_ast(func.code, tenv, meth.sig), ())
end

# canonicalize those to function calls
# there are some special ast node and ccall in there
module OtherBuiltins
const new = :new_tag
const new_array = :new_array_tag
const new_array_1d = :new_array_1d_tag
const new_array_2d = :new_array_2d_tag
const new_array_3d = :new_array_3d_tag
const addressof = :addressof_tag
function isleaftype(x::ANY)
    ccall(:jl_is_leaf_type, Int32, (Any,), x)
end
end



eval_call_values!{L<:Lattice}(sched::Scheduler, t::Thread, sd::StateDiff, ::Type{L}, f, args) = top(L)

call_gate{T<:Lattice}(v::T) = top(T)
call_gate(v::Const) = isa(v.v, Type)? v : top(Const) # keep constant types for metaprogramming
call_gate(v::Union(Sign,Ty)) = v
call_gate(v::ConstCode) = v
call_gate(p::Prod) = prod(map(call_gate,p.values))
NOMETH = 0

function eval_call_code!{V,S}(sched::Scheduler{V,S},t::Thread,fcode,args::Vector{V},env, args_heap)
    child = Thread(0,1)
    args = map(call_gate, args)
    initial = InitialState(V, fcode)
    narg = length(fcode.args)
    if fcode.isva
        narg -= 1
        vargs = args[narg+1:end]
        vargs_heap = args_heap[narg+1:end]
        args = args[1:narg]
        args_heap = args_heap[1:narg]
    end
    if narg != length(args)
        DEBUGWARN && warn(@sprintf("Wrong arg count for %s : %s vs %s%s", fcode, fcode.args, args, fcode.isva ? " (vararg)" : ""))
        return
    end
    sd = StateDiff(child,V,V)
    for i = 1:narg
        argname = fcode.args[i]
        arg = args[i]
        if haskey(fcode.decl_types, argname)
            declty = fcode.decl_types[argname]
            if isa(declty,DataType) && declty.name === Type.name &&
                isa(declty.parameters[1],Type)
                arg = meet(arg, convert(V,Const(declty.parameters[1])))
            else
                arg = meet(arg, convert(V,Ty(declty)))
            end
        end
        initial.args[i] = arg
    end
    if fcode.isva
        tup = eval_call!(sched, child, sd, convert(V,Const(Base.tuple)), vargs, vargs_heap)
        @assert tup !== nothing
        initial.args[narg+1] = tup
    end
    for i=1:2:length(fcode.tvar_mapping)
        tv = fcode.tvar_mapping[i]
        tval = fcode.tvar_mapping[i+1]
        aval = if isa(tval,Type) || isa(tval,TypeVar)
            convert(V,Kind(tval))
        else
            convert(V,Const(tval))
        end
        initial.tenv[div(i+1,2)] = aval
    end
    length(env) == length(fcode.capt) || warn(@sprintf("Wrong env size %d vs %d : %s vs %s", length(env), length(fcode.capt), env, fcode.capt))
    for i=1:length(fcode.capt)
        val = i > length(env) ? top(V) : convert(V,env[i])
        initial.capt[i] = val
    end
    if t.fc > 0
        heap = sched.states.funs[t.fc].heap[t.pc]
    else
        heap = Set{Set{Any}}([Set{Any}([:global])])
    end
    for obj in heap
        nobj = Set{Any}()
        for (i,arg) in enumerate(args_heap)
            if arg in obj
                push!(nobj, Up(i))
            end
        end
        if :global in obj
            push!(nobj, :global)
        end
        push!(initial.heap, nobj)
    end
    #@show initial.heap

    # check for cached version of this call
    fc = 0
    for fc2 in 1:length(sched.funs)
        if sched.funs[fc2] === fcode
            if sched.states.initials[fc2] == initial
                fc = fc2
                break
            else
            end
        end
    end
    if fc == 0
        fc = register_fun!(sched, fcode, initial)
        child.fc = fc
        heappush!(sched.threads, child)
    end
    
    push!(t.wait_on, fc)
    t.fc > 0 && push!(sched.called_by[fc], (t.fc,t.pc))
    nothing
end

function eval_call!{V,S}(sched::Scheduler{V,S}, t::Thread, sd::StateDiff, fun::Int, args::Vector{Int})
    n = length(args)
    stack = Array(V, n)
    for i=1:n
        stack[i] = eval_local(sched.states,t.fc,t.pc,args[i])
    end
    f = eval_local(sched.states,t.fc,t.pc,fun)
    sd.value = eval_call!(sched, t, sd, f, stack, Any[args...])
end

function eval_call!{S,V}(sched::Scheduler{V,S}, t::Thread, sd::StateDiff, fun::V, args::Vector{V}, args_heap::Vector{Any})
    (isbot(fun) || any(isbot, args)) && (#=println("bot arg ", args); =#return bot(V))
    f = convert(Const,fun)
    if f <= Const(Base._apply)
        actual_args = V[]
        if args[2] <= Ty(Function) # handle the strange _apply semantics
            fun = args[2]
        else
            fun = args[1]
            push!(actual_args, args[2])
        end
        for i=3:length(args)
            if args[i] <= Ty(Tuple)
                l = convert(Const, eval_call_values!(sched, t, sd, V, convert(V,Const(Base.nfields)), V[args[i]]))
                istop(l) && return top(V)
                for k=1:l.v
                    push!(actual_args, eval_call_values!(sched, t, sd, V, convert(V,Const(Base.getfield)), V[args[i], convert(V,Const(k))]))
                end
            else # TODO handle other iterators
                # TODO also even when not known iterable replace (a0, ..., an, unknown, b0,...) with (a0, ..., an, vararg{join(...)}) : sometimes the method match is simple
                return top(V)
            end
        end
        args = actual_args
        args_heap = map(_ -> :global, actual_args)
    end
    
    # actually do the call
    
    cc = convert(ConstCode,fun)
    # known lambda
    if !istop(cc)
        eval_call_code!(sched, t, cc.v, args, cc.env, args_heap)
        return bot(V)
    end

    cf = convert(Const,fun)
    # generic function call
    if !istop(cf) && (isa(cf.v,Function) && isgeneric(cf.v) || !isa(cf.v,Function) && !isa(cf.v,IntrinsicFunction))
        f = cf.v
        if !isa(f,Function)
            f = getfield(sched.funs[t.fc].mod, :call) # call overloading
            unshift!(args, fun)
        end

        argtypes = to_signature(args)
        meths = Base._methods(f,argtypes,1)
        if meths !== false
            for meth in meths
                cc = code_for_method(meth, argtypes)
                istop(cc) && return top(V) # TODO unknown effects
                eval_call_code!(sched, t, cc.v, args, cc.env, args_heap)
            end
            return bot(V)
        else
            return top(V) # TODO unknown effects
        end
    end

    # either unknown or builtin
    if f <= Const(Base.throw) || f <= Const(Base.rethrow)
        must_throw!(sd, args[1])
        bot(V)
    else
        # canonicalize known ccalls
        if f <= Const(Base.ccall)
            # TODO add rethrow here instead of hijacking Base.rethrow
            known_ccall = # TODO make this less ugly
            (args[1] <= Const(:jl_new_array) ? OtherBuiltins.new_array :
             args[1] <= Const(:jl_alloc_array_1d) ? OtherBuiltins.new_array_1d :
             args[1] <= Const(:jl_alloc_array_2d) ? OtherBuiltins.new_array_2d :
             args[1] <= Const(:jl_alloc_array_3d) ? OtherBuiltins.new_array_3d :
             args[1] <= Const(:jl_is_leaf_type) ? OtherBuiltins.isleaftype : nothing)
            if known_ccall !== nothing
                args = args[4:end][1:2:end]
                fun = convert(V, Const(known_ccall))
            end
        end
        if f <= Const(Base._expr)
            fun = convert(V,Const(OtherBuiltins.new))
            unshift!(args, convert(V,Const(Base.Expr)))
        end
        result = eval_call_values!(sched, t, sd, V, fun, args)
        #=if !istop(convert(Const, fun)) && istop(result) && !any(istop, args)
        warn(@sprintf("Top result for %s %s", fun, args))
        end=#
        result
    end
end

function eval_new!{V}(sched::Scheduler, t::Thread, sd::StateDiff, args::V...)
    any(isbot, args) && return bot(V)
    sd.value = eval_call_values!(sched, t, sd, V, meet(top(V), Const(OtherBuiltins.new)), collect(args))
end

@generated function eval_call_values!{Ls}(sched::Scheduler, t::Thread, sd::StateDiff, ::Type{Prod{Ls}}, f::Prod{Ls}, args::Vector{Prod{Ls}})
    ex = :(top(Prod{Ls}))
    for L in Ls.types
        ex = :(meet($ex, eval_call_values!(sched, t, sd, $L, f, args)))
    end
    ex
end
#TODO rename this as const_funs or sthing
# TODO add intrinsics that can throw
const BITS_INTR = [Base.add_float,Base.add_int, Base.sub_int, Base.mul_int, Base.srem_int, Base.ctlz_int, Base.slt_int, Base.sle_int, Base.not_int,Base.apply_type, Base.issubtype, Base.tuple, Base.nfields, Core.sizeof, Base.fieldtype, Base.Union, Base.svec, OtherBuiltins.isleaftype, Base.is]
const BITS_FUNC = [+,+, -, *, %, leading_zeros, <, <=, !, Base.apply_type, Base.issubtype, Base.tuple, Base.nfields, Core.sizeof, Base.fieldtype, Base.Union, Base.svec, OtherBuiltins.isleaftype, Base.is]
@assert length(BITS_INTR) == length(BITS_FUNC)
function eval_call_values!{V}(sched::Scheduler, t::Thread, sd::StateDiff, ::Type{Sign}, f::V, args::Vector{V})
    if (f <= Const(Base.unbox) || f <= Const(Base.box))
        return convert(V,convert(Sign,args[2]))
    end
    # sign add
    if f <= Const(Base.add_int) || f <= Const(Base.checked_sadd)
        length(args) == 2 || return bot(V)
        args[1] <= Sign(0) && args[2] <= Sign(0) && return convert(V,Sign(0)) # +(0 0) = 0
        for sgn in (-1,1) # (+|0)+(+|0) == + and (-|0)+(-|0) == -
            (args[1] <= Sign(sgn) || args[1] <= Sign(0)) &&
            (args[2] <= Sign(sgn) || args[2] <= Sign(0)) &&
            return convert(V,Sign(sgn))
        end
    end
    # sign sub
    if f <= Const(Base.sub_int) || f <= Const(Base.checked_ssub)
        length(args) == 2 || return bot(V)
        args[1] <= Sign(0) && args[1] <= Sign(0) && return convert(V,Sign(0))
        for sgn in (-1,1)
            (args[1] <= Sign(sgn) || args[1] <= Sign(0)) &&
            (args[2] <= Sign(-sgn) || args[2] <= Sign(0)) &&
            return convert(V,Sign(sgn))
        end
    end
    # sign comparison
    is_sle = f <= Const(Base.sle_int)
    is_slt = f <= Const(Base.slt_int)
    if (is_sle || is_slt) && length(args) == 2
        sa, sb = convert(Sign,args[1]), convert(Sign,args[2])
        if !(istop(sa) || istop(sb) || sa.s == sb.s)
            return convert(V, Const(is_sle ? (sa.s <= sb.s) : sa.s < sb.s))
        end
    end

    top(V)
end

function intrinsic_name(cv)
    intrname = string(cv)
    for fn in names(Core.Intrinsics)
        intr = Core.Intrinsics.(fn)
        if intr === cv
            intrname = string(fn)
            break
        end
    end
    intrname
end

# TODO add exception info
const INTR_TYPES = [
                    (Bool, [Base.slt_int, Base.sle_int, Base.not_int, Base.is, Base.ne_float, Base.lt_float, Base.ule_int, Base.ult_int, Base.le_float, Base.eq_float, Base.isdefined, Base.fpiseq, Base.fpislt]),
                    (Int,[Core.sizeof]),
                    (DataType, [Base.fieldtype]),
                    (Union{DataType,Union},[Base.apply_type]),
                    (UnionType, [Base.Union]),
                    (SimpleVector, [Base.svec]),
                    (Any,[Core.eval]),
                    (Int32, [OtherBuiltins.isleaftype])
                    ]
const FA_INTR = [Base.trunc_int, Base.sext_int, Base.zext_int, Base.checked_trunc_uint, Base.checked_trunc_sint, Base.uitofp, Base.sitofp, Base.fptosi, Base.box, Base.unbox, OtherBuiltins.new, Base.checked_fptosi, Base.checked_fptoui]

function eval_call_values!{V}(sched::Scheduler, t::Thread, sd::StateDiff, ::Type{Ty}, f::V, args::Vector{V})
    if length(args) >= 1
        for bf in FA_INTR
            if f <= Const(bf)
                cty = convert(Const, args[1])
                istop(cty) && return top(V)
                return convert(V, Ty(cty.v))
            end
        end
    end
    
    # cglobal and typassert take the return type as second argument ...
    if f <= Const(Base.cglobal)
        cty = convert(Const, args[2])
        istop(cty) && return top(V)
        return convert(V, Ty(cty.v))
    end
    if f <= Const(Base.typeassert)
        cty = convert(Kind, args[2])
        istop(cty) && return top(V) #TODO Typevar
        return meet(args[1],convert(V, cty.ub))
    end
    if  f <= Const(OtherBuiltins.new_array) ||
        f <= Const(OtherBuiltins.new_array_1d) ||
        f <= Const(OtherBuiltins.new_array_2d) ||
        f <= Const(OtherBuiltins.new_array_3d)
        aty = convert(Const, args[1])
        istop(aty) && return convert(V,Ty(Array))
        return convert(V, Ty(aty.v))
    end
    argtypes = map(a->convert(Ty,a),args)
    for (retty,intrs) in INTR_TYPES
        for bf in intrs
            if f <= Const(bf)
                return convert(V, Ty(retty))
            end
        end
    end
    if f <= Const(Base.select_value)
        return convert(V,reduce(join, args[2:end]))
    end
    if f <= Const(Base.typeof)
        return convert(V,Kind(argtypes[1].ty))
    end
    if f <= Const(Base.tuple)
        return convert(V,Ty(Tuple{map(a->a.ty,argtypes)...}))
    end
    if f <= Const(Base.arraylen) || f <= Const(Base.arraysize)
        return convert(V, Ty(Int))
    end
    if f <= Const(Base.nfields)
        tty = argtypes[1].ty
        (isleaftype(tty) || tty <: Tuple) && return convert(V, Const(length(tty.types)))
        return convert(V, Ty(Int))
    end
    if f <= Const(Base.getfield)
        aty = argtypes[1].ty
        aty === Module && return top(V)
        istuple = aty <: Tuple
        (isa(aty,UnionType) || aty.abstract) && return top(V) #TODO could do better here
        len = length(aty.types)
        isva = istuple && len > 0 && aty.types[end] <: Vararg
        isva && (len -= 1)
        fld = convert(Const, args[2])
        if istop(fld) # non constant field
            types = map(Ty,isva ? aty.types[1:end-1] : aty.types)
            return convert(V,foldl(join, isva ? Ty(aty.types[end].parameters[1]) : bot(Ty), types))
        else # constant field
            fldv = fld.v
            fidx = if isa(fldv, Symbol) && !istuple
                findfirst(fieldnames(aty), fldv)
            elseif isa(fldv, Int)
                fldv
            else
                0
            end
            1 <= fidx || (must_throw!(sd,Ty(BoundsError)); return bot(V))
            isva || fidx <= len || (must_throw!(sd,Ty(BoundsError)); return bot(V))
            ftyp = fidx <= len ? aty.types[fidx] : aty.types[end].parameters[1]
            return convert(V, Ty(ftyp))
        end
    end
    if f <= Const(Base.setfield!)
        # TODO return bot for wrong fields
        return args[3]
    end
    if f <= Const(Base.ccall)
        retty = convert(Const,args[2])
        istop(retty) || return convert(V,Ty(retty.v))
    end
    if f <= Const(Base.typeassert)
        typ = convert(Const, args[2])
        istop(typ) && return top(V)
        return convert(V, Ty(typ.v))
    end
    if f <= Const(Base.arrayref)
        argtypes[1] <= Ty(Array) || return top(V)
        aty = argtypes[1].ty
        resty = bot(Ty)
        if isa(aty, UnionType)
            for aty in aty.types
                @assert(isa(aty,DataType) && aty.name === Array.name)
                resty = join(resty, Ty(aty.parameters[1]))
            end
        elseif isa(aty,DataType) && aty.name === Array.name
            resty = Ty(aty.parameters[1])
        else
            @assert(false, "What is this type $aty")
        end
        return convert(V,resty)
    end
    if f <= Const(Base.arrayset)
        return args[1]
    end
    if f <= Const(Base.isa)
        cty = convert(Kind,args[2])
        istop(cty) && return top(V)
        isa_ty = cty.ub
        argtypes[1] <= isa_ty && return convert(V, Const(true))
        isbot(meet(argtypes[1], isa_ty)) && return convert(V, Const(false))
        return convert(V, Ty(Bool))
    end
    if f <= Const(Base.pointerref)
        argtypes[1] <= Ty(Base.Ptr) || return top(V)
        return convert(V, Ty(argtypes[1].ty.parameters[1]))
    end

    if DEBUGWARN
        if f <= Ty(IntrinsicFunction)
            cv = convert(Const,f).v
            intrname = intrinsic_name(cv)
            warn(@sprintf("Unknown intrinsic %s with args %s", intrname, args))
            return top(V)
        end
        if !istop(convert(Const,f))
            fv = convert(Const,f)
            isdefined(fv,:code) && fv.code.name === :anonymous && return top(V)
            warn(@sprintf("Unknown builtin type %s %s with args %s", f, args, f))
        end
    end
    top(V)
end

function eval_call_values!{V}(sched::Scheduler, t::Thread, sd::StateDiff, ::Type{Const}, f::V, args::Vector{V})
    # only evaluate when every argument is constant
    cargs = map(a -> convert(Const, a), args)
    (istop(f) || any(a -> istop(a), cargs)) && return top(V)

    # bits functions
    for (bf,rf) in zip(BITS_INTR,BITS_FUNC)
        if f <= Const(bf)
            argvals = map(a -> a.v, cargs)
            res = bot(Const)
            try
                res = Const(rf(argvals...))
            catch exc
                warn("thrown calling ", f, " ", argvals)
                must_throw!(sd, Ty(typeof(exc))) # TODO could be more precise here
            end
            return convert(V,res)
        end
    end

    # module.const
    if f <= Const(Base.getfield) && isa(cargs[1].v, Module)
        mod = cargs[1].v
        name = cargs[2].v
        isa(name, Symbol) || return (must_throw!(sd,Ty(TypeError)); bot(V)) # module only supports symbol indexing
        isconst(mod, name) || return top(V) # non const global
        return convert(V,Const(eval(mod,name)))
    end

    # immutable.const (types are immutable for all intent and purposes)
    if f <= Const(Base.getfield)
        isimmutable(cargs[1].v) || isa(cargs[1].v, Type) || return top(V)
        v = cargs[1].v
        name = cargs[2].v
        if (isa(name,Symbol) || isa(name,Int))
            if  isdefined(v, name)
                return convert(V,Const(getfield(v, name)))
            else
                must_throw!(sd, top(Ty)) # TODO not correct
                return bot(V)
            end
        else
            must_throw!(sd, Ty(TypeError))
            return bot(V)
        end
    end

    if f <= Const(OtherBuiltins.new) # TODO consider which class of types are safe to construct here
        return top(V)
    end

    if DEBUGWARN
        if f <= Ty(IntrinsicFunction)
            cv = convert(Const,f).v
            intrname = intrinsic_name(cv)
            warn(@sprintf("Unknown intrinsic const %s with args %s", intrname, args))
            return top(V)
        end
        if !(f <= Const(Base.isa)) && !(f <= Const(Base.typeassert))
            warn(@sprintf("Unknown builtin const %s with args %s", f, args))
        end
    end
    top(V)
end
function eval_call_values!{V}(sched::Scheduler, t::Thread, sd::StateDiff, ::Type{Birth}, f::V, args::Vector{V})
    if  f <= Const(OtherBuiltins.new) ||
        f <= Const(OtherBuiltins.new_array) ||
        f <= Const(OtherBuiltins.new_array_1d) ||
        f <= Const(OtherBuiltins.new_array_2d) ||
        f <= Const(OtherBuiltins.new_array_3d)
        sd.heap_use = :new
        return convert(V,Birth(t.fc,t.pc))
    end
    top(V)
end

function eval_call_values!{V,EV}(sched::Scheduler, t::Thread, sd::StateDiff, ::Type{ConstCode{EV}}, f::V, args::Vector{V})
    if f <= Const(OtherBuiltins.new)
        ty = convert(Const, args[1])
        (istop(ty) || ty.v !== Function) && return top(V)
        code = convert(Const, args[2])
        istop(code) && return top(V)
        actual_code = code_from_ast(code.v, (), Tuple)
        # TODO the env evaluation should be part of the expr tree
        #env = map!(capt_var -> convert(EV,eval_local(sched.states,t.fc,t.pc, capt_var)), Array(EV, length(actual_code.capt)), actual_code.capt)
        env = map(capt -> convert(EV,capt), args[3:end])
        return convert(V,ConstCode(EV, actual_code, tuple(env...)))
    end
    top(V)
end

function eval_assign!{V}(sched,sd,code,name,res::V,saval::Int)
    if name in code.locals || isa(name,GenSym)
        push!(sd.locals, LocalStateDiff(name, res, saval))
        sd.value = res
    else
        # TODO unknown effects
    end
    nothing
end

function eval_sym!{V}(sched::Scheduler{V},t,sd,code,e)
    if e in code.locals || isa(e,GenSym)
        ls = sched.states.funs[t.fc]
        val = eval_local!(ls, sd, t.pc, e)
        sd.value = val
    elseif isa(e,Symbol) && isconst(code.mod,e)
        sd.value = convert(V, Const(getfield(code.mod,e)))
    else
        may_throw!(sd, Ty(UndefVarError))
        sd.value = top(V) # global
    end
end
StateDiff(t,LV,TV) = StateDiff{LV,TV}(t,Array(LocalStateDiff{LV},0), -1, Array(Int,0), bot(LV), bot(TV), false, :global)
function Base.copy{V,TV}(sd::StateDiff{V,TV})
    StateDiff{V,TV}(sd.t, copy(sd.locals), sd.sa_name, copy(sd.lost), sd.value, sd.thrown, sd.must_throw, sd.heap_use)
end

function may_throw!(sd :: StateDiff, v)
    sd.thrown = join(sd.thrown, v)
end

function must_throw!(sd :: StateDiff, v)
    sd.thrown = join(sd.thrown, v)
    sd.must_throw = true
end

function step!{V,S}(sched::Scheduler{V,S}, t::Thread, conf::Config)
    TRACE = GTRACE
    code = sched.funs[t.fc]
    sd = StateDiff(t,V,V)
    
    TRACE && println("Step thread ",t.fc, ":", t.pc)
    next_pc = branch_pc = t.pc+1
    e = code.body[t.pc]

    if !isempty(t.wait_on)
        ncycled = 0
        final = bot(FinalState{V})
        for i = 1:length(t.wait_on)
            wait_on = t.wait_on[i]
            join!(final, sched.states.finals[wait_on])
            if !sched.done[wait_on] # cycle
                ncycled += 1
                t.wait_on[ncycled] = wait_on
            end
        end
        resize!(t.wait_on, ncycled)
        if ncycled > 0
            ft = fork(sched, t)
            ft.wait_on = t.wait_on
            t.wait_on = Array(Int,0)
            ft.cycle += 1
        end
        # TODO move into function
        if final.must_throw
            must_throw!(sd, final.thrown)
        else
            may_throw!(sd, final.thrown)
        end
        sd.value = final.ret_val
#        sd.heap_use = 
        if isbot(sd.value)
            #println("returned bot in $(t.fc) $code :")
            #show_dict(STDOUT, sched.states[t.fc,1])
        end
        #println("Returned heap : $(final.heap) from")
        for obj in final.heap
            
        end
    elseif isa(e, Expr) && (e.head === :call || e.head === :call1 || e.head === :new)
        args = code.call_args[t.pc]
        if e.head === :new
            args = map(i -> eval_local(sched.states,t.fc,t.pc,i), code.call_args[t.pc])
            eval_new!(sched, t, sd, args...)
        else
            eval_call!(sched, t, sd, args[1], args[2:end])
        end
    elseif isa(e, LocalName)
        if e === :UNKNOWN
            sd.value = top(V)
        else
            eval_sym!(sched, t, sd, code, e)
        end
    elseif isa(e,Expr) && e.head === :return
        sd.value = eval_local(sched.states,t.fc,t.pc,code.call_args[t.pc][1])
        sd.heap_use = code.call_args[t.pc][1]
        next_pc = branch_pc = length(code.body)+1
    elseif isa(e,GotoNode)
        next_pc = branch_pc = code.label_pc[e.label::Int+1]
        sd.value = convert(V,Const(nothing))
    elseif isa(e,Expr) && e.head === :gotoifnot
        branch_pc = code.label_pc[e.args[2]::Int+1]
        sd.value = eval_local(sched.states,t.fc,t.pc,code.call_args[t.pc][1])
        if isbot(sd.value)
            #warn("branch on bot")
            next_pc = branch_pc = length(code.body)+1
        elseif sd.value <= Const(true)
            branch_pc = next_pc
        elseif sd.value <= Const(false)
            next_pc = branch_pc
        end
    elseif isa(e,Expr) && e.head === :(=)
        @assert next_pc == branch_pc
        val = eval_local(sched.states,t.fc,t.pc,code.call_args[t.pc][1])
        eval_assign!(sched, sd, code, e.args[1]::LocalName, val, code.call_args[t.pc][1])
    elseif isa(e,Expr) && e.head == :enter
        push!(t.eh_stack, code.label_pc[e.args[1]::Int+1])
        sd.value = convert(V,Const(nothing))
    elseif isa(e,Expr) && e.head == :leave
        for i=1:(e.args[1]::Int)
            pop!(t.eh_stack)
        end
        sd.value = convert(V,Const(nothing))
    elseif isa(e,Expr) && e.head in (:line,:boundscheck,:meta,:simdloop) || isa(e,LineNumberNode) || isa(e,LabelNode)
        sd.value = convert(V,Const(nothing))
    elseif isa(e,Expr)
        dump(e)
        error("unknown expr")
    else
        if isa(e, TopNode)
            e = getfield(ccall(:jl_base_relative_to, Any, (Any,), code.mod)::Module,e.name)
        elseif isa(e, QuoteNode)
            e = e.value
        end
        sd.value = convert(V,Const(e))
    end
    if !isempty(t.wait_on)
        return
    end
    sd.sa_name = t.pc
    
    TRACE && (print("> ");Meta.show_sexpr(e);println("  →  ", sd.value, "\n"))
    
    could_throw = !isbot(sd.thrown)
    must_throw = sd.must_throw
    
    branch_sd = sd
    if could_throw
        @assert next_pc == branch_pc == t.pc+1 # branching cannot throw
        exc_sd = LocalStateDiff(:the_exception, convert(V,sd.thrown), -1)
        handler = isempty(t.eh_stack) ? length(code.body)+1 : t.eh_stack[end]
        branch_pc = handler
        if must_throw
            next_pc = handler
            push!(sd.locals, exc_sd)
            sd.value = bot(V)
        else
            branch_sd = copy(sd)
            branch_sd.value = bot(V)
            push!(branch_sd.locals, exc_sd)
        end
        if handler in code.label_pc
            ls = sched.states.funs[t.fc]
            ls.dtree = add_edge!(code, ls.dtree, t.pc, findfirst(code.label_pc, handler))
        elseif handler != length(code.body)+1
            error("????")
        end
    end
    #=if !must_throw
        values[t.fc,t.pc] = res
    end=#

    chgd = propagate!(sched.states, t.fc, t.pc, next_pc, sd)

    if next_pc != branch_pc
        branch_chgd = propagate!(sched.states, t.fc, t.pc, branch_pc, branch_sd)
        if (chgd || branch_chgd) && branch_pc <= length(code.body)
            ft = fork(sched, t, branch_pc)
        end
    end
    
    if !chgd
        next_pc = length(code.body)+1
    end
    
    t.pc = next_pc
    nothing
end

Base.done(s::Scheduler,t::Thread) = t.pc > length(s.funs[t.fc].body)
Base.done(s::Scheduler) = isempty(s.threads)
function Base.isless(t::Thread,t2::Thread)
    t.fc < t2.fc && return false
    t.fc > t2.fc && return true
    t.cycle > t2.cycle && return false
    t.cycle < t2.cycle && return true
    ie = isempty(t.wait_on)
    ie2 = isempty(t2.wait_on)
    !ie && ie2 && return false
    ie && !ie2 && return true
    t.pc > t2.pc && return false
    t.pc < t2.pc && return true
    false
end
function step!(s::Scheduler)
    isempty(s.threads) && return (0, 0)
    t = heappop!(s.threads)
    while !isempty(s.threads)
        t2 = heappop!(s.threads)
        if t2.fc == t.fc && t2.pc == t.pc && t2.cycle == t.cycle
            append!(t.wait_on, t2.wait_on)
        else
            heappush!(s.threads, t2)
            break
        end
    end
    k = 0
    tpc = -1
    try
        tpc = t.pc
        step!(s, t, s.config)
    catch x
        println("Exception while executing ", t, " :")
        println(x)
        println("Function : ", s.funs[t.fc])
        rethrow(x)
    end
    if done(s,t)
        fc = t.fc
        t.pc = length(s.funs[fc].body) + 1
        push!(s.done_threads,t)
        
        same_func = Array(Int,0)
        for i in 1:length(s.threads)
            if s.threads[i].fc == fc
                push!(same_func, i)
            end
        end
        
        isdone = isempty(same_func)
        mincycle = isdone ? -1 : minimum(Int[s.threads[i].cycle for i in same_func])
        if !isdone && mincycle > t.cycle
            isdone = mincycle > s.states.finals[fc].last_cycle
        end
        GTRACE && println("THREAD FINISHED ", s.funs[t.fc], " : ", s.states.finals[t.fc],  "================")
        if isdone
            GTRACE && println("FUN FINISHED $(t.fc) $(s.funs[t.fc])", s.states.finals[t.fc])
            if !isempty(same_func)
                deleteat!(s.threads, same_func)
                heapify!(s.threads)
            end
            s.done[t.fc] = true
            fill!(s.states.funs[t.fc].changed, false)
        end
    else
        heappush!(s.threads, t)
    end
    t.fc, tpc
end
LIM = Inf
function run(s::Scheduler; verbose = false)
    nstep = 0
    maxthread = length(s.threads)
    while !done(s) && nstep < LIM
        step!(s)
        maxthread = max(maxthread, length(s.threads))
        if verbose && nstep % 10000 == 0
            println("... (", maxthread, ", ", length(s.funs), ")")
        end
        nstep += 1
    end
    nstep, maxthread
end
function Base.show(io::IO, s::Scheduler)
    println(io, "====== scheduler (", length(s.threads), " active threads, ", length(s.funs), " functions):")
    page_out = isa(io, Base.Terminals.TTYTerminal)
    fcs = Int[t.fc for t in s.threads]
    dfcs = Int[t.fc for t in s.done_threads]
    nthr = Dict([u => length(findin(fcs,u)) for u in unique(fcs)])
    dnthr = Dict([u => length(findin(dfcs,u)) for u in unique(dfcs)])
    for (k,v) in enumerate(s.funs)
        println(io, "==== fun ", k, ": ", v)
        println(io, "threads : ", get(nthr,k,0), " active, ", get(dnthr,k,0), " done")
        callers = map(cfc -> (s.funs[cfc[1]], cfc[2]), collect(s.called_by[k]))
        println(io, "called by : ")
        for (fun, pc) in callers
            println(io, "\t- ", fun, " at ", pc)
        end
        println(io, "final : ", s.states.finals[k])
        println(io, "initial : ")
        show_dict(io, s.states[k, 1])
        page_out && (k % 30 == 0) && read(STDIN, Char)
    end
    println(io, "======")
end

function linearize_stmt!(stmt,body,args_pc)
    if isa(stmt,Expr) && stmt.head in (:call,:call1,:new)
        pcs = Int[]
        for arg in stmt.args
            linearize_stmt!(arg, body, args_pc)
            push!(pcs, length(body))
        end
        push!(body,stmt)
        push!(args_pc, pcs)
    elseif isa(stmt,Expr) && stmt.head === :(=)
        linearize_stmt!(stmt.args[2],body,args_pc)
        apc = length(body)
        push!(body,stmt)
        push!(args_pc, [apc])
    elseif isa(stmt,Expr) && stmt.head in (:return, :gotoifnot)
        linearize_stmt!(stmt.args[1],body,args_pc)
        apc = length(body)
        push!(body,stmt)
        push!(args_pc, [apc])
    elseif isa(stmt,SymbolNode)
        push!(body,stmt.name)
        push!(args_pc,Int[])
    elseif isa(stmt,Expr) && stmt.head === :copyast
        push!(body,stmt.args[1])
        push!(args_pc,Int[])
    elseif isa(stmt,Expr) && (stmt.head === :& || stmt.head === :const) # TODO this is not correct
        linearize_stmt!(stmt.args[1], body, args_pc)
    elseif isa(stmt,Expr) && stmt.head in (:type_goto, :static_typeof)
        error("type_goto/static_typeof are not supported (and never will ?)")
    elseif isa(stmt,Expr) && stmt.head === :the_exception
        push!(body, :the_exception) # TODO name collision, make this a proper part of state
        push!(args_pc,Int[])
    elseif isa(stmt,LambdaStaticData)
        push!(body,Function) # canonicalize inline ASTs into :
        push!(args_pc,Int[])    # new(Function, ast, env...)
        push!(body,stmt)
        push!(args_pc,Int[])
        capts = capt_from_ast(stmt)
        for capt in capts
            push!(body, capt)
            push!(args_pc,Int[])
        end
        push!(args_pc, Int[((length(body)-1-length(capts)):length(body))...])
        push!(body, Expr(:new, Function, stmt, capts...))
    else
        push!(body,stmt)
        push!(args_pc,Int[])
    end
end

function eval_typ_in(ty, tenv)
    if isa(ty,TypeVar)
        if ty.bound
            idx = findfirst(tenv,ty)
            @assert idx > 0
            tenv[idx+1]
        else
            ty
        end
    elseif isa(ty,DataType)
        args = Any[ty.parameters...]
        for i = 1:length(args)
            args[i] = eval_typ_in(args[i], tenv)
        end
        Base.apply_type(ty.name.primary, args...)
    else
        ty
    end
end
const HIT = [0,0,0]
const _code_cache = ObjectIdDict()#Dict{Any,Code}()
const SR = []

function capt_from_ast(ast)
    if !isa(ast,Expr)
        ast = Base.uncompressed_ast(ast)
    end
    capt = Array(Symbol, 0)
    for varinfo in ast.args[2][2] # captured
#        @show varinfo
        name = varinfo[1]
        push!(capt, name)
    end
    capt
end
function code_from_ast(linf,tenv,sig::ANY)
    TRACE = GTRACE
    key = (linf,tenv) # TODO svec don't hash correctly with tvars ?
    haskey(_code_cache, key) && return (_code_cache[key]::Code)
    fun_name = linf.name
    mod = linf.module
    ast = Base.uncompressed_ast(linf)
    TRACE && @show ast
    orig_body = ast.args[3].args

    body = Any[]
    args_pc = Vector{Int}[]
    sizehint!(body,length(orig_body))
    sizehint!(args_pc,length(orig_body))
    for stmt in orig_body
        linearize_stmt!(stmt, body, args_pc)
    end
    #=for (i,(b,apc)) in enumerate(zip(body,args_pc))
        println(i, ") ", b, " -- ", apc)
    end=#
    
    # TODO ask Jeff if this is the easiest way to sort out this mess
    # probably not
    locs = Set{LocalName}()
    for loc in ast.args[2][1]
#        @show loc
        push!(locs, loc[1])
    end
    isva = false
    args = map(ast.args[1]) do a
        if isa(a, Expr) && a.head === :(::) # TODO ugh
            if isa(a.args[2],Expr) && (a.args[2].head === :call && a.args[2].args[1] === TopNode(:apply_type) && a.args[2].args[2] === :Vararg ||
                                       a.args[2].head === :(...))
                isva = true
            end
            a.args[1]
        elseif isa(a, Symbol)
            a
        else
            dump(a)
            error("arg ? " * string(a))
        end
    end
    decltypes = Dict{LocalName,Any}()
    sigtypes = sig.types
    for argn = 1:length(args)
        ty = sigtypes[min(argn,end)]
        ty = ty <: Vararg ? ty.parameters[1] : ty
        isva && argn==length(args) && (ty = Tuple{Vararg{ty}})
        decltypes[args[argn]] = eval_typ_in(ty, tenv)
    end
    if isva
        decltypes[args[end]] = Tuple{sigtypes[end]}
    end
    capt = capt_from_ast(ast)
    union!(locs,args)
    union!(locs,capt)
    push!(locs, :the_exception, :UNKNOWN) #TODO ugh

    label_pc = Array(Int, 0)
    gensy = Set{Int}()
    notsa = Set{Symbol}()
    sa = Set{Symbol}()
    for pc = 1:length(body)
        if isa(body[pc], LabelNode)
            lnum = body[pc].label+1
            if lnum > length(label_pc)
                l = length(label_pc)
                resize!(label_pc, lnum)
                label_pc[l+1:end] = -1
            end
            label_pc[lnum] = pc
        end
        if isa(body[pc],GenSym)
            push!(gensy,body[pc].id)
        end
        if isa(body[pc],Expr) && body[pc].head === :(=)
            v = body[pc].args[1]
            if v in locs && !(v in notsa)
                if v in sa
                    delete!(sa,v)
                    push!(notsa,v)
                else
                    push!(sa,v)
                end
            end
        end
    end
    
    HIT[1] += length(gensy)
    HIT[2] += length(locs)
    HIT[3] += length(sa)

    c = Code(mod, fun_name, body, args_pc, label_pc, locs, args, isva, tenv, capt, decltypes)
    for i=1:2:length(tenv)
        push!(c.locals, tenv[i].name)
    end
    _code_cache[key] = c
    c
end

const _staged_cache = ObjectIdDict()#Dict{Any,Any}()


function print_code(io, sched, fc)
    c = sched.funs[fc]
    ls = sched.states.funs[fc]
    for i=1:length(c.body)
        print(io, i, "| ")
        Meta.show_sexpr(io, c.body[i])
        print(io, " \t")
        print(io, ls.sa[i])
        print(io, "\t[")
        for obj in ls.heap[i]
            for var in obj
                print(io, var, " ")
            end
            print(io, ", ")
        end
        print(io, "]")
              #=for li in 1:length(ls.locals)
            ls.
        end=#
        println()
    end
end
print_code(sched,fc) = print_code(STDOUT,sched,fc)

export Prod,Sign,Const,Ty,Birth,Thread,FunctionState,Scheduler,Code,ExprVal,FinalState,ConstCode,LocalStore,State, isbot, istop, Kind, Lattice, Config,Stats,Analysis,InitialState

# == client

module Analysis
using GreenFairy
const ValueTup = (Const,Ty,Kind,Sign,Birth,ConstCode{Ty})
const ValueT = Prod{Tuple{ValueTup...}}
const (MValueT,CellT) = GreenFairy.make_mprod(ValueTup)
const FinalT = FinalState{ValueT}
const InitT = InitialState{ValueT}
make_sched(conf) = Scheduler{ValueT,State{ValueT,InitT,FinalT}}(State(ValueT,InitT,FinalT),Array(Bool,0),Array(Thread,0),Array(Thread,0),conf,Array(Set{Any},0),Array(Code,0))
end

immutable Stats
    n_iteration
    max_concurrent_threads
    total_time
    n_funs
end

function Base.show(io::IO, s::Stats)
    dt = s.total_time
    niter = s.n_iteration
    maxthr = s.max_concurrent_threads
    @printf(io, "Analysis completed in %.2f s\n", dt)
    @printf(io, "\t%d max concurrent threads\n", maxthr)
    if niter >= 1000
        @printf(io, "\t%.2f K iterations\n", niter/1000)
    else
        @printf(io, "\t%d iterations\n", niter)
    end
    @printf(io, "\t%.2f Kit/s\n", (niter/1000)/dt)
    @printf(io, "\t%d functions interpreted", s.n_funs)
end

function init(f::Function, args)
    global LAST_SC
    sched = LAST_SC = Analysis.make_sched(Config(:always))
    args = map(args) do a
        if isa(a,Tuple)
            foldl(meet, top(Analysis.ValueT), a)
        else
            convert(Analysis.ValueT, a)
        end
    end
    empty!(_code_cache)
    t = Thread(0,0)
    eval_call_values!(sched, t, StateDiff(t,Analysis.ValueT,Ty), convert(Analysis.ValueT,Const(f)), Analysis.ValueT[args...])
    sched
end

function run(f::Function, args)
    global LAST_SC
    sched = LAST_SC = Analysis.make_sched(Config(:always))
    args = map(args) do a
        if isa(a,Tuple)
            foldl(meet, top(Analysis.ValueT), a)
        else
            convert(Analysis.ValueT, a)
        end
    end
    empty!(_code_cache)
    t = Thread(0,0)
    eval_call!(sched, t, StateDiff(t,Analysis.ValueT,Ty), convert(Analysis.ValueT,Const(f)), Analysis.ValueT[args...], Any[:global for _ in args])
    dt = @elapsed begin
        niter,maxthr = run(sched)
    end
    sched, Stats(niter, maxthr, dt, length(sched.funs))
end
global ntests
function start_test()
    global ntests
    ntests = 0
end
function test(after::Function, f::Function, args...)
    global ntests
    s, stats = run(f, args)
    after(s.states.finals[1])
    @show stats
    #@show s.states.finals[1].ret_val
    ntests += 1
end
function end_test()
    global ntests
    @printf("all good (%d tests)\n", ntests)
end

function RUN(F::Function,args::ANY)
    sched = Analysis.make_sched(Config(:always))
    eval_call_gf!(sched, Thread(0,0), F, map(a->convert(Analysis.ValueT, Ty(a)), args))
    dt = @elapsed begin
        niter,maxthr = run(sched, verbose=true)
    end
    println("Finished in ", niter, " ", maxthr, " threads :")
    @printf("Speed %.2f Kit/s for %.2f s\n", (niter/1000)/dt, dt)
    #println("Result : ", sched.final[1])
    #read(STDIN,Char)
    sched
end

end
