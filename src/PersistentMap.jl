abstract type PersistentMap{K, V} <: AbstractDict{K, V} end

struct NotFound end

struct PersistentArrayMap{K, V} <: PersistentMap{K, V}
    kvs::Vector{Pair{K, V}}
end
PersistentArrayMap{K, V}() where {K, V} =
    PersistentArrayMap{K, V}(Pair{K, V}[])
PersistentArrayMap(kvs::(Union{Tuple{K, V}, Pair{K, V}})...) where {K, V} =
    PersistentArrayMap{K, V}(Pair{K, V}[Pair(k, v) for (k, v) in kvs])
PersistentArrayMap(; kwargs...) = PersistentArrayMap(kwargs...)

Base.isequal(m1::PersistentArrayMap, m2::PersistentArrayMap) =
    isequal(Set(m1.kvs), Set(m2.kvs))
==(m1::PersistentArrayMap, m2::PersistentArrayMap) =
    Set(m1.kvs) == Set(m2.kvs)

Base.length(m::PersistentArrayMap)  = length(m.kvs)
Base.isempty(m::PersistentArrayMap) = length(m) == 0

findkeyidx(m::PersistentArrayMap, k) = findfirst(kv -> kv[1] == k, m.kvs)

function _get(m::PersistentArrayMap, k, default, hasdefault::Bool)
    for kv in m.kvs
        kv[1] == k && return kv[2]
    end
    hasdefault ? default : default()
end

Base.get(m::PersistentArrayMap, k) =
    _get(m, k, ()->error("key not found: $k"), false)
Base.get(m::PersistentArrayMap, k, default) =
    _get(m, k, default, true)
Base.getindex(m::PersistentArrayMap, k) = get(m, k)

Base.haskey(m::PersistentArrayMap, k) = get(m, k, NotFound()) != NotFound()

function assoc(m::PersistentArrayMap{K, V}, k, v) where {K, V}
    idx = findkeyidx(m, k)
    idx === nothing && return PersistentArrayMap{K, V}(push!(m.kvs[1:end], Pair{K,V}(k, v)))

    kvs = m.kvs[1:end]
    kvs[idx] = Pair{K,V}(k, v)
    PersistentArrayMap{K, V}(kvs)
end

function dissoc(m::PersistentArrayMap{K, V}, k) where {K, V}
    idx = findkeyidx(m, k)
    idx === nothing && return m

    kvs = m.kvs[1:end]
    splice!(kvs, idx)
    PersistentArrayMap{K, V}(kvs)
end

function Base.iterate(m::PersistentArrayMap, i = 1)
    if i > length(m)
        return nothing
    else
        return (m.kvs[i], i + 1)
    end
end

Base.map(f::( Union{DataType, Function}), m::PersistentArrayMap) =
    PersistentArrayMap([f(kv) for kv in m]...)

Base.show(io::IO, ::MIME"text/plain", m::PersistentArrayMap{K, V}) where {K, V} =
    print(io, "Persistent{$K, $V}$(m.kvs)")


# Persistent Hash Maps
# ====================

struct PersistentHashMap{K, V} <: PersistentMap{K, V}
    trie::SparseBitmappedTrie{PersistentArrayMap{K, V}}
    length::Int
end
PersistentHashMap{K, V}() where {K, V} =
    PersistentHashMap{K, V}(SparseNode(PersistentArrayMap{K, V}), 0)

function PersistentHashMap(itr)
    if length(itr) == 0
        return PersistentHashMap()
    end
    K, V = typejoin(map(typeof, itr)...).types
    m = PersistentHashMap{K, V}()
    for (k, v) in itr
        m = assoc(m, k, v)
    end
    m
end

function PersistentHashMap(kvs::(Tuple{Any, Any})...)
    PersistentHashMap([kvs...])
end

function PersistentHashMap(kvs::(Pair)...)
    PersistentHashMap([kvs...])
end

function PersistentHashMap(; kwargs...)
    isempty(kwargs) ?
    PersistentHashMap{Any, Any}() :
    PersistentHashMap(kwargs...)
end

Base.length(m::PersistentHashMap) = m.length
Base.isempty(m::PersistentHashMap) = length(m) == 0

zipd(x,y) = map(p -> p[1] => p[2], zip(x,y))
Base.isequal(m1::PersistentHashMap, m2::PersistentHashMap) =
    length(m1) == length(m2) && all(x -> isequal(x...), zipd(m1, m2))

tup_eq(x) = x[1] == x[2]
==(m1::PersistentHashMap, m2::PersistentHashMap) =
    length(m1) == length(m2) && all(x -> x[1] == x[2], zipd(m1, m2))

function _update(f::Function, m::PersistentHashMap{K, V}, key) where {K, V}
    keyhash = reinterpret(Int, hash(key))
    arraymap = get(m.trie, keyhash, PersistentArrayMap{K, V}())
    newmap = f(arraymap)
    newtrie, _ = update(m.trie, keyhash, newmap)
    PersistentHashMap{K, V}(newtrie,
                            m.length + (length(newmap) < length(arraymap) ? -1 :
                                        length(newmap) > length(arraymap) ? 1 :
                                        0))
