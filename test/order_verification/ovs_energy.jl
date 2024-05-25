module OVS_Energy

include("ovs_funcs.jl")

using Symbolics, HallThruster, LinearAlgebra

@variables x t

Dt = Differential(t)
Dx = Differential(x)

L = 0.05

ϕ = sin_wave(x/L, amplitude = 300, phase = π/2, nwaves = 0.25)
ne = sin_wave(x/L, amplitude = 2e15, phase = π/4, nwaves = 0.5, offset = 1.1e16)
nn = sin_wave(x/L, amplitude = 5e18, phase = pi/3, nwaves = 2.0, offset = 6e18)
ui = sin_wave(x/L, amplitude = 13000, phase = π/4, nwaves = 0.75, offset = 10000)
μ = sin_wave(x/L, amplitude = 1e4, phase = π/2, nwaves = 1.2, offset = 1.1e4)
ϵ = sin_wave(x/L, amplitude = 20, phase = 1.3*π/2, nwaves = 1.1, offset = 30)
∇ϕ = Dx(ϕ)
niui = ne * ui
nϵ = ne * ϵ
ue = μ * (∇ϕ - Dx(nϵ)/ne)
κ = 10/9 * μ * nϵ

ϕ_func = eval(build_function(ϕ, [x]))
ne_func = eval(build_function(ne, [x]))
μ_func = eval(build_function(μ, [x]))
niui_func = eval(build_function(niui, [x]))
nϵ_func = eval(build_function(nϵ, [x]))
κ_func = eval(build_function(κ, [x]))
ue_func = eval(build_function(expand_derivatives(ue), [x]))
∇ϕ_func = eval(build_function(expand_derivatives(∇ϕ), [x]))
nn_func = eval(build_function(nn, [x]))
ϵ_func = eval(build_function(ϵ, [x]))

k(ϵ) = 8.32 * OVS_rate_coeff_ex(ϵ)
W(ϵ) = 1e7 * ϵ * exp(-20 / ϵ)
energy_eq = Dt(nϵ) + Dx(5/3 * nϵ * ue - 10/9 * μ * nϵ * Dx(nϵ/ne)) + ne * (-ue * Dx(ϕ) + nn * k(ϵ) + W(ϵ))
source_energy = eval(build_function(expand_derivatives(energy_eq), [x]))

function solve_energy!(params, max_steps, dt, rtol = sqrt(eps(Float64)))
    t = 0.0
    nϵ_old = copy(params.cache.nϵ)
    residual = Inf
    iter = 0
    res0 = 0.0
    while iter < max_steps && abs(residual / res0) > rtol
        HallThruster.update_electron_energy!(params, dt)
        params.cache.νiz .= 0.0
        params.cache.νex .= 0.0
        params.cache.inelastic_losses .= 0.0
        params.config.conductivity_model(params.cache.κ, params) # update thermal conductivity
        residual = Lp_norm(params.cache.nϵ .- nϵ_old, 2)
        if iter == 1
            res0 = residual
        end
        nϵ_old .= params.cache.nϵ
        t += dt
        iter += 1
    end

    return params
end

