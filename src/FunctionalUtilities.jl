__precompile__()
module FunctionalUtilities

import Base.==

include("FunctionalCore.jl")

include("BitmappedVectorTrie.jl")

include("PersistentVector.jl")

const PVector = PersistentVector
const pvec = PersistentVector

export PersistentVector, PVector, pvec,
       append, push, assoc, peek, pop

include("PersistentDict.jl")

const PDict = PersistentAutoDict

export PersistentArrayDict, PersistentHashDict, PersistentAutoDict, PDict,
       assoc, dissoc

include("PersistentSet.jl")

const PSet = PersistentSet

export PersistentSet, PSet,
       disj

include("PersistentList.jl")

const PList = PersistentList

export PersistentList, PList, EmptyList, cons, .., head, tail

include("PersistentQueue.jl")

const PQueue = PersistentQueue

export PersistentQueue, PQueue, queue, enq

include("ImmutableRef.jl")

export ImmutableRef, Promise, Delay, deliver, isrealized

include("LazyDict.jl")

const LDict = LazyDict

export LazyDict, LDict, islazy


export @Persistent

fromexpr(ex::Expr, ::Type{pvec}) = :(pvec($(esc(ex))))
fromexpr(ex::Expr, ::Type{pset}) = :(pset($(map(esc, ex.args[2:end])...)))
function fromexpr(ex::Expr, ::Type{phmap})
    kvtuples = [:($(esc(kv.args[end-1])), $(esc(kv.args[end])))
                for kv in ex.args[2:end]]
    :(phmap($(kvtuples...)))
end

using Base.Meta: isexpr
macro Persistent(ex)
    if isexpr(ex, [:vcat, :vect])
        fromexpr(ex, pvec)
    elseif isexpr(ex, :call) && ex.args[1] === :Set
        fromexpr(ex, pset)
    elseif isexpr(ex, :call) && ex.args[1] === :Dict
        fromexpr(ex, phmap)
    else
        error("Unsupported @Persistent syntax")
    end
end

################################################################################
# Definitions for freeze, deepfreeze_internal, thaw, and deepthaw_internal

# #TODO These are wrong; actively under development...

#deepfreeze_internal
deepfreeze_internal(x::Core.SimpleVector, stackdict::IdDict) = begin
    haskey(stackdict, x) && return stackdict[x]
    y = PVector(Any[deepfreeze_internal(x[i], stackdict) for i = 1:length(x)]...)
    stackdict[x] = y
    return y
end
deepfreeze_internal(x::Array, stackdict::IdDict) = begin
    haskey(stackdict, x) && return stackdict[x]
    _deepfreeze_array_t(x, eltype(x), stackdict)
end
_deepfreeze_array_t(@nospecialize(x), T, stackdict::IdDict) = begin
    isbitstype(T) && return (stackdict[x]=freeze(x))
    y = PVector(Any[deepfreeze_internal(x[i], stackdict) for i = 1:length(x)]...)
    
    dest = similar(x)
    stackdict[x] = dest
    for i = 1:(length(x)::Int)
        if ccall(:jl_array_isassigned, Cint, (Any, Csize_t), x, i-1) != 0
            xi = ccall(:jl_arrayref, Any, (Any, Csize_t), x, i-1)
            if !isbits(xi)
                xi = deepfreeze_internal(xi, stackdict)
            end
            ccall(:jl_arrayset, Cvoid, (Any, Any, Csize_t), dest, xi, i-1)
        end
    end
    return dest
end
function deepfreeze_internal(x::Union{Dict,IdDict}, stackdict::IdDict)
    if haskey(stackdict, x)
        return stackdict[x]::typeof(x)
    end

    if isbitstype(eltype(x))
        return (stackdict[x] = copy(x))
    end

    dest = empty(x)
    stackdict[x] = dest
    for (k, v) in x
        dest[deepfreeze_internal(k, stackdict)] = deepfreeze_internal(v, stackdict)
    end
    dest
end

end # module FunctionalUtilities