end

function assoc(m::PersistentHashMap{K, V}, key, value) where {K, V}
    _update(m, key) do arraymap
        assoc(arraymap, key, value)
    end
end

function dissoc(m::PersistentHashMap, key)
    _update(m, key) do arraymap
        dissoc(arraymap, key)
    end
end

function Base.getindex(m::PersistentHashMap, key)
    val = get(m.trie, reinterpret(Int, hash(key)), NotFound())
    (val === NotFound()) && error("key not found")
    val[key]
end

Base.get(m::PersistentHashMap, key) = m[key]
function Base.get(m::PersistentHashMap, key, default)
    val = get(m.trie, reinterpret(Int, hash(key)), NotFound())
    (val === NotFound()) && return default
    val[key]
end

function Base.haskey(m::PersistentHashMap, key)
    val = get(m.trie, reinterpret(Int, hash(key)), NotFound())
    (val != NotFound()) && haskey(val, key)
end

function Base.iterate(m::PersistentHashMap)
    trie_iter_result = iterate(m.trie)
    if trie_iter_result === nothing
        return nothing
    else
        arrmap, triestate = trie_iter_result
        kvs = arrmap.kvs
        return iterate(m, (kvs, triestate))
    end
end

function Base.iterate(m::PersistentHashMap, (kvs, triestate))
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

function Base.map(f::( Union{Function, DataType}), m::PersistentHashMap)
    PersistentHashMap([f(kv) for kv in m]...)
end

function Base.filter(f::Function, m::PersistentHashMap{K, V}) where {K, V}
    arr = Array{Pair{K, V},1}()
    for el in m
        f(el) && push!(arr, el)
    end
    isempty(arr) ? PersistentHashMap{K, V}() : PersistentHashMap(arr...)
end

# Suppress ambiguity warning while allowing merging with array
function _merge(d::PersistentHashMap, others...)
    acc = d
    for other in others
        for (k, v) in other
            acc = assoc(acc, k, v)
        end
    end
    acc
end

# This definition suppresses ambiguity warning
Base.merge(d::PersistentHashMap, others::AbstractDict...) =
    _merge(d, others...)
Base.merge(d::PersistentHashMap, others...) =
    _merge(d, others...)

 function Base.show(io::IO, ::MIME"text/plain", m::PersistentHashMap{K, V}) where {K, V}
    print(io, "Persistent{$K, $V}[")
    print(io, join(["$k => $v" for (k, v) in m], ", "))
    print(io, "]")
end


# Persistent Default Maps
# =======================
# The point of these "default" maps is this: it is generally fastest to use array maps for
# small/short maps and best to use hash-maps for large maps. Usually, we don't want to
# worry too much about tracking when things are large or small, though. Enter the default
# maps. Default maps are just a struct that wraps and imitates a PersistentArrayMap with
# one exception: when the size of an array map would grow to 64, a hash-map is instead
# returned, so maps get promoted automatically.
# The pmap function, below, returns default maps when appropriate instead of array maps.


const _max_array_map_size = 64

struct PersistentDefaultMap{K,V} <: PersistentMap{K,V}
    impl::PersistentArrayMap{K,V}
end

PersistentDefaultMap{K, V}() where {K, V} =
    PersistentDefaultMap{K, V}(PersistentArrayMap(Pair{K, V}[]))
PersistentDefaultMap(arr::Array{Pair{K,V}}) where {K,V} =
    PersistentDefaultMap{K,V}(PersistentArrayMap{K,V}(arr))
PersistentDefaultMap(arr::Array{Tuple{K,V}}) where {K,V} =
    PersistentDefaultMap{K,V}(PersistentArrayMap{K,V}([k=>v for (k,v) in arr]))
PersistentDefaultMap(kvs::(Union{Tuple{K, V}, Pair{K, V}})...) where {K, V} =
    PersistentDefaultMap{K,V}(PersistentArrayMap{K, V}(Pair{K, V}[Pair(k, v) for (k, v) in kvs]))
Base.isequal(m1::PersistentDefaultMap, m2::PersistentDefaultMap) = isequal(m1.impl, m2.impl)
==(m1::PersistentDefaultMap, m2::PersistentDefaultMap) = (m1.impl == m2.impl)

Base.length(m::PersistentDefaultMap)  = length(m.impl)
Base.isempty(m::PersistentDefaultMap) = isempty(m.impl)

findkeyidx(m::PersistentDefaultMap, k) = findkeyidx(m.impl)

Base.get(m::PersistentDefaultMap, k) = get(m.impl, k)
Base.get(m::PersistentDefaultMap, k, default) = get(m.impl, k, default)
Base.getindex(m::PersistentDefaultMap, k) = getindex(m.impl, k)

Base.haskey(m::PersistentDefaultMap, k) = haskey(m.impl, k)

function FunctionalCollections.assoc(m::PersistentDefaultMap{K, V}, k, v) where {K, V}
    if length(m.impl) + 1 >= _max_array_map_size && !haskey(m.impl, k)
        assoc(PersistentHashMap(collect(m)), k, v)
    else
        q = assoc(m.impl, k, v)
        (q === m.impl) ? m : PersistentDefaultMap{K,V}(q)
    end
