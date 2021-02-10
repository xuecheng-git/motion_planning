using Plots
using Random
Random.seed!(1)

include_ddp()

# Model
include_model("double_integrator")

function f(model::DoubleIntegratorContinuous, x, u, w)
    [x[2]; (1.0 + w[1]) * u[1]]
end

model = DoubleIntegratorContinuous{Midpoint, FixedTime}(2, 1, 1)

struct MultipleModel{I, T} <: Model{I, T}
	n::Vector{Int}
	m::Vector{Int}
	d::Vector{Int}

	model::Model

	N::Int
	p::Int
end

function multiple_model(model, T, N; p = 0)
	n = model.n
	m = model.m
	d = model.d

	# n = [N * (n + (t == 1 ? 0 : p)) for t = 1:T]
	n = [N * (n + p) for t = 1:T]
	m = [N * m + (t == 1 ? p : 0) for t = 1:T-1]
	d = [N * d for t = 1:T-1]

	MultipleModel{typeof(model).parameters...}(n, m, d, model, N, p)
end

# Policy
p_policy = model.n * model.n + model.n + model.m * model.n + model.m

function policy(θ, x, n, m)
	K1 = reshape(view(θ, 1:n * n), n, n)
	k1 = view(θ, n * n .+ (1:n))
	K2 = reshape(view(θ, n * n + n .+ (1:m * n)), m, n)
	k2 = view(θ, n * n + n + m * n .+ (1:m))

	z1 = tanh.(K1 * x + k1)
	z2 = tanh.(K1 * z1 + k1)
	z3 = tanh.(K1 * z2 + k1)
	zo = K2 * z3 + k2

	return zo
end

function fd(models::MultipleModel, x, u, w, h, t)
	N = models.N

	n = models.n[t]
	m = models.m[t]
	d = models.d[t]

	ni = models.model.n
	mi = models.model.m
	di = models.model.d

	p = models.p

	nip = ni + p

	x⁺ = []

	for i = 1:N
		xi = view(x, (i - 1) * nip .+ (1:ni))
		ui = view(u, (i - 1) * mi .+ (1:mi))
		wi = view(w, (i - 1) * di .+ (1:di))

		if t == 1
			θ = view(u, N * mi .+ (1:p))
		else
			θ = view(x, (i - 1) * nip + ni .+ (1:p))
		end

		u_ctrl = ui + policy(θ, xi, ni, mi)

		push!(x⁺, [fd(models.model, xi, u_ctrl, wi, h, t); θ])
	end

	return vcat(x⁺...)
end

# Time
T = 101
h = 0.01

N = 2 * model.n + 1
models = multiple_model(model, T, N, p = p_policy)


z = range(0.0, stop = 3.0 * 2.0 * π, length = T)
p_ref = zeros(T)#1.0 * cos.(1.0 * z)
plot(z, p_ref)
xT = [vcat([[pr; 0.0; zeros(models.p)] for i = 1:N]...) for pr in p_ref]

# Initial conditions, controls, disturbances
# x1 = [p_ref[1]; 0.0; p_ref[1]; 0.0]
x1 = zeros(models.n[1])
for i = 1:N
	x1[(i - 1) * (model.n + models.p) + 1] = 1.0
end
x1

ū = [1.0e-1 * randn(models.m[t]) for t = 1:T-1]
wi = [0.0, 0.05, 0.1, 0.15, 0.2]#, 0.5, 1.0]
@assert length(wi) == N
w = [vcat(wi...) for t = 1:T-1]

# Rollout
x̄ = rollout(models, x1, ū, w, h, T)

# Objective
Q = [(t < T ?
	h * Diagonal(vcat([[1.0; 1.0; 1.0e-5 * ones(models.p)] for i = 1:N]...))
	: Diagonal(vcat([[1000.0; 1000.0; 1.0e-5 * ones(models.p)] for i = 1:N]...))) for t = 1:T]
q = [-2.0 * Q[t] * xT[t] for t = 1:T]

_R = 1.0e-1 * ones(models.m[2])
R = [h * Diagonal(t == 1 ? [_R; 1.0e-1 * ones(models.p)] : _R) for t = 1:T-1]
r = [zeros(models.m[t]) for t = 1:T-1]

obj = StageCosts([QuadraticCost(Q[t], q[t],
	t < T ? R[t] : nothing, t < T ? r[t] : nothing) for t = 1:T], T)

function g(obj::StageCosts, x, u, t)
	T = obj.T
    if t < T
		Q = obj.cost[t].Q
		q = obj.cost[t].q
	    R = obj.cost[t].R
		r = obj.cost[t].r
        return x' * Q * x + q' * x + u' * R * u + r' * u
    elseif t == T
		Q = obj.cost[T].Q
		q = obj.cost[T].q
        return x' * Q * x + q' * x
    else
        return 0.0
    end
