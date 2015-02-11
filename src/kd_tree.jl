module KD
function euclidean_distance{T <: FloatingPoint}(point_1::AbstractVector{T},
                                                point_2::AbstractVector{T})
    dist = 0.0
    for i = 1:size(point_1, 1)
        @inbounds dist += abs2(point_1[i] - point_2[i])
    end
    return dist
end


# Hyper rectangles are used to bound points in space.
# For an inner node all it's children are bounded by the
# inner nodes hyper rectangle.
immutable HyperRectangle{T <: FloatingPoint}
    mins::Vector{T}
    maxes::Vector{T}
end


# When creating the tree we split the parents hyper rectangles
# so that each children gets its own.
function split_hyper_rec{T <: FloatingPoint}(hyper_rec::HyperRectangle{T},
                                             dim::Int,
                                             value::T)
    new_max = copy(hyper_rec.maxes)
    new_max[dim] = value

    new_min = copy(hyper_rec.mins)
    new_min[dim] = value

    return HyperRectangle(hyper_rec.mins, new_max),
           HyperRectangle(new_min, hyper_rec.maxes)
end


# From a hyper rectangle we can find the minimum and maximum distance to a point.
# If the point is inside the hyper cube the minimum dist is 0
# We do not return the sqrt here.
function get_min_max_distance{T <: FloatingPoint}(rec::HyperRectangle{T}, point::Vector{T})
    min_d = zero(T)
    max_d = zero(T)
    @inbounds for dim in 1:size(point,1)
        d1 = (rec.maxes[dim] - point[dim]) * (rec.maxes[dim] - point[dim])
        d2 = (rec.mins[dim] - point[dim]) * (rec.mins[dim] - point[dim])
        if (rec.mins[dim] > point[dim]) || (rec.maxes[dim] < point[dim]) # Point is outside
            min_d += min(d1, d2)
        end
        max_d += max(d1,d2)
    end
    return min_d, max_d
end


# The KDTree type
immutable KDTree{T <: FloatingPoint}
  data::Matrix{T} # dim x n_points array with floats
  hyper_recs::Vector{HyperRectangle{T}} # Each hyper rectangle bounds its children
  split_vals::Vector{T} # what values we split the tree at for a given internal node
  split_dims::Vector{Int} # what dimension we split the tree for a given internal node
  indices::Vector{Int} # Translates from a point index to the actual point in the data
  leaf_size::Int
  n_leafs::Int
  n_internal_nodes::Int
  last_row_index::Int
  first_leaf_row::Int
  offset::Int
end

function show(io::IO, tree::KDTree)
    print(io, string("KDTree from ", size(tree.data, 2),
                 " point in ", size(tree.data, 1), " dimensions."))
end

# Helper functions to get node numbers and points
get_left_node(idx::Int) = idx * 2
get_right_node(idx::Int) = idx * 2 + 1
get_parent_node(idx::Int) = div(idx, 2)

# From node index -> point in data
get_point(tree::KDTree, idx::Int) = view(tree.data, :, tree.indices[get_point_index(tree, idx)])

function get_n_points(tree::KDTree, idx::Int)
    if idx != tree.n_leafs + tree.n_internal_nodes
        return tree.leaf_size
    else
        point_size = size(tree.data,2) % tree.leaf_size
        if point_size == 0
            return tree.leaf_size
        else
            return point_size
        end
    end
end


function get_point_index(tree::KDTree, idx::Int) 
    if idx >= tree.last_row_index
        return (idx - tree.last_row_index) * tree.leaf_size + 1
    else
        return (tree.offset -1 + idx -1 - tree.n_internal_nodes) * tree.leaf_size + size(tree.data,2) % tree.leaf_size + 1
    end
end

is_leaf_node(tree::KDTree, idx::Int) = idx > tree.n_internal_nodes


# Constructor for KDTree
function KDTree{T <: FloatingPoint}(data::Matrix{T},
                                    leaf_size::Int = 1)

    n_dim, n_points = size(data)

    if n_dim > 20
        warn(string("You are sending in data with a large dimension, n_dim = ", n_dim,
                    ". K-d trees are not optimal for high dimensional data.",
                    " The data matrix should be given in dimensions (n_dim, n_points).",
                    " Did you acidentally flip them?"))
    end


    n_leaf_nodes =  iceil(n_points / leaf_size)
    n_internal_nodes = n_leaf_nodes - 1


    l = ifloor(log2(n_leaf_nodes))

    rest = n_leaf_nodes - 2^l
    offset = rest * 2
    last_row_index = int(2^(l+1))
    if last_row_index >= n_internal_nodes + n_leaf_nodes
        last_row_index = int(last_row_index/2)
    end


    #k = ifloor(log2(n_leafs)) # First row with leaf nodes


    indices = collect(1:n_points)
    split_vals = Array(T, n_internal_nodes)
    split_dims = Array(Int, n_internal_nodes) # 128 dimensions should be enough
    hyper_recs = Array(HyperRectangle{T}, n_internal_nodes)


    # Create first bounding hyper rectangle
    maxes = Array(T, n_dim)
    mins = Array(T, n_dim)
    for j in 1:n_dim
        dim_max = typemin(T)
        dim_min = typemax(T)
        for k in 1:n_points
            dim_max = max(data[j, k], dim_max)
            dim_min = min(data[j, k], dim_min)
        end
        maxes[j] = dim_max
        mins[j] = dim_min
    end
    hyper_recs[1] = HyperRectangle{T}(mins, maxes)

    low = 1
    high = n_points

    # Call the recursive KDTree builder
    build_KDTree(1, data, split_vals,
                 split_dims, hyper_recs,
                 indices, leaf_size,
                  low, high)

    println("l ", l)

    KDTree(data, hyper_recs,
           split_vals, split_dims, indices, leaf_size, n_leaf_nodes,
            n_internal_nodes,
           last_row_index, l ,offset)
  end


