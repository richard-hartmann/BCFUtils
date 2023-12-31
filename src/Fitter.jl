export FitCfg, FitCfg_for_Ohmic_bath, fit, get_fit, u_limits

using SciMLBase
using Optimization
using OptimizationOptimJL
using Sobol
using Distances: minkowski
using NLsolve
using Logging
using Printf
using Serialization

"""
    FitCfg{T}(
        b::AbstractBath{T}
        tau_range::AbstractTauIter{T}
        num_exp_terms::Int64
        p::T
        u_init_min::NTuple{4, T}
        u_init_max::NTuple{4, T}
        diff_kind::Symbol
        maxiters::Int64
    ) where T<:AbstractFloat

Configure and, thus, uniquely specify the fitting.
This allows to keep track (save) of the initial conditions that have been 
tried, and procede in a later call.

We save ALL real numbers using the same float type to ensure that, e.g., t_max = 2 and t_max = 2.0
which yields the same fitting procedure have the same configuration.
There might be a solution which is more in the spirit of general codeing, but for now it should suffice.


# Arguments
- `b::AbstractBath{T}`: BCF of the bath `b` as reference to fit against  
- `tau_range::AbstractTauRange{T}`: a range for times t_i ∈ [0, t_max] used to calculate the difference
- `num_exp_terms::Int64`: number of exponential terms used for the approximate representation
- `p::T`: exponent of the p-norm difference
- `u_init_min::NTuple{4, T}`: lower limits for the initial conditions
- `u_init_max::NTuple{4, T}`: upper limits for the initial conditions
- `diff_kind::Symbol`: kind of difference to be minimized, so far `:abs_p_diff` and `:rel_p_diff` have been implemented
- `maxiters::Int64`: maximum number of iteration for the minimizer
"""
struct FitCfg{T<:AbstractFloat}
    b::AbstractBath{T}
    tau_range::AbstractTauIter{T}
    num_exp_terms::Int64
    p::T
    u_init_min::NTuple{4, T}
    u_init_max::NTuple{4, T}
    diff_kind::Symbol
    maxiters::Int64

    function FitCfg(
            b::AbstractBath{T},
            tau_range::AbstractTauIter{T},
            num_exp_terms::Int64, 
            p::Real, 
            u_init_min::NTuple{4, Real}, 
            u_init_max::NTuple{4, Real}, 
            diff_kind::Symbol, 
            maxiters::Int64, 
        ) where T <: AbstractFloat
        0 < num_exp_terms || throw("0 < num_exp_terms required")
        0 < p || throw("0 < p required")
        1 < maxiters || throw("1 < maxiters required")

        p = convert(T, p)
        u_init_min = convert(NTuple{4, T}, u_init_min)
        u_init_max = convert(NTuple{4, T}, u_init_max)
        
        new{T}(b, tau_range, num_exp_terms, p, u_init_min, u_init_max, diff_kind, maxiters)
    end
end


"convenient function for (reduced) Ohmic BCFs, i.e., wc=1 and c1=1, which gets FitCfg with some default values"
function FitCfg_for_Ohmic_bath(
    t_max, 
    s, 
    num_exp_terms, 
    diff_kind::Symbol;
    p=5,
    u_init_min=( 0,   0,  0, -pi/2), 
    u_init_max=(10, 2pi, 10, +pi/2), 
    maxiters=1000, 
    num_tau=150, 
    a_tilde=0.1, 
    u_tilde=0.5
)

    T = promote_type_of_many(t_max, s, p, u_init_min..., u_init_max..., a_tilde, u_tilde)
    u_init_min = NTuple{4, T}(u_init_min)
    u_init_max = NTuple{4, T}(u_init_max)

    b = OhmicExpCO{T}(s, c1=1)
    t_max, s, a_tilde, u_tilde = convert_many(T, t_max, s, a_tilde, u_tilde)
    tau_range = get_TauExpIter_for_Ohmic(t_max, s, num_tau, a_tilde, u_tilde)
    
    FitCfg(b, tau_range, num_exp_terms, p, u_init_min, u_init_max, diff_kind, maxiters)
