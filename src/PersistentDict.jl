"""
    PersistentDict{K,V} <: AbstractDict{K,V}
PersistentDict is the abstract subtype for all implementations of persistent maps such as
PersistentHashDict, PersistentAutoDict, and PersistentArrayDict.

To construct a PersistentDict use the PersistentDict constructor.
"""
abstract type PersistentDict{K, V} <: AbstractDict{K, V} end

struct NotFound end

struct PersistentArrayDict{K, V} <: PersistentDict{K, V}
    kvs::Vector{Pair{K, V}}
end
PersistentArrayDict{K, V}() where {K, V} =
    PersistentArrayDict{K, V}(Pair{K, V}[])
PersistentArrayDict(kvs::(Union{Tuple{K, V}, Pair{K, V}})...) where {K, V} =
    PersistentArrayDict{K, V}(Pair{K, V}[Pair(k, v) for (k, v) in kvs])
PersistentArrayDict(; kwargs...) = PersistentArrayDict(kwargs...)

Base.isequal(m1::PersistentArrayDict, m2::PersistentArrayDict) =
    isequal(Set(m1.kvs), Set(m2.kvs))
==(m1::PersistentArrayDict, m2::PersistentArrayDict) =
    Set(m1.kvs) == Set(m2.kvs)

Base.length(m::PersistentArrayDict)  = length(m.kvs)
Base.isempty(m::PersistentArrayDict) = length(m) == 0

findkeyidx(m::PersistentArrayDict, k) = findfirst(kv -> kv[1] == k, m.kvs)

function _get(m::PersistentArrayDict, k, default, hasdefault::Bool)
    for kv in m.kvs
        kv[1] == k && return kv[2]
    end
    hasdefault ? default : default()
end

Base.get(m::PersistentArrayDict, k) =
    _get(m, k, ()->error("key not found: $k"), false)
Base.get(m::PersistentArrayDict, k, default) =
    _get(m, k, default, true)
Base.getindex(m::PersistentArrayDict, k) = get(m, k)

Base.haskey(m::PersistentArrayDict, k) = get(m, k, NotFound()) != NotFound()

function assoc(m::PersistentArrayDict{K, V}, k, v) where {K, V}
    idx = findkeyidx(m, k)
    idx === nothing && return PersistentArrayDict{K, V}(push!(m.kvs[1:end], Pair{K,V}(k, v)))

    kvs = m.kvs[1:end]
    kvs[idx] = Pair{K,V}(k, v)
    PersistentArrayDict{K, V}(kvs)
end

function dissoc(m::PersistentArrayDict{K, V}, k) where {K, V}
    idx = findkeyidx(m, k)
    idx === nothing && return m

    kvs = m.kvs[1:end]
    splice!(kvs, idx)
    PersistentArrayDict{K, V}(kvs)
end

function Base.iterate(m::PersistentArrayDict, i = 1)
    if i > length(m)
        return nothing
    else
        return (m.kvs[i], i + 1)
    end
end

Base.map(f::( Union{DataType, Function}), m::PersistentArrayDict) =
    PersistentArrayDict([f(kv) for kv in m]...)

Base.show(io::IO, ::MIME"text/plain", m::PersistentArrayDict{K, V}) where {K, V} =
    print(io, "Persistent{$K, $V}$(m.kvs)")


# Persistent Hash Maps
# ====================

struct PersistentHashDict{K, V} <: PersistentDict{K, V}
    trie::SparseBitmappedTrie{PersistentArrayDict{K, V}}
    length::Int
end
PersistentHashDict{K, V}() where {K, V} =
    PersistentHashDict{K, V}(SparseNode(PersistentArrayDict{K, V}), 0)

function PersistentHashDict(itr)
    if length(itr) == 0
        return PersistentHashDict()
    end
    K, V = typejoin(map(typeof, itr)...).types
    m = PersistentHashDict{K, V}()
    for (k, v) in itr
        m = assoc(m, k, v)
    end
    m
end

function PersistentHashDict(kvs::(Tuple{Any, Any})...)
    PersistentHashDict([kvs...])
end

function PersistentHashDict(kvs::(Pair)...)
    PersistentHashDict([kvs...])
end

function PersistentHashDict(; kwargs...)
    isempty(kwargs) ?
    PersistentHashDict{Any, Any}() :
    PersistentHashDict(kwargs...)
end

Base.length(m::PersistentHashDict) = m.length
Base.isempty(m::PersistentHashDict) = length(m) == 0

zipd(x,y) = map(p -> p[1] => p[2], zip(x,y))
Base.isequal(m1::PersistentHashDict, m2::PersistentHashDict) =
    length(m1) == length(m2) && all(x -> isequal(x...), zipd(m1, m2))

tup_eq(x) = x[1] == x[2]
==(m1::PersistentHashDict, m2::PersistentHashDict) =
    length(m1) == length(m2) && all(x -> x[1] == x[2], zipd(m1, m2))

function _update(f::Function, m::PersistentHashDict{K, V}, key) where {K, V}
    keyhash = reinterpret(Int, hash(key))
    arraymap = get(m.trie, keyhash, PersistentArrayDict{K, V}())
    newmap = f(arraymap)
    newtrie, _ = update(m.trie, keyhash, newmap)
    PersistentHashDict{K, V}(newtrie,
                            m.length + (length(newmap) < length(arraymap) ? -1 :
                                        length(newmap) > length(arraymap) ? 1 :
                                        0))
end

function assoc(m::PersistentHashDict{K, V}, key, value) where {K, V}
    _update(m, key) do arraymap
        assoc(arraymap, key, value)
    end
end

function dissoc(m::PersistentHashDict, key)
    _update(m, key) do arraymap
        dissoc(arraymap, key)
    end
end