# Recursive function to build the tree.
# Calculates what dimension has the maximum spread,
# and how many points to send to each side.
# Splits the hyper cubes and calls recursively
# with the new cubes and node indices.
function build_KDTree{T <: FloatingPoint}(index::Int,
                                          data::Matrix{T},
                                          split_vals::Vector{T},
                                          split_dims::Vector{Int},
                                          hyper_recs::Vector{HyperRectangle{T}},
                                          indices::Vector{Int},
                                          leaf_size::Int,
                                          low::Int,
                                          high::Int)

    #n_internal_nodes = length(split_dims)   
    n_points = high - low + 1 # Points left
    #println("n_points", n_points)

    if n_points <= leaf_size
        println(index)
        return
    end


    # The number of leafs we have to fix
    n_leafs = iceil(n_points / leaf_size)

    if Base.VERSION >= v"0.4.0-dev"
        k = floor(Integer, log2(n_leafs))
    else
        k = ifloor(log2(n_leafs)) 
    end

    # Number of leftover nodes needed
    rest = n_leafs - 2^k

    if k == 0
        mid_idx = 1
    elseif n_points < 2*leaf_size
        mid_idx = leaf_size
    elseif  rest > 2^(k-1)
        mid_idx = 2^k*leaf_size + low
    else
        mid_idx = n_points - 2^(k-1)*leaf_size + low
    end

    # Find the dimension where we have the largest spread.
    n_dim = size(data, 1)
    split_dim = -1
    max_spread = zero(T)
    for dim in 1:n_dim
        xmin = typemax(T)
        xmax = typemin(T)
        # Find max and min in this dim

        for coordinate in 1:n_points
            xmin = min(xmin, data[dim, indices[coordinate + low - 1]])
            xmax = max(xmax, data[dim, indices[coordinate + low - 1]])
        end

        if xmax - xmin > max_spread # Found new max_spread, update split dimension
            max_spread = xmax - xmin
            split_dim = dim
        end
    end

    #println("low ", low)
    #println("high ", high)
    #println("index ", index)
    #println("mid_idx ", mid_idx)

    println("hejsan ", mid_idx)
    split_dims[index] = split_dim

    # select! works like n_th element in c++
    # sorts the points in the maximum spread dimension s.t
    # data[split_dim, a]) < data[split_dim, b]) for all a > mid_idx, b > mid_idx
    select_spec!(indices, mid_idx, low, high, data, split_dim)

    split = data[split_dim, indices[mid_idx]]
    split_vals[index] = split

    # Create the hyper rectangles for the children
    #hyper_rec_1, hyper_rec_2 = split_hyper_rec(hyper_recs[index], split_dim, split)
    #hyper_recs[get_left_node(index)] = hyper_rec_1
    #hyper_recs[get_right_node(index)] = hyper_rec_2

    build_KDTree(get_left_node(index), data,
                  split_vals, split_dims, hyper_recs,
                   indices, leaf_size, low, mid_idx - 1)

    build_KDTree(get_right_node(index), data,
                  split_vals, split_dims, hyper_recs,
                  indices, leaf_size, mid_idx, high)
end


# Finds the k nearest neighbour to a given point in space.
function k_nearest_neighbour{T <: FloatingPoint}(tree::KDTree, point::Vector{T}, k::Int)

    if k > size(tree.data, 2) || k <= 0
        error("k > number of points in tree or <= 0")
    end

    if size(point,1) != size(tree.data, 1)
        error(string("Wrong dimension of input point, points in the tree",
                     " have dimension ", size(tree.data, 1), " you",
                     " gave a point with dimension ", size(point,1), "."))
    end

    best_idxs = [-1 for i in 1:k]
    best_dists = [typemax(T) for i in 1:k]

    _k_nearest_neighbour(tree, point, k, best_idxs, best_dists)

    return best_idxs, sqrt(best_dists)
end


