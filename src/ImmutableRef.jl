# ImmutableRef base-class:
abstract type ImmutableRef{T} <: Ref{T} end
Base.setindex!(r::ImmutableRef, val, idcs...) = error("setindex! object of type $(typeof(r)) is immutable")

struct ImmutableRefValue{T} <: ImmutableRef{T}
    _val::T
end
Base.getindex(r::ImmutableRefValue) = r._val

ImmutableRef(x::T) where {T} = ImmutableRefValue{T}(x)

# DelayFunction is a type for specifying a delay object's computation;
# once the computation is peformed, the ref that holds the DelayFunction
# object will point to the result of the computation instead
struct _DelayFunction
    _f::Function
    _mux::Threads.SpinLock
    function _DelayFunction(f::Function)
        new(f, Threads.SpinLock())
    end
end

"""
    Delay{T}

Delays objects are ImmutableRef objects that store a function of zero arguments;
when the delay object is dereferenced (`delay[]`) then the function is called and
its return value is saved in the delay for all subsequent dereferences. Delays
are thread-safe as long as their functions are also thread-safe.

# Examples
```jtdoctest
# Define a function that will be calculated in the delay:
julia> function test_delay()
           println("Calculating...")
           10
       end
test_delay (generic function with 1 method)

julia> d = Delay(test_delay)
Delay{Any}(<unrealized>)

julia> d[]
Calculating...
10

julia> d[]
10

julia> d
Delay{Any}(10)

# We can also specify a type for the delay:
julia> d = Delay{Integer}(test_delay)
Delay{Integer}(<unrealized>)

julia> d[]
Calculating...
10

julia> d = Delay{String}(test_delay)
Delay{String}(<unrealized>)

julia> d[]
MethodError: Cannot `convert` an object of type Int64 to an object of type String
```
"""
mutable struct Delay{T} <: ImmutableRef{T}
    _val::Union{T,_DelayFunction}
    function Delay{T}(df::_DelayFunction) where {T}
        if T <: _DelayFunction
            error("Delay{$T} cannot reference _DelayFunction")
        end
        new(df)
    end
end
Delay{T}(f::Function) where {T} = Delay{T}(_DelayFunction(f))
Delay(f::Function) = Delay{Any}(_DelayFunction(f))
# we don't want people poking around in Delay objects:
Base.getproperty(delay::Delay, sym::Symbol) = error("type $(typeof(delay)) has no public field $sym")
Base.setproperty!(delay::Delay, sym::Symbol, val) = error("type $(typeof(delay)) has no public field $sym")
Base.propertynames(delay::Delay) = ()
# The accessor, which may run the delay:
function Base.getindex(d::Delay{T}) where {T}
    val = getfield(d, :_val)
    if isa(val, _DelayFunction)
        mux = val._mux
        try
            lock(mux)
            # make sure someone else didn't calculate before we locked:
            lockedval = getfield(d, :_val)
            if lockedval === val
                # it hasn't been memoized yet and we have the lock:
                val = val._f()
                tval::T = val
                if isa(tval, _DelayFunction)
                    error("getindex Delay function returned a value with type _DelayFunction")
                end
                setfield!(d, :_val, tval)
            else
                val = lockedval
            end
        finally
            unlock(mux)
        end
    end
    val
end
Base.fetch(d::Delay) = d[]
"""
    isrealized(delay::Delay)
Yields true if the given delay object has already been calculated and
memoized and false otherwise.
"""
isrealized(delay::Delay) = !isa(getfield(delay, :_val), _DelayFunction)
function Base.show(io::IO, ::MIME"text/plain", d::Delay{T}) where {T}
    val = getfield(d, :_val)
    if isa(val, _DelayFunction)
        print(io, "$(typeof(d))(<unrealized>)")
    else
        print(io, "$(typeof(d))($val)")
    end
end


# Promises

# Generic box type to denote an undelivered promise
struct _PromiseState{T}
    _val::Ref{T}
    _cond::Threads.Condition

    function _PromiseState{T}() where {T}
        new(Ref{T}(), Threads.Condition())
    end
end
"""
    Promise{T}
Promise objects are repositories for values that may or may not yet have 
been calculated. To wait on a promise or to retrieve the value once it
has been delivered, simply access its value: `promise[]`. To deliver a
value to a promise, use `deliver(promise, value)`. Promises are safe to
use across multiple threads as long as its fields are not changed.
"""
mutable struct Promise{T} <: ImmutableRef{T}
    _state::Union{T,_PromiseState}
    function Promise{T}() where {T}
        if T <: _PromiseState
            error("Promise object cannot be initialized with _PromiseState type")
        end
        new(_PromiseState{T}())
    end
end
# we don't want people poking around in Promise objects:
Base.getproperty(promise::Promise, sym::Symbol) = error("type $(typeof(promise)) has no public field $sym")
Base.setproperty!(promise::Promise, sym::Symbol, val) =
    error("type $(typeof(promise)) has no public field $sym")
Base.propertynames(promise::Promise) = ()
function Base.getindex(promise::Promise{T}) where {T}
    st = getfield(promise, :_state)
    if isa(st, _PromiseState)
        c = st._cond
        lock(c)
        try
            # make sure nobody else got there before we locked the mutex
            if st === getfield(promise, :_state)
                # okay, we just need to wait on the condition...
                wait(c)
                # when the condition is finished, promise._state will be the
                # delivered value, so we don't need to do anything else
            end
            st = getfield(promise, :_state)
        finally
            unlock(c)
        end
    end
    st
end
Base.fetch(p::Promise) = d[]
"""
    deliver(promise::Promise{T}, val::T)
Delivers the given value to the given promise then returns val. If the
promise has already been realized, then an error is thrown.
"""
function deliver(promise::Promise{T}, val::T) where {T}
    st = getfield(promise, :_state)
    if isa(st, _PromiseState)
        c = st._cond
        lock(c)
        try
            if st === getfield(promise, :_state)
                setfield!(promise, :_state, val)
                notify(c, val)
            else
                error("deliver cannot deliver value to a realized promise")
            end
        finally
            unlock(c)
        end
    else
        error("deliver cannot deliver value to a realized promise")
    end
    val
end
"""
    isrealized(promise::Promise{T})
Yields true if the given promise object has been realized and false otherwise.
"""
isrealized(promise::Promise{T}) where {T} = !isa(getfield(promise, :_state), _PromiseState)

function Base.show(io::IO, ::MIME"text/plain", p::Promise{T}) where {T}
    st = getfield(p, :_state)
    if isa(st, _PromiseState)
        print(io, "$(typeof(p))(<unrealized>)")
    else
        print(io, "$(typeof(p))($st)")
    end
end