function Base.getindex(m::PersistentHashDict, key)
    val = get(m.trie, reinterpret(Int, hash(key)), NotFound())
    (val === NotFound()) && error("key not found")
    val[key]
end

Base.get(m::PersistentHashDict, key) = m[key]
function Base.get(m::PersistentHashDict, key, default)
    val = get(m.trie, reinterpret(Int, hash(key)), NotFound())
    (val === NotFound()) && return default
    val[key]
end

function Base.haskey(m::PersistentHashDict, key)
    val = get(m.trie, reinterpret(Int, hash(key)), NotFound())
    (val != NotFound()) && haskey(val, key)
end

function Base.iterate(m::PersistentHashDict)
    trie_iter_result = iterate(m.trie)
    if trie_iter_result === nothing
        return nothing
    else
        arrmap, triestate = trie_iter_result
        kvs = arrmap.kvs
        return iterate(m, (kvs, triestate))
    end
end

function Base.iterate(m::PersistentHashDict, (kvs, triestate))
    if isempty(kvs) && isempty(triestate)
        return nothing
    else
        if isempty(kvs)
            arrmap, triestate = iterate(m.trie, triestate)
            return iterate(m, (arrmap.kvs, triestate))
        else
            return (kvs[1], (kvs[2:end], triestate))
        end
    end
end

function Base.map(f::( Union{Function, DataType}), m::PersistentHashDict)
    PersistentHashDict([f(kv) for kv in m]...)
end

function Base.filter(f::Function, m::PersistentHashDict{K, V}) where {K, V}
    arr = Array{Pair{K, V},1}()
    for el in m
        f(el) && push!(arr, el)
    end
    isempty(arr) ? PersistentHashDict{K, V}() : PersistentHashDict(arr...)
end

# Suppress ambiguity warning while allowing merging with array
function _merge(d::PersistentHashDict, others...)
    acc = d
    for other in others
        for (k, v) in other
            acc = assoc(acc, k, v)
        end
    end
    acc
end

# This definition suppresses ambiguity warning
Base.merge(d::PersistentHashDict, others::AbstractDict...) =
    _merge(d, others...)
Base.merge(d::PersistentHashDict, others...) =
    _merge(d, others...)

 function Base.show(io::IO, ::MIME"text/plain", m::PersistentHashDict{K, V}) where {K, V}
    print(io, "PHash{$K, $V}(")
    print(io, join(["$k => $v" for (k, v) in m], ", "))
    print(io, ")")
end


# Persistent Default Maps
# =======================
# The point of these "default" maps is this: it is generally fastest to use array maps for
# small/short maps and best to use hash-maps for large maps. Usually, we don't want to
# worry too much about tracking when things are large or small, though. Enter the default
# maps. Default maps are just a struct that wraps and imitates a PersistentArrayDict with
# one exception: when the size of an array map would grow to 64, a hash-map is instead
# returned, so maps get promoted automatically.


const _max_array_map_size = 64

struct PersistentAutoDict{K,V} <: PersistentDict{K,V}
    impl::PersistentArrayDict{K,V}
end

PersistentAutoDict{K, V}() where {K, V} =
    PersistentAutoDict{K, V}(PersistentArrayDict(Pair{K, V}[]))
PersistentAutoDict(arr::Array{Pair{K,V}}) where {K,V} =
    PersistentAutoDict{K,V}(PersistentArrayDict{K,V}(arr))
PersistentAutoDict(arr::Array{Tuple{K,V}}) where {K,V} =
    PersistentAutoDict{K,V}(PersistentArrayDict{K,V}([k=>v for (k,v) in arr]))
PersistentAutoDict(kvs::(Union{Tuple{K, V}, Pair{K, V}})...) where {K, V} =
    PersistentAutoDict{K,V}(PersistentArrayDict{K, V}(Pair{K, V}[Pair(k, v) for (k, v) in kvs]))
Base.isequal(m1::PersistentAutoDict, m2::PersistentAutoDict) = isequal(m1.impl, m2.impl)
==(m1::PersistentAutoDict, m2::PersistentAutoDict) = (m1.impl == m2.impl)

Base.length(m::PersistentAutoDict)  = length(m.impl)
Base.isempty(m::PersistentAutoDict) = isempty(m.impl)

findkeyidx(m::PersistentAutoDict, k) = findkeyidx(m.impl)

Base.get(m::PersistentAutoDict, k) = get(m.impl, k)
Base.get(m::PersistentAutoDict, k, default) = get(m.impl, k, default)
Base.getindex(m::PersistentAutoDict, k) = getindex(m.impl, k)

Base.haskey(m::PersistentAutoDict, k) = haskey(m.impl, k)

function FunctionalCollections.assoc(m::PersistentAutoDict{K, V}, k, v) where {K, V}
    if length(m.impl) + 1 >= _max_array_map_size && !haskey(m.impl, k)
        assoc(PersistentHashDict(collect(m)), k, v)
    else
        q = assoc(m.impl, k, v)
        (q === m.impl) ? m : PersistentAutoDict{K,V}(q)
    end
end

function FunctionalCollections.dissoc(m::PersistentAutoDict{K, V}, k) where {K, V}
    q = dissoc(m.impl, k)
    (q === m.impl) ? m : PersistentAutoDict{K,V}(q)
end

function Base.iterate(m::PersistentAutoDict, i = 1)
    iterate(m.impl, i)
end

Base.map(f::( Union{DataType, Function}), m::PersistentAutoDict) = PersistentAutoDict(map(f, m.impl))

Base.show(io::IO, q::MIME"text/plain", m::PersistentAutoDict{K, V}) where {K, V} =
    print(io, "PDict{$K, $V}(")
    print(io, join(["$k => $v" for (k, v) in m.impl], ", "))
    print(io, ")")

