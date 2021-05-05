using JuMP
using Clp
using DiffOpt
using Test
using ChainRulesCore

# This script creates the JuMP model for a small unit commitment instance
# represented in a solution map function taking parameters as arguments and returning
# the optimal solution as output.

# The derivatives of this solution map can then be expressed in ChainRules semantics
# and implemented using DiffOpt

ATOL=1e-4
RTOL=1e-4

"""
Solution map of the problem using parameters:
- `load1_demand, load2_demand` for the demand of two nodes
- `gen_costs` is the vector of generator costs
- `noload_costs` is the vector of fixed activation costs of the generators,
and returning the optimal output power `p`.
"""
function unit_commitment(load1_demand, load2_demand, gen_costs, noload_costs; model = Model(() -> diff_optimizer(Clp.Optimizer)))
    ## Problem data
    unit_codes = [1, 2] # Generator identifiers
    load_names = ["Load1", "Load2"] # Load identifiers
    n_periods = 4 # Number of time periods
    Pmin = Dict(1 => fill(0.5, n_periods), 2 => fill(0.5, n_periods)) # Minimum power output (pu)
    Pmax = Dict(1 => fill(3.0, n_periods), 2 => fill(3.0, n_periods)) # Maximum power output (pu)
    RR = Dict(1 => 0.25, 2 => 0.25) # Ramp rates (pu/min)
    P0 = Dict(1 => 0.0, 2 => 0.0) # Initial power output (pu)
    D = Dict("Load1" => load1_demand, "Load2" => load2_demand) # Demand
    Cp = Dict(1 => gen_costs[1], 2 => gen_costs[2]) # Generation cost coefficient ($/pu)
    Cnl = Dict(1 => noload_costs[1], 2 => noload_costs[2]) # No-load cost ($)

    ## Variables
    @variable(model, 0 <= u[g in unit_codes, t in 1:n_periods] <= 1) # Commitment
    @variable(model, p[g in unit_codes, t in 1:n_periods] >= 0) # Power output
    
    ## Constraints
    
    # Energy balance
    @constraint(
        model,
        energy_balance_cons[t in 1:n_periods],
        sum(p[g, t] for g in unit_codes) == sum(D[l][t] for l in load_names),
    )
    
    # Generation limits
    @constraint(model, [g in unit_codes, t in 1:n_periods], Pmin[g][t] * u[g, t] <= p[g, t])
    @constraint(model, [g in unit_codes, t in 1:n_periods], p[g, t] <= Pmax[g][t] * u[g, t])
    
    # Ramp rates
    @constraint(model, [g in unit_codes, t in 2:n_periods], p[g, t] - p[g, t - 1] <= 60 * RR[g])
    @constraint(model, [g in unit_codes], p[g, 1] - P0[g] <= 60 * RR[g])
    @constraint(model, [g in unit_codes, t in 2:n_periods], p[g, t - 1] - p[g, t] <= 60 * RR[g])
    @constraint(model, [g in unit_codes], P0[g] - p[g, 1] <= 60 * RR[g])
    
    # Objective
    @objective(
        model,
        Min,
        sum((Cp[g] * p[g, t]) + (Cnl[g] * u[g, t]) for g in unit_codes, t in 1:n_periods),
    )
    
    optimize!(model)
    @assert termination_status(model) == MOI.OPTIMAL
    # converting to dense matrix
    return JuMP.value.(p.data)
end

@show unit_commitment([1.0, 1.2, 1.4, 1.6], [1.0, 1.2, 1.4, 1.6], [1000.0, 1500.0], [500.0, 1000.0])

