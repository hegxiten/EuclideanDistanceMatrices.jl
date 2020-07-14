module EuclideanDistanceMatrices

using LinearAlgebra, Statistics
import Pkg
using TotalLeastSquares
import Convex
using SCS
using StatsBase
using Turing, Distributions
using Turing2MonteCarloMeasurements


export complete_distmat, reconstruct_pointset, denoise_distmat, lowrankapprox, procrustes, posterior

"""
    D̃, S = complete_distmat(D, W, λ = 2)

Takes an incomplete squared Euclidean distance matrix `D` and fills in the missing entries indicated by the mask `W`. `W` is a `BitArray` or array of {0,1} with 0 denoting a missing value. Returns the completed matrix and an SVD object that allows reconstruction of the generating point set `X`.

*NOTE* This function is only available after `using Convex, SCS`.

# Arguments:
- `D`: The incomplete matrix
- `W`: The mask
- `λ`: Regularization parameter. A higher value enforces better data fitting, which might be required if the number of entries in `D` is very small.

# Example:
```julia
using EuclideanDistanceMatrices, Distances
P = randn(2,40)
D = pairwise(SqEuclidean(), P)
W = rand(size(D)...) .> 0.3 # Create a random mask
W = (W + W') .> 0           # It makes sense for the mask to be symmetric
W[diagind(W)] .= true
D0 = W .* D                 # Remove missing entries

D2, S = complete_distmat(D0, W)

@show (norm(D-D2)/norm(D))
@show (norm(W .* (D-D2))/norm(D))
```

The set of points that created `D` can be reconstructed up to an arbitrary rotation and translation, `X` contains the reconstruction in the `d` first rows, where `d` is the dimension of the point coordinates. To reconstruct `X` using `S`, do
```julia
X  = reconstruct_pointset(S, 2)

# Verify that reconstructed `X` is correct up to rotation and translation
A = [X' ones(size(D,1))]
P2 = (A*(A \\ P'))'
norm(P-P2)/norm(P) # Should be small
```

Ref: Algorithm 5 from "Euclidean Distance Matrices: Essential Theory, Algorithms and Applications"
Ivan Dokmanic, Reza Parhizkar, Juri Ranieri and Martin Vetterli https://arxiv.org/pdf/1502.07541.pdf
"""
function complete_distmat(D, W, λ=2)
    @assert all(==(1), diag(W)) "The diagonal is always observed and equal to 0. Make sure the diagonal of W is true"
    @assert all(iszero, diag(D)) "The diagonal of D is always 0"
    n = size(D, 1)
    x = -1/(n + sqrt(n))
    y = -1/sqrt(n)
    V = [fill(y, 1, n-1); fill(x, n-1,n-1) + I(n-1)]
    e = ones(n)
    G = Convex.Variable((n-1, n-1))
    B = V*G*V'
    E = diag(B)*e' + e*diag(B)' - 2*B
    problem = Convex.maximize(tr(G)- λ * norm(vec(W .* (E - D))), [G ∈ :SDP])
    Convex.solve!(problem, SCS.Optimizer)
    if Int(problem.status) != 1
        @error problem.status
    end
    B  = Convex.evaluate(B)
    D2 = diag(B)*e' + e*diag(B)' - 2*B
    @info "Data fidelity (norm(W .* (D-D̃))/norm(D))", (norm(W .* (D-D2))/norm(D))
    s  = svd(B)
    D2, s
end



function reconstruct_pointset(S::SVD,dim)
    X  = Diagonal(sqrt.(S.S[1:dim]))*S.Vt[1:dim, :]
end


"""
    reconstruct_pointset(D, dim)

Takes a squared distance matrix or the SVD of one and reconstructs the set of points embedded in dimension `dim` that generated `D; up to a translation and rotation/reflection. See `procrustes` for help with aligning the result to a collection of anchors.
"""
function reconstruct_pointset(D::AbstractMatrix, dim)
    n = size(D,1)
    J = I - fill(1/n, n, n)
    G = -1/2 * J*D*J
    E = eigen(G)
    Diagonal(sqrt.(E.values[1:dim]))*E.vectors'[1:dim, :]
