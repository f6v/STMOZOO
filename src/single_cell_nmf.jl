module SingleCellNMF

using Distributions, DataFrames, LinearAlgebra, UMAP, Distances

export perform_nmf, reduce_dims_atac

"""
Reduce dimensions of ATAC-seq dataset using UMAP. 
	
	reduce_dims_atac(atac_df::DataFrame, Z::Array{Float64}, R::Array{Bool})
	reduce_dims_atac(atac_df::DataFrame)	
Input
- `atac_df`: `DataFrame` with loci in rows and cells in columns 
- `Z`: epigenetic aggregation matrix returned by `perform_nmf`
- `R`: binary aggregation matrix returned by `perform_nmf`. 

In case `Z` and `R` are not provided, no aggregation of ATAC signal is performed.

Returns a (2 x number of cells) array which represents the data
in a low-dimensional spaced inferred with UMAP.
"""
function reduce_dims_atac(atac_df, Z, R)
	X_atac, _ = df_to_array(atac_df, "locus_name")

	ZR = (Z .* R) ./ sum(Z .* R, dims = 1)
	X_atac = X_atac * ZR

	return umap(X_atac; n_neighbors=30, metric = CorrDist())
end

function reduce_dims_atac(atac_df::DataFrame)
	n_cells = size(atac_df, 2) - 1
	Z = Matrix{Float64}(I, n_cells, n_cells) 
	R = Matrix{Bool}(I, n_cells, n_cells) 

	return reduce_dims_atac(atac_df, Z, R)
end

"""
	perform_nmf(rna_df::DataFrame, atac_df::DataFrame, k::Int64;
			dropout_prob = 0.25, n_iter = 500.0, alpha = 1.0, lambda = 100000.0,
			gamma = 1.0, verbose = false)

Perform non-negative matrix factorization(NMF) using both scRNA-seq and scATAC-seq data.
The function returns cell loadings, as well as modality-specific loadings. The choice of
`k` can reflect the prior knowledge about the major sources of variability in both scRNA-seq
and scATAC-seq data. Alternatively, the best value of `k` can be determined empirically.

Input
- `rna_df`: RNA-seq `DataFrame` with genes in rows and cells in columns. Must include a `gene_name` column
- `atac_df`: ATAC-seq `DataFrame` with loci in rows and cells in columns. Must include a `locus_name` column
- `k`: dimensionality of a shared low-dimensional representation of both input datasets
- `dropout_prob`: higher probability reduces over-aggregation of ATAC-seq signal, must be between 0 and 1
- `n_iter`: number of iterations for the algorithm
- `alpha`: regularization parameter for gene loading matrix
- `lambda`: regularization parameter for aggregation matrix Z
- `gamma`: regularization parameter for cell loading matrix H
- `verbose`: set to `true` for printing logs
 
Output
- Cell loading matrix `H`
- Gene loading matrix
- Locus loading matrix
- ATAC aggregation matrix `Z`
- Binary over-aggregation matrix `R`
- History for the objective value
"""
function perform_nmf(rna_df::DataFrame, atac_df::DataFrame, k::Int64;
			dropout_prob = 0.25, n_iter = 500.0, alpha = 1.0, lambda = 100000.0,
			gamma = 1.0, verbose = false)
	if k <= 0
		throw(ArgumentError("k should be positive"))
	end
	
	if !("gene_name" in names(rna_df)) || !("locus_name" in names(atac_df))
		throw(ArgumentError("Input DataFrames must have feature names"))
	end
	
	X_rna, gene_names = df_to_array(rna_df, "gene_name")
	X_atac, loci_names = df_to_array(atac_df, "locus_name") 
	
	n_rows_rna, n_cells = size(X_rna)
	n_rows_atac, n_cells = size(X_atac)
	
	# Cell loading matrix
	H = rand(Uniform(), k, n_cells)
	
	# ATAC signal aggregation matrices	
	Z = rand(Uniform(), n_cells, n_cells)
	R = rand(Bernoulli(dropout_prob), n_cells, n_cells)
	
	# Gene and locus loading matrices
	W_rna = rand(Uniform(), n_rows_rna, k)
	W_atac = rand(Uniform(), n_rows_atac, k)
	
	obj_history = []
	
	for i = 1:n_iter
		verbose && println("Iteration $(i)")

		# inplace version: H ./= sum(H, dims = 2)
		H = H ./ sum(H, dims = 2)
		W_rna = update_W_rna(W_rna, X_rna, H)  
		w_atac = update_W_atac(W_atac, X_atac, H, Z, R)
		H = update_H(W_rna, W_atac, X_rna, X_atac, H, Z, R, alpha, lambda, gamma)
		Z = update_Z(W_atac, X_atac, H, Z, R, lambda)

		current_obj = alpha * norm(X_rna .- W_rna * H)^2 + 
				norm(X_atac * (Z .* R) .- W_atac * H)^2 +
				lambda * norm(Z .- H' * H) + gamma * sum(sum(H, dims = 1).^2)
		push!(obj_history, current_obj)
	end
	
	W_rna_df = DataFrame(W_rna)
	W_atac_df = DataFrame(W_atac)
	
	W_rna_df[!, "gene_name"] = gene_names
	W_atac_df[!, "locus_name"] = loci_names

	return H, W_rna_df, W_atac_df, Z, R, obj_history
end

function df_to_array(df::DataFrame, feature_name)
	features = df[!, feature_name]
	df_no_names = df[!, filter(x -> x != feature_name, names(df))]
	X = convert(Array{Float64}, df_no_names)	
		
	return X, features
end

function update_W_rna(W_rna, X_rna, H)
	return W_rna .* (X_rna * H') ./ (W_rna * H * H' .+ eps(Float64))
end

function update_W_atac(W_atac, X_atac, H,
			Z, R)
	return W_atac .* (X_atac * (Z .* R) * H') ./ (W_atac * H * H' .+ eps(Float64)) 
end

function update_H(W_rna, W_atac, X_rna,
			X_atac, H, Z,
			R, alpha, lambda, gamma)
	numerator = alpha * W_rna' * X_rna .+ W_atac' * X_atac * (Z .* R)
			.+ lambda * H * (Z + Z')
	k = size(H)[1]
	denominator = (alpha * W_rna' * W_rna + W_atac' * W_atac + 2 * lambda * H * H'
			+ gamma * ones(k, k)) * H

	return H .* numerator ./ (denominator .+ eps(Float64))	
end

function update_Z(W_atac, X_atac, H,
			Z, R, lambda)
	numerator = (X_atac' * W_atac * H) .* R .+ lambda * H' * H 
	denominator = X_atac' * X_atac * (Z .* R) .* R .+ lambda * Z
		
	return Z .* numerator ./ (denominator .+ eps(Float64))
end
end
