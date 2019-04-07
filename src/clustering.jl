"""
    dpclustering(y::Array{Real, 1}, N::Array{Real, 1}; <keyword arguments>)
Perform dirichlet clustering on the variant allele frequency distribution of cancer sequencing data and find the number of clusters that the data supports, y is a vector of the number of reads reporting each mutant, N is the total depth at each locus.

...
## Arguments
- `iterations = 1000`: number of iterations of the gibbs samples
- `C = 30`: Max number of clusters to consider
- `burninstart = round(Int64, iterations/2)`: Burn in of the gibbs samples
- `bw = 0.01`: Bandwidth of density estimation
- `maxxaxis = 0.7`:
- `cutoffweight = 0.05`: Minimum weight to be called a cluster
- `verbose = true`: Show progress of gibbs sampling with `ProgressMeter` package
- `A = 0.01`: Hyperparameter for α, see Nik-Zainal et al
- `B = 0.01`: Hyperparameter for α, see Nik-Zainal et al
...
"""
function dpclustering(y, N;
    iterations = 20000,
    C = 30, #max number of clusters
    burninstart = round(Int64, 5000),
    bw = 0.01, # bandwidth of density estimation
    maxxaxis = 0.7,
    cutoffweight = 0.05, #minimum weight to be called a cluster
    verbose = true,
    A = 0.01, # Hyperparameters for alpha
    B = 0.01 # Hyperparameters for alpha
    )

    sum(y .== 0) == 0 || error("Some mutations have VAF = 0.0, make sure these mutations are removed before clustering")

    nummuts = length(y)

    # Set up arrays and matrices for recording samples
    y = map(Float64, y) # make sure read counts and depth are floats
    N = map(Float64, N)
    VAF = y ./ N
    π = zeros(Float64, iterations, C)
    PrS = zeros(Float64, nummuts, C)
    α = zeros(Float64, iterations)
    mutburdens = zeros(Float64, iterations, C, nummuts)
    V = ones(Float64, iterations, C)
    clusterassignment = zeros(Int64, iterations, nummuts)

    #random initial clusters between 0 and 1
    π[1, :] = rand(Uniform(0.0, maximum(VAF)), C)
    for c in 1:C
        mutburdens[1, c, :] .= π[1, c]
    end

    α[1] = 1.0
    V[1, 1:(C - 1)] .= 0.5

    if verbose == true
      p = Progress(iterations, 1, "Gibbs sampling progress: ", 30)
    end

    for m in 2:iterations
        for k in 1:nummuts
            #Binomial log-likelihood
            PrS[k, 1] = log.(V[m .- 1, 1]) .+ (y[k] .* log.(mutburdens[m-1, 1, k])) .+
            (N[k] .- y[k]) .* log.(1 .- mutburdens[m - 1, 1, k])
            allocate!(PrS, V, mutburdens, y, N, k, C, m)
            takemax!(PrS, k, C)
            exp!(PrS, k, C)
            normalize!(PrS, k, C)
        end

        multinomsample!(clusterassignment, PrS, nummuts, m, C)

        # Update stick-breaking weights
        updatestick!(V, clusterassignment, α, C, m)

        V[m, [V[m, 1:(C-1)] .== 1.0; false]] .= 0.9999

        countsPerCopyNum = N

        mutburdens[m, :, :] = mutburdens[m - 1, :, :]
        @fastmath @inbounds for c in unique(clusterassignment[m, :])
          idx = findall((in)(c), clusterassignment[m, :])
          αp = sum(y[idx])
          βp = 1 ./ sum(countsPerCopyNum[idx])
          π[m, c] = minimum([rand(Gamma(αp, βp)), 0.999])
          mutburdens[m, c, :] .= π[m, c]
        end
        x1 = C .+ A .- 1

        x2 = sum(log.(1 .- V[m, 1:(C.-1)]))
        x3 = B .- x2

        α[m] = rand(Gamma(C .+ A .- 1, 1/(B .- sum(log.(1 .- V[m, 1:(C.-1)])))))
        #α[m] = rand(Gamma(x1, x3))

        if verbose == true
          next!(p)
        end

    end

    dp = DPout(clusterassignment, V, π, α)

    DF, wts =
    getdensity(dp, iterations; burninstart = burninstart, bw = bw, maxxaxis = maxxaxis)
    wtsout, clonefreq, allwts, allfreq =
    summariseoutput(dp, wts, iterations; burninstart = burninstart, cutoffweight = cutoffweight)

    sortind = sortperm(clonefreq)
    return DPresults(DF, wts, length(wtsout), wtsout[sortind],
    clonefreq[sortind], allwts, allfreq, dp, TargetData(y, N, VAF));