end



struct FitSol{T<:AbstractFloat}
    idx::Int64
    u::Vector{T}
    objective::T
    returncode::SciMLBase.ReturnCode.T
end

mutable struct FitState{T<:AbstractFloat}
    solutions::Vector{FitSol{T}}
    sobol_idx::Int64
    best_objective::T
end


function FitState{T}() where {T<:AbstractFloat}
    FitState(Vector{FitSol{T}}(undef, 0), 0, convert(T, Inf))
end

function FitState(::FitCfg{T}) where {T<:AbstractFloat}
    FitState(Vector{FitSol{T}}(undef, 0), 0, convert(T, Inf))
end

# supposed to be optimized (use this since it is included in NLsolve anyway)
"absolute p-norm difference"
diff(::Type{Val{:abs_p_diff}}, f_t::AbstractVector, params::Tuple{AbstractVector, Real}) = minkowski(f_t, params...)

"relative p-norm difference"
function diff(::Type{Val{:rel_p_diff}}, f_t::AbstractVector, params::Tuple{AbstractVector, AbstractVector, Real})
    f_ref, abs2_f_ref, p = params
    sum([(abs2(f_t[i] - f_ref[i]) / abs2_f_ref[i])^(p/2) for i in 1:length(f_ref)])^(1/p)
end

# dispatch diff_kind::Symbol to specific function
diff(diff_kind::Symbol, f_t::AbstractVector, params::Tuple) = diff(Val{diff_kind}, f_t, params)


"""
calculate the relative p-norm difference for a given BCF (contained in params_for_diff) and 
a multi exponential representation parameterized by u
"""
function diff_from_exp(u, param)
    tau_range, params_for_diff, diff_kind = param
    f_t = [_bcf_sum_exp(ti, u) for ti in tau_range]
    return diff(diff_kind, f_t, params_for_diff)
end



function fit_bcf_to_exp(tau_test, bcf_tau, p, u0, method, maxiters, diff_kind::Symbol)
    if diff_kind == :abs_p_diff
        params_for_diff = bcf_tau, p
    elseif diff_kind == :rel_p_diff
        params_for_diff = bcf_tau, abs2.(bcf_tau), p
    else
        throw(ArgumentError("unknown diff_kind $diff_kind"))
    end
    f_opt = OptimizationFunction(diff_from_exp, AutoForwardDiff())
    param = (tau_test, params_for_diff, diff_kind)
    prob = OptimizationProblem(f_opt, u0, param)
    sol = solve(prob, method, maxiters=maxiters)
    return sol
end

function get_TauExpRange(fc::FitCfg)
    BCF.get_TauExpRange(fc.t_max, fc.s, fc.num_tau, fc.a_tilde, fc.u_tilde)
end