# Forward differentiation rule for the solution map of the unit commitment problem
# taking in input perturbations on the input parameters and returning perturbations propagated to the result
function ChainRulesCore.frule((_, Δload1_demand, Δload2_demand, Δgen_costs, Δnoload_costs), ::typeof(unit_commitment), load1_demand, load2_demand, gen_costs, noload_costs)
    model = Model(() -> diff_optimizer(Clp.Optimizer))
    pv = unit_commitment(load1_demand, load2_demand, gen_costs, noload_costs, model=model)
    energy_balance_cons = model[:energy_balance_cons]
    MOI.set.(model, DiffOpt.ForwardIn{DiffOpt.ConstraintConstant}(), energy_balance_cons, [d1 + d2 for (d1, d2) in zip(Δload1_demand, Δload1_demand)])

    p = model[:p]
    u = model[:u]

    for t in size(p, 2)
        MOI.set(model, DiffOpt.ForwardIn{DiffOpt.LinearObjective}(), p[1,t], Δgen_costs[1])
        MOI.set(model, DiffOpt.ForwardIn{DiffOpt.LinearObjective}(), p[2,t], Δgen_costs[2])
        MOI.set(model, DiffOpt.ForwardIn{DiffOpt.LinearObjective}(), u[1,t], Δnoload_costs[1])
        MOI.set(model, DiffOpt.ForwardIn{DiffOpt.LinearObjective}(), u[2,t], Δnoload_costs[2])
    end
    DiffOpt.forward(JuMP.backend(model))
    Δp = MOI.get.(model, DiffOpt.ForwardOut{MOI.VariablePrimal}(), p)
    return (pv, Δp.data)
end


load1_demand = [1.0, 1.2, 1.4, 1.6]
load2_demand = [1.0, 1.2, 1.4, 1.6]
gen_costs = [1000.0, 1500.0]
noload_costs = [500.0, 1000.0]

Δload1_demand = 0 * load1_demand .+ 0.1
Δload2_demand = 0 * load2_demand .+ 0.2
Δgen_costs = 0 * gen_costs .+ 0.1
Δnoload_costs = 0 * noload_costs .+ 0.4
@show (pv, Δpv) = ChainRulesCore.frule((nothing, Δload1_demand, Δload2_demand, Δgen_costs, Δnoload_costs), unit_commitment, load1_demand, load2_demand, gen_costs, noload_costs)

# Reverse-mode differentiation of the solution map
# The computed pullback takes a seed for the optimal solution `̄p` and returns
# derivatives wrt each input parameter.
function ChainRulesCore.rrule(::typeof(unit_commitment), load1_demand, load2_demand, gen_costs, noload_costs; model = Model(() -> diff_optimizer(Clp.Optimizer)))
    pv = unit_commitment(load1_demand, load2_demand, gen_costs, noload_costs, model=model)
    function pullback_unit_commitment(pb)
        p = model[:p]
        u = model[:u]
        energy_balance_cons = model[:energy_balance_cons]

        MOI.set.(model, DiffOpt.BackwardIn{MOI.VariablePrimal}(), p, pb)
        DiffOpt.backward(JuMP.backend(model))

        dgen_costs = similar(gen_costs)
        dgen_costs[1] = sum(MOI.get.(model, DiffOpt.BackwardOut{DiffOpt.LinearObjective}(), p[1,:]))
        dgen_costs[2] = sum(MOI.get.(model, DiffOpt.BackwardOut{DiffOpt.LinearObjective}(), p[2,:]))

        dnoload_costs = similar(noload_costs)
        dnoload_costs[1] = sum(MOI.get.(model, DiffOpt.BackwardOut{DiffOpt.LinearObjective}(), u[1,:]))
        dnoload_costs[2] = sum(MOI.get.(model, DiffOpt.BackwardOut{DiffOpt.LinearObjective}(), u[2,:]))
        
        dload1_demand = MOI.get.(model, DiffOpt.BackwardOut{DiffOpt.ConstraintConstant}(), energy_balance_cons)
        dload2_demand = copy(dload1_demand)
        return (dload1_demand, dload2_demand, dgen_costs, dnoload_costs)
    end
    return (pv, pullback_unit_commitment)
end

(pv, pullback_unit_commitment) = ChainRulesCore.rrule(unit_commitment, load1_demand, load2_demand, gen_costs, noload_costs; model = Model(() -> diff_optimizer(Clp.Optimizer)))
@show pullback_unit_commitment(ones(size(pv)))