end

function FunctionalCollections.dissoc(m::PersistentDefaultMap{K, V}, k) where {K, V}
    q = dissoc(m.impl, k)
    (q === m.impl) ? m : PersistentDefaultMap{K,V}(q)
end

function Base.iterate(m::PersistentDefaultMap, i = 1)
    iterate(m.impl, i)
end

Base.map(f::( Union{DataType, Function}), m::PersistentDefaultMap) = PersistentDefaultMap(map(f, m.impl))

Base.show(io::IO, q::MIME"text/plain", m::PersistentDefaultMap{K, V}) where {K, V} =
    print(io, "PersistentDefault{$K, $V}$(m.impl.kvs)")

# The pmap function:
"""
    pmap(map::PersistentMap)::PersistentMap
Yields the given map.

# Examples
```jldoctest
using FunctionalCollections
m = FunctionalCollections.phmap([:a => 1, :b => 2, :c => 3])
pmap(m) === m  # The identical map is returned.

# output
true
```
"""
function pmap(map::PersistentMap{K,V})::PersistentMap{K,V} where {K,V}
    map
end
"""
    pmap(pairs::AbstractArray{Pair})::PersistentMap
Yields a persistent map of the key-value pairs in the given array; if the size of the
given arrary is greater than $_max_array_map_size, then a hash map is used; otherwise an array map is
used.

# Examples
```jldoctest
julia> pmap([:a => 1, :b => 2, :c => 3])
Persistent{Symbol, Int64}Pair{Symbol,Int64}[:a => 1, :b => 2, :c => 3]
```
"""
function pmap(u::AbstractArray{Pair{K,V},1})::PersistentMap{K,V} where {K,V}
    if length(u) < _max_array_map_size
        PersistentDefaultMap(u)
    else
        PersistentHashMap(u)
    end
end
"""
    pmap(dict::AbstractDict{K,V})::PersistentMap{K,V}
Yields a persistent map that is a duplicate of the given dictionary.

# Examples
```jldoctest
julia> pmap(Dict(:a => 1, :b => 2, :c => 3))
Persistent{Symbol, Int64}Pair{Symbol,Int64}[:a => 1, :b => 2, :c => 3]
```
"""
function pmap(dict::AbstractDict{K,V})::PersistentMap{K,V} where {K,V}
    pmap(collect(dict))
end
"""
    pmap(pairs::Pair{K,V}...)::PersistentMap{K,V}
Yields a persistent map that is composed of the given key-value pairs.

# Examples
```jldoctest
julia> pmap(:a => 1, :b => 2, :c => 3)
Persistent{Symbol, Int64}Pair{Symbol,Int64}[:a => 1, :b => 2, :c => 3]
```
"""
function pmap(pairs::Pair{K,V}...)::PersistentMap{K,V} where {K,V}
    pmap([pairs...])
end
"""
    pmap(tuples::Tuple{K,V}...)::PersistentMap{K,V}
Yields a persistent map that is composed of the given key-value tuples.

# Examples
```jldoctest
julia> pmap((:a, 1), (:b, 2), (:c, 3))
Persistent{Symbol, Int64}Pair{Symbol,Int64}[:a => 1, :b => 2, :c => 3]
```
"""
function pmap(tuples::Tuple{K,V}...)::PersistentMap{K,V} where {K,V}
    pmap([tuples...])
end
"""
    pmap()::PersistentMap{Any,Any}
    pmap(k1=v1, k2=v2...)::PersistentMap{Any,Any}
Yields an empty persistent map or an array map containing only the
given key-value pairs.

# Examples
```jtdoctest
julia> pmap()
Persistent{Any, Any}Pair{Any,Any}[]
julia> pmap(a=1, b=2)
Persistent{Symbol, Int64}Pair{Symbol,Int64}[:a => 1, :b => 2]
```
"""
function pmap(; kw...)::PersistentMap
    if length(kw) < _max_array_map_size
        PersistentDefaultMap([kw...])
    else
        PersistentHashMap([kw...])
    end
end
"""
    pmap(arr::Array)::PersistentMap
Yields a persistent map from the generic array, which must contain any
number of 2-tuples and pairs.

# Examples
```jtdoctest
julia> pmap([(:a, 1), (:b, 2), (:c, 3)])
Persistent{Symbol, Int64}Pair{Symbol,Int64}[:a => 1, :b => 2, :c => 3]
julia> pmap([:a => 1, :b => 2, :c => 3])
Persistent{Symbol, Int64}Pair{Symbol,Int64}[:a => 1, :b => 2, :c => 3]
julia> pmap([:a => 1, (:b, 2), :c => 3])
Persistent{Symbol, Int64}Pair{Symbol,Int64}[:a => 1, :b => 2, :c => 3]
```
"""
function pmap(arr::Array)::PersistentMap
    if length(arr) < _max_array_map_size
        PersistentDefaultMap(arr)
    else
        PersistentHashMap(arr)
    end
end