"""
# fit exp bcf to Ohmic-kind bcf for many Sobol generated initial conditions

Based on the state given by `fs::FitState` continue to process new Sobol samples 
until `num_samples` have been processed.
Only results with lower objective value are added to `fs::FitState`.

An InterruptException will stop the routine early and return gracefully with the current state.

# Arguments
- `fc::FitCfg{T}`: fit configuration (see `struct FitCfg` for details)
- `fs::FitState{T}`: this mutable struct keeps track of the processed samples 
    and stores sequentially improving results
- `num_samples` the maximum number of samples to process
"""
function sobol_scan_fit!(fc::FitCfg{T}, fs::FitState{T}, num_samples; verbose=false) where {T<:AbstractFloat}
    # we need the parametric type {T} here, as its needed to instanciate the new solution object

    tau_test = collect(fc.tau_range)
    bcf_tau_test = [bcf(ti, fc.b) for ti in tau_test]
    
    method_NM = NelderMead()
    method_BFGS = BFGS()
       
    # init  low-discrepancy sobol sequence
    sobol_seq = Sobol.SobolSeq(4*fc.num_exp_terms)
    # skip already checked samples
    Base.skip(sobol_seq, fs.sobol_idx, exact=true)

    i = fs.sobol_idx+1

    cnt_new = 0
    was_interrupted = false

    try
        while i <= num_samples
            verbose && print("sample $i, ")
        
            # draw initial condition using sobol samples
            u0 = next!(sobol_seq)
            for i in 1:4
                u0[i:4:end] = fc.u_init_min[i] .+ (fc.u_init_max[i]-fc.u_init_min[i])*u0[i:4:end]
            end 
        
            # run NelderMead followed by BFGS Optimization
            sol_pre = fit_bcf_to_exp(tau_test, bcf_tau_test, fc.p, u0, method_NM, Integer(ceil(fc.maxiters/3)), fc.diff_kind)
            verbose && @printf("NelderMead pre solution: fmin %.4e %s, ",sol_pre.objective, sol_pre.retcode)
            sol = fit_bcf_to_exp(tau_test, bcf_tau_test, fc.p, sol_pre.u, method_BFGS, fc.maxiters, fc.diff_kind)
            verbose && @printf("BFGS solution: fmin %.4e %s\n", sol.objective, sol.retcode)

            if sol.objective < fs.best_objective
                cnt_new += 1
                # store new solution which improves previous one
                new_sol = FitSol{T}(i, sol.u, sol.objective, sol.retcode)
                push!(fs.solutions, new_sol)
                fs.best_objective = sol.objective

                printstyled(@sprintf("new improoved result: idx %i fmin %e %s\n", i, sol.objective, sol.retcode), color=:green)
            end
            i += 1
        end
    catch e
        println()
        @info "caught exception $e"
        isa(e, InterruptException) || throw(e)
        was_interrupted = true
    end
    fs.sobol_idx = i-1

    return cnt_new, was_interrupted
end


"""
hash the string repr of `fc::FitCfg` and return its hex string

### ToDO 

come up with something more robust that `repr(fc)`
"""
function fc_identifyer(fc::FitCfg)
    r = repr(fc)
    string(hash(r), base=16)
end

"save fit state, contruct unique file name based on `fc::FitCfg`"
function save(fc::FitCfg, fs::FitState, path=".fit")
    save(fc_identifyer(fc), fc, fs, path)
end

"save fit state"
function save(fname, fc::FitCfg, fs::FitState, path=".fit")
    ispath(path) || mkdir(path)
    serialize(joinpath(path, fname), (fc, fs))
    @info "fit state saved"
end


"load fit data from an existing file"
function load(full_name)
    deserialize(full_name)
end

"load fit for a given data FitCfg, return (sobol_state, data)"
function load(fc::FitCfg, path=".fit")
    fname = fc_identifyer(fc)
    full_name = joinpath(path, fname)

    if ispath(full_name)
        # load from file
        fc_ff, fs = load(full_name)
        # sanity check
        @assert fc_ff == fc
    else
        # create new state based on config
        fs = FitState(fc)
    end

    return fs, fc
end


"load state, run fits, save state and return numbes of processed sobol samples"
function fit(fc::FitCfg, num_samples, path=".fit"; verbose=false)
    fs, _ = load(fc, path)
    i_0 = fs.sobol_idx
    _, was_interrupted = sobol_scan_fit!(fc, fs, num_samples, verbose=verbose)
    save(fc, fs, path)
    was_interrupted && throw(InterruptException())
    return fs.sobol_idx - i_0
end


function get_fit(full_name::AbstractString, idx::Integer)
    _, fs = load(full_name)
    idx <= 0 && return fs.solutions[end]
    return fs.solutions[idx]
end


function get_fit(fc::FitCfg, idx=0, path=".fit")
    full_name = joinpath(path, fc_identifyer(fc))
    get_fit(full_name, idx)
end


function u_limits(u)
    u1 = u[1:4:end]
    u2 = u[2:4:end]
    u3 = u[3:4:end]
    u4 = u[4:4:end]

    u_mins = (minimum(u1), minimum(u2), minimum(u3), minimum(u4))
    u_maxs = (maximum(u1), maximum(u2), maximum(u3), maximum(u4))
    return u_mins, u_maxs
end