function verify_energy(ncells; niters = 20000)
    grid = HallThruster.generate_grid(HallThruster.SPT_100.geometry, (0.0, 0.05), UnevenGrid(ncells))

    z_cell = grid.cell_centers
    z_edge = grid.edges
    ncells = length(z_cell)

    μ = μ_func.(z_cell)
    κ = κ_func.(z_cell)
    ne = ne_func.(z_cell)
    ϕ = zeros(ncells)
    ue = ue_func.(z_cell)
    ∇ϕ = ∇ϕ_func.(z_cell)
    nn = nn_func.(z_cell)
    niui = niui_func.(z_cell)
    Tev = ϵ_func.(z_cell) * 2/3
    νex = zeros(ncells)
    νiz = zeros(ncells)
    channel_area = ones(ncells)
    dA_dz = zeros(ncells)

    nϵ_exact = nϵ_func.(z_cell)
    pe = copy(nϵ_exact)

    Te_L = nϵ_exact[1] / ne[1]
    Te_R = nϵ_exact[end] / ne[end]

    nϵ = Te_L * ne # Set initial temp to 3 eV

    Aϵ = Tridiagonal(ones(ncells-1), ones(ncells), ones(ncells-1))
    bϵ = zeros(ncells)

    min_electron_temperature = 0.1 * min(Te_L, Te_R)

    source_func = (params, i) -> source_energy(params.z_cell[i])

    # Test backward difference implicit solve
    dt = 1e-6

    transition_function = HallThruster.StepFunction()

    excitation_model = OVS_Excitation()
    ionization_model = OVS_Ionization()

    wall_loss_model = HallThruster.ConstantSheathPotential(20.0, 1.0, 1.0)
    L_ch = 0.025
    propellant = HallThruster.Xenon
    LANDMARK = true

    geometry = (;channel_length = L_ch)

    config = (;
        ncharge = 1, source_energy = source_func, implicit_energy = 1.0,
        min_electron_temperature, transition_function, LANDMARK, propellant,
        ionization_model, excitation_model, wall_loss_model, geometry,
        anode_boundary_condition = :dirichlet,
        conductivity_model = HallThruster.LANDMARK_conductivity(),
    )

    species = [HallThruster.Xenon(0), HallThruster.Xenon(1)]
    species_range_dict = Dict([:Xe => 1, Symbol("Xe+") => 0])

    ionization_reactions = HallThruster._load_reactions(config.ionization_model, species)
    ionization_reactant_indices = HallThruster.reactant_indices(ionization_reactions, species_range_dict)
    ionization_product_indices = HallThruster.product_indices(ionization_reactions, species_range_dict)

    excitation_reactions = HallThruster._load_reactions(config.excitation_model, species)
    excitation_reactant_indices = HallThruster.reactant_indices(excitation_reactions, species_range_dict)

    wall_losses = zeros(ncells)
    inelastic_losses = zeros(ncells)
    ohmic_heating = zeros(ncells)
    cache = (;
        Aϵ, bϵ, μ, ϕ, ne, ue, ∇ϕ, Tev, pe, νex, νiz,
        wall_losses, ohmic_heating, inelastic_losses,
        channel_area, dA_dz, κ, nϵ, nn, ni = ne, niui
    )

    Δz_cell, Δz_edge = HallThruster.grid_spacing(grid)

    params = (;
        z_cell, z_edge, Te_L = 2/3 * Te_L, Te_R = 2/3 * Te_R, cache, config,
        dt, L_ch, propellant,
        ionization_reactions,
        ionization_reactant_indices,
        ionization_product_indices,
        excitation_reactions,
        excitation_reactant_indices,
        Δz_cell, Δz_edge,
        ncells
    )

    solve_energy!(params, niters, dt)
    results_implicit = (;z = z_cell, exact = nϵ_exact, sim = params.cache.nϵ[:])

    # Test crank-nicholson implicit solve
    params.cache.nϵ .= ne * Te_L

    config = (;
        ncharge = 1, source_energy = source_func, implicit_energy = 0.5,
        min_electron_temperature, transition_function, LANDMARK, propellant,
        ionization_model, excitation_model, wall_loss_model, geometry,
        anode_boundary_condition = :dirichlet,
        conductivity_model = HallThruster.LANDMARK_conductivity(),
    )

    dt = 8 / maximum(abs.(ue)) * (z_cell[2] - z_cell[1])
    params = (;
        z_cell, z_edge, Te_L = 2/3 * Te_L, Te_R = 2/3 * Te_R, cache, config,
        dt, L_ch, propellant,
        ionization_reactions,
        ionization_reactant_indices,
        ionization_product_indices,
        excitation_reactions,
        excitation_reactant_indices,
        Δz_cell, Δz_edge, ncells
    )

    solve_energy!(params, niters, dt)
    results_crank_nicholson = (;z = z_cell, exact = nϵ_exact, sim = params.cache.nϵ[:])

    return (results_implicit, results_crank_nicholson)
end

end
