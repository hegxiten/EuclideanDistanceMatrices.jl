using EuclideanDistanceMatrices, Turing, Distances, LinearAlgebra
N = 10    # Number of points
σL = 0.1  # Location noise std
σD = 0.01 # Distance noise std (measured in the same unit as positions)

P  = randn(2,N)                       # These are the true locations
Pn = P + σL*randn(size(P))            # Noisy locations
D  = pairwise(Euclidean(), P, dims=2) # True distance matrix (this function exoects distances, not squared distances).
Dn = D + σD*randn(size(D))            # Noisy distance matrix
Dn[diagind(Dn)] .= 0 # The diagonal is always 0

# We select a small number of distances to feed the algorithm, this corresponds to only some distances between points being measured
distances = []
p = 0.5 # probability of including a distance
for i = 1:N
    for j = i+1:N
        rand() < p || continue
        push!(distances, (i,j,Dn[i,j]))
    end
end
@show length(distances)
@show expected_number_of_entries = p*((N^2-N)÷2)