end


"""
    denoise_distmat(D, dim, p = 2)

Takes a noisy squared distance matrix and returns a denoised version. `p` denotes the "norm" used in measuring the error. `p=2` assumes that the error is Gaussian, whereas `p=1` assumes that the error is large but sparse.

# Arguments:
- `dim`: The dimension of the points that generated `D`
"""
function denoise_distmat(D, dim, p=2)
    if p == 2
        s = svd(D)
        return lowrankapprox(s, dim+2)
    elseif p == 1
        A,E,s,sv = rpca(D, nonnegA=true)
        return lowrankapprox(s, dim+2)
    else
        throw(ArgumentError("p must be 1 or 2"))
    end
end

function lowrankapprox(s::SVD, r)
    @views s.U[:,1:r] * Diagonal(s.S[1:r]) * s.Vt[1:r,:]
end
lowrankapprox(D, r) = D = lowrankapprox(svd(D), r)


"""
    R,t = procrustes(X, Y)

Find rotation matrix `R` and translation vector `t` such that `R*X .+ t ≈ Y`
"""
function procrustes(X,Y)
    mX = mean(X, dims=2)
    mY = mean(Y, dims=2)
    Xb,Yb = X .- mX, Y .- mY
    s = svd(Xb*Yb')
    R = s.V*s.U'
    R, mY - R*mX
end




function posterior(
    locations::AbstractMatrix,
    distances;
    nsamples = 3000,
    sampler = NUTS(),
    σL = 0.3,
    σD = 0.3
)
    dim, N = size(locations)
    Nd = length(distances)
    Turing.@model model(locations, distances, ::Type{T} = Float64) where {T} = begin

        P0 ~ MvNormal(vec(locations), σL) # These denote the true locations
        P = reshape(P0, dim, N)
        # de = Vector{T}(undef, Nd) # These are the estimated errors in the distance measurements
        dh = Vector{T}(undef, Nd) # These are the predicted distance measurements
        # de ~ MvNormal(Nd, σD) # These are the estimated errors in the distance measurements
        d = sqrt.(getindex.(distances, 3))
        for ind in eachindex(distances)
            (i,j,di) = distances[ind]
            dh[ind] = norm(P[:,i] - P[:,j]) # This is the predicted SqEuclidean given the posterior location
            # de[ind] = (dh-di) # Predicted error
            # de ~ d[ind] # Assume normal noise in delay measurements
            # de[ind] ~ Normal(dh-sqrt(di), σD) # Assume normal noise in delay measurements
        end
        d ~ MvNormal(dh, σD) # These are the estimated errors in the distance measurements
    end

    m = model(locations, distances)

    if sampler isa Turing.Inference.InferenceAlgorithm
        @info "Starting sampling (this might take a while)"
        @time chain = sample(m, sampler, nsamples)
        nt = Particles(chain, crop=clamp(0, 500, nsamples-500))
        nt = (nt..., P=reshape(nt.P0, dim, N))
        @info "Done"
        return nt, chain
    elseif typeof(sampler) ∈ (Turing.MAP, Turing.MLE)
        res = optimize(m, sampler)
        c = StatsBase.coef(res)
        C = StatsBase.vcov(res)
        names = StatsBase.params(res)

        Pinds = findfirst.([==("P0[$i]") for i in eachindex(locations)], Ref(names))
        dinds = findfirst.([==("d[$i]") for i in eachindex(distances)], Ref(names))

        Pde = Particles(MvNormal(Vector(c), Symmetric(Matrix(C) + 0.1*min(σL,σD)^2*I)))
        P = reshape(Pde[Pinds], dim, N)
        de = Pde[dinds]
        (P=P, de=de), res
    end
    # chain
end




function __build__()
    Pkg.add(PackageSpec("https://github.com/baggepinnen/Turing2MonteCarloMeasurements.jl"))
end




end