end

function multinomsample!(clusterassignment, PrS, nummuts, m, C)
  @fastmath @inbounds for k in 1:nummuts
    clusterassignment[m, k] = sum(rand(Multinomial(1, PrS[k, :])) .* collect(1:C))
  end
end

function takemax!(PrS, k, C)
  maxPrS = maximum(PrS[k, :])
  @fastmath @inbounds for i in 1:C
    PrS[k, i] = PrS[k, i] - maxPrS
  end
end

function exp!(PrS, k, C)
  @fastmath @inbounds for i in 1:C
    PrS[k, i] = exp(PrS[k, i])
  end
end

function normalize!(PrS, k, C)
  sumPrS = sum(PrS[k, :])
  @fastmath @inbounds for i in 1:C
    PrS[k, i] = PrS[k, i] / sumPrS
  end
end

function updatestick!(V, clusterassignment, α, C, m)
  @fastmath @inbounds for h in 1:(C-1)
    V[m, h] = rand(Beta(1+sum(clusterassignment[m, :] .== h), α[m - 1] + sum(clusterassignment[m, :] .> h)))
  end
end

function allocate!(PrS, V, mutburdens, obsy, obsN, k, C, m)
    @fastmath @inbounds for j in 2:C
        PrS[k, j] = log(V[m-1, j]) +
        sum(log.(1 .- view(V, m-1, 1:(j-1)))) +
        obsy[k] * log(mutburdens[m-1, j, k]) +
        (obsN[k] - obsy[k]) * log(1-mutburdens[m-1, j, k])
    end
end

function getdensity(dp, iterations; burninstart = 500, bw = 1.0, maxxaxis = 0.5)

    wts = zeros( size(dp.V)[1], size(dp.V)[2]);
    wts[:, 1] = dp.V[:, 1]
    wts[:, 2] = dp.V[:, 2] .* (1 .- dp.V[:, 1])

    for i in 3:size(wts)[2]
        wts[:, i] = dp.V[:, i] .* prod((1 .- dp.V[:, (1:i .- 1)]), dims = 2)
    end

    postints = zeros(512, iterations -  burninstart + 1)

    xx = kde(dp.π[burninstart - 1, :],
    weights = wts[burninstart, :]./(sum(wts[burninstart, :])),
                npoints = 512, boundary = (0, maxxaxis), bandwidth = bw).x

    for i in burninstart:iterations
        postints[:, i - burninstart + 1] = kde(dp.π[i - 1, :], weights = wts[i, :]./(sum(wts[i, :])),
        npoints = 512, boundary = (0, maxxaxis), bandwidth = bw).density
    end

    meanv = mean(postints, dims = 2)[:]
    lq = mapslices(x -> quantile(x, 0.025), postints, dims = 2)[:]
    uq = mapslices(x -> quantile(x, 0.975), postints, dims = 2)[:]

    DF = DataFrame(mean = meanv, lq = lq, uq = uq, x = collect(xx))

    return DF, wts
end

function summariseoutput(dp, wts, iterations; burninstart = 1000, cutoffweight = 0.05)

    postwts = wts[burninstart:iterations, :]
    meanwts = mean(postwts, dims = 1)
    clonewts = meanwts[meanwts.>cutoffweight]

    clonefrequency = mean(dp.π[burninstart:iterations, :], dims = 1)
    largeclonefrequency = clonefrequency[meanwts.>cutoffweight]

    clonefrequency = clonefrequency[:]
    meanwts = meanwts[:]

    sortind = sortperm(clonefrequency)

    return clonewts, largeclonefrequency, meanwts[sortind], clonefrequency[sortind]
end
