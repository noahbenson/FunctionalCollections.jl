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

export PersistentList, PList,
       EmptyList,
       cons, ..,
       head,
       tail

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

end # module FunctionalUtilities