function _k_nearest_neighbour{T <: FloatingPoint}(tree::KDTree,
                                                  point::Vector{T},
                                                  k::Int,
                                                  best_idxs ::Vector{Int},
                                                  best_dists::Vector{T},
                                                  index::Int=1)
    println(index)
    if is_leaf_node(tree, index)
        point_index = get_point_index(tree, index)
        for z in point_index:point_index + get_n_points(tree, index) -1

            println(z)
            # Inlined distance because views are just too slow
            dist_d = 0.0
            for i = 1:size(point, 1)
                dist_d += abs2(tree.data[i, tree.indices[z]] - point[i])
            end
            #dist_d = euclidean_distance(trial_point, point)
            if dist_d <= best_dists[k] # Closer than the currently k closest.
                ins_point = 1
                while(ins_point < k && dist_d > best_dists[ins_point]) # Look through best_dists for insertion point
                    ins_point +=1
                end
                for (i in k:-1:ins_point+1) # Shift down
                     best_idxs[i] = best_idxs[i-1]
                     best_dists[i]  = best_dists[i-1]
                end
                # Update with new values
                best_idxs[ins_point] = tree.indices[z]
                best_dists[ins_point] = dist_d
            end
        end
        return
    end

    if point[tree.split_dims[index]] < tree.split_vals[index]
        println("hopp")
        close = get_left_node(index)
        far = get_right_node(index)
    else
        println("happ")
        far = get_left_node(index)
        close = get_right_node(index)
    end

    _k_nearest_neighbour(tree, point, k, best_idxs, best_dists, close)

    # Only go far node if it sphere crosses hyperplane
    println(abs2(point[tree.split_dims[index]] - tree.split_vals[index]) )
    if abs2(point[tree.split_dims[index]] - tree.split_vals[index]) < best_dists[k]
        print("hej")
         _k_nearest_neighbour(tree, point, k, best_idxs, best_dists, far)
    end

    return

end
# Returns the sorted list of indices for all points in the tree inside a
# hypersphere of a given point with a given radius
function query_ball_point{T <: FloatingPoint}(tree::KDTree,
                                              point::Vector{T},
                                              radius::T)

    if size(point,1) != size(tree.data, 1)
        error(string("Wrong dimension of input point, points in the tree",
                     " have dimension ", size(tree.data, 1), " you",
                     " gave a point with dimension ", size(point,1), "."))
    end

    index = 1
    idx_in_ball = Int[]
    traverse_check(tree, index, point, radius^2 , idx_in_ball)
    sort!(idx_in_ball)
    return idx_in_ball
end


# Explicitly check the distance between leaf node and point
function traverse_check{T <: FloatingPoint}(tree::KDTree,
                                            index::Int,
                                            point::Vector{T},
                                            r::T,
                                            idx_in_ball::Vector{Int})


    min_d, max_d = get_min_max_distance(tree.hyper_recs[index], point)
    if min_d > r # Hyper shpere is outside hyper rectangle, skip the whole sub tree
        return
    elseif max_d < r
        traverse_no_check(tree, index, idx_in_ball)
    elseif tree.is_leafs[index]
        for z in tree.start_idxs[index]:tree.end_idxs[index]
            # Inlined distance because views are just too slow
            dist_d = 0.0
            for i = 1:size(point, 1)
                @inbounds dist_d += abs2(tree.data[i, tree.indices[z]] - point[i])
            end
            if dist_d < r
            #if euclidean_distance(get_point(tree, index), point) < r
                push!(idx_in_ball, tree.indices[z])
            end
        end
        return
    else
        traverse_check(tree, get_left_node(index), point, r, idx_in_ball)
        traverse_check(tree, get_right_node(index), point, r, idx_in_ball)
    end
end


# Adds everything in this subtree since we have determined
# that the hyper rectangle completely encloses the hyper sphere
function traverse_no_check(tree::KDTree, index::Int, idx_in_ball::Vector{Int})
    if tree.is_leafs[index]
        for z in tree.start_idxs[index]:tree.end_idxs[index]
            push!(idx_in_ball, tree.indices[z])
        end
        return
    else
        traverse_no_check(tree, get_left_node(index), idx_in_ball)
        traverse_no_check(tree, get_right_node(index), idx_in_ball)
    end
end


# Taken from https://github.com/JuliaLang/julia/blob/v0.3.5/base/sort.jl
# and modified because I couldn't figure out how to get rid of
# the memory consumption when I passed in a new anonymous function
# to the "by" argument in each node. I also removed the return value.
function select_spec!{T <: FloatingPoint}(v::AbstractVector, k::Int, lo::Int,
                                          hi::Int, data::Matrix{T}, dim::Int)
    lo <= k <= hi || error("select index $k is out of range $lo:$hi")
     @inbounds while lo < hi
        if hi-lo == 1
            if data[dim, v[hi]] < data[dim, v[lo]]
                v[lo], v[hi] = v[hi], v[lo]
            end
            return
        end
        pivot = v[(lo+hi)>>>1]
        i, j = lo, hi
        while true
            while data[dim, v[i]] < data[dim, pivot]; i += 1; end
            while  data[dim, pivot] <  data[dim, v[j]] ; j -= 1; end
            i <= j || break
            v[i], v[j] = v[j], v[i]
            i += 1; j -= 1
        end
        if k <= j
            hi = j
        elseif i <= k
            lo = i
        else
            return
        end
    end
    return
end
end