end

# Constraints
# p_con = [t == T ? N * model.n : (t > 1 ? models.m[t] : (models.m[t] - models.p)) for t = 1:T]
p_con = [t == T ? 0 : (t > 1 ? models.m[t] : (models.m[t] - models.p)) for t = 1:T]
info_t = Dict()
x_idx = vcat([(i - 1) * (model.n + models.p) .+ (1:model.n) for i = 1:N]...)

# Visualize
info_T = Dict(:idx => x_idx)
con_set = [StageConstraint(p_con[t], t < T ? info_t : info_T) for t = 1:T]

function c!(c, cons::StageConstraints, x, u, t)
	T = cons.T

	if t == 1
		c .= view(u, 1:(models.m[t] - models.p))
	elseif t < T
		c .= u
	else
		nothing
	end
end

prob = problem_data(models, obj, con_set, copy(x̄), copy(ū), w, h, T,
	n = models.n, m = models.m, d = models.d)

# Solve
@time constrained_ddp_solve!(prob,
    max_iter = 1000, max_al_iter = 8,
	ρ_init = 1.0, ρ_scale = 10.0,
	con_tol = 1.0e-5)

x, u = current_trajectory(prob)
x̄, ū = nominal_trajectory(prob)

# individual trajectories
x_idx = [(i - 1) * (model.n + models.p) .+ (1:model.n) for i = 1:N]
u_idx = [(i - 1) * model.m .+ (1:model.m) for i = 1:N]

# Visualize
x_idxs = vcat(x_idx...)
u_idxs = vcat(u_idx...)

# state
plot(hcat([xT[t] for t = 1:T]...)[x_idxs, :]',
    width = 2.0, color = :black, label = "")
plot!(hcat(x...)[x_idxs, :]', color = :magenta, label = "")

# verify solution
uθ = u[1][models.N * model.m .+ (1:models.p)]
xθ_idx = [(i - 1) * (model.n + models.p) + model.n .+ (1:models.p) for i = 1:N]

policy_err = []
for i = 1:N
	for t = 2:T
		push!(policy_err, norm(x̄[t][xθ_idx[i]] - uθ, Inf))
	end
end
@show maximum(policy_err)

slack_err = []
for t = 1:T-1
	if t > 1
		push!(slack_err, norm(ū[t], Inf))
	else
		push!(slack_err, norm(ū[t][1:models.N * model.m], Inf))
	end
end
@show maximum(slack_err)

# Simulate policy
include(joinpath(@__DIR__, "simulate.jl"))

# Policy
θ = u[1][models.N * model.m .+ (1:models.p)]

# Model
model_sim = model
x1_sim = copy(x1[1:model.n])
T_sim = 10 * T

# Time
tf = h * (T - 1)
t = range(0, stop = tf, length = T)
t_sim = range(0, stop = tf, length = T_sim)
dt_sim = tf / (T_sim - 1)

# Simulate
x_sim = []
u_sim = []
J_sim = []
Random.seed!(1)
for k = 1:10
	w_sim = [randn(1)[1] for t = 1:T-1]

	x_nn, u_nn, J_nn, Jx_nn, Ju_nn = simulate_policy(
		model_sim,
		θ,
	    [x[1:model.n] for x in x̄], [u[1:model.m] for u in ū],
		[_Q[1:model.n, 1:model.n] for _Q in Q], [_R[1:model.m, 1:model.m] for _R in R],
		T_sim, h,
		copy(x1_sim),
		w_sim)

	push!(x_sim, x_nn)
	push!(u_sim, u_nn)
	push!(J_sim, J_nn)
end

# Visualize
idx = (1:2)
plt = plot(t, hcat(x̄...)[idx, :]',
	width = 2.0, color = :black, label = "",
	xlabel = "time (s)", ylabel = "state",
	title = "double integrator (J_avg = $(round(mean(J_sim), digits = 3)))")

for xs in x_sim
	plt = plot!(t_sim, hcat(xs...)[idx, :]',
	    width = 1.0, color = :magenta, label = "")
end
display(plt)
# plot(t, hcat(u..., u[end])',
# 	width = 2.0, color = :black, label = "",
# 	linetype = :steppost)

plt = plot(
	label = "",
	xlabel = "time (s)", ylabel = "state",
	title = "double integrator (J_avg = $(round(mean(J_sim), digits = 3)))")
for us in u_sim
	plt = plot!(t_sim, hcat(us..., us[end])',
		width = 1.0, color = :magenta, label = "",
		linetype = :steppost)
end
display(plt)
