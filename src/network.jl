function single_ground_all_pair_resistances{T}(a::SparseMatrixCSC, c::Vector{T}, cfg;
                                                    exclude = Tuple{Int,Int}[],
                                                    nodemap = Matrix{Float64}(0, 0),
                                                    orig_pts = Vector{Int}(),
                                                    polymap = NoPoly(),
                                                    hbmeta = RasterMeta())
    #=numpoints = size(c, 1)
    cc = connected_components(SimpleWeightedGraph(a))
    debug("Graph has $(size(a,1)) nodes, $numpoints focal points and $(length(cc)) connected components")
    resistances = -1 * ones(eltype(a), numpoints, numpoints)
    voltmatrix = zeros(eltype(a), size(resistances))

    cond_pruned = sprand(1, 1, 0.1)
    d = 0
    M = 1
    pt1 = 1
    rcc = 0
    cond = laplacian(a)

    subsets = getindex.([cond], cc, cc)
    z = zeros.(eltype(a), size.(cc))
    volt = zeros.(eltype(a), size.(cc))

    is_raster = cfg["data_type"] == "raster"
    write_volt_maps = cfg["write_volt_maps"] == "True"
    write_cur_maps = cfg["write_cur_maps"] == "True"

    get_shortcut_resistances = false
    if is_raster && !write_volt_maps && !write_cur_maps
        get_shortcut_resistances = true
        shortcut = -1 * ones(size(resistances))
        covered = Dict{Int, Bool}()
        for i = 1:size(cc, 1)
            covered[i] = false
        end
    end

    p = 0
    for i = 1:numpoints
        if c[i] != 0
            rcc = rightcc(cc, c[i])
            if get_shortcut_resistances
                if covered[rcc]
                    continue
                end
            end
            cond_pruned = subsets[rcc]
            pt1 = ingraph(cc[rcc], c[i])
            d = cond_pruned[pt1, pt1]
            cond_pruned[pt1, pt1] = 0
            M = aspreconditioner(ruge_stuben(cond_pruned))
        end
        for j = i+1:numpoints
            if (i,j) in exclude
                continue
            end
            if c[i] == 0
                resistances[i,j] = resistances[j,i] = -1
                continue
            end
            pt2 = ingraph(cc[rcc], c[j])
            if pt2 == 0
                continue
            end
            debug("pt1 = $pt1, pt2 = $pt2")
            p +=1
            curr = z[rcc]
            v = volt[rcc]
            if pt1 != pt2
                curr[pt1] = -1
                curr[pt2] = 1
                solve_linear_system!(cfg, v, cond_pruned, curr, M)
                curr[:] = 0
            end
            postprocess(v, c, i, j, resistances, pt1, pt2, cond_pruned, cc[rcc], cfg, voltmatrix,
                                            get_shortcut_resistances;
                                            nodemap = nodemap,
                                            orig_pts = orig_pts,
                                            polymap = polymap,
                                            hbmeta = hbmeta)
            v[:] = 0
        end
        cond_pruned[pt1,pt1] = d
        if get_shortcut_resistances
            update_shortcut_resistances!(i, shortcut, resistances, voltmatrix, c, cc[rcc])
            covered[rcc] = true
        end
    end
    if get_shortcut_resistances
        resistances = shortcut
    end
    debug("solved $p equations")
    for i = 1:size(resistances,1)
        resistances[i,i] = 0
    end
    resistances=#

    # Get number of focal points
    numpoints = size(c, 1)

    #Get number of connected components
    cc = connected_components(SimpleWeightedGraph(a))

    info("Graph has $(size(a,1)) nodes, $numpoints focal points and $(length(cc)) connected components")

    # Initialize pairwise resistance
    resistances = -1 * ones(eltype(a), numpoints, numpoints)
    voltmatrix = zeros(eltype(a), size(resistances))

    # Take laplacian of matrix
    t = @elapsed lap = laplacian(a)
    info("Time to construct laplacian = $t seconds")

    # Get a vector of connected components
    comps = getindex.([lap], cc, cc)

    is_raster = cfg["data_type"] == "raster"
    write_volt_maps = cfg["write_volt_maps"] == "True"
    write_cur_maps = cfg["write_cur_maps"] == "True"

    get_shortcut_resistances = false
    if is_raster && !write_volt_maps && !write_cur_maps
        get_shortcut_resistances = true
        shortcut = -1 * ones(size(resistances))
        covered = Dict{Int, Bool}()
        for i = 1:size(cc, 1)
            covered[i] = false
        end
    end

    for (cid, comp) in enumerate(cc)

        # Subset of points relevant to CC
        csub = filter(x -> x in comp, c) |> unique
        #idx = findin(c, csub)

        if isempty(csub)
            continue
        end

        # Conductance matrix corresponding to CC
        matrix = comps[cid]

        # Construct preconditioner *once* for every CC
        t1 = @elapsed P = aspreconditioner(ruge_stuben(matrix))
        info("Time taken to construct preconditioner = $t1 seconds")

        # Get local nodemap for CC - useful for output writing
        t2 = @elapsed local_nodemap = construct_local_node_map(nodemap, comp, polymap)
        info("Time taken to construct local nodemap = $t2 seconds")

        function f(i)

            # Generate return type
            ret = Vector{Tuple{Int,Int,Float64}}()

            pi = csub[i]
            comp_i = findfirst(comp, pi)
            I = find(x -> x == pi, c)
            smash_repeats!(ret, I)

            # Preprocess matrix
            d = matrix[comp_i, comp_i]
            #matrix[comp_i, comp_i] = 0

            # Iteration space through all possible pairs
            rng = i+1:size(csub, 1)

            # Loop through all possible pairs
            for j in rng

                pj = csub[j]
                comp_j = findfirst(comp, pj)
                J = find(x -> x == pj, c)

                # Forget excluded pairs
                ex = false
                for c_i in I, c_j in J
                    if (c_i, c_j) in exclude
                        ex = true
                        break
                    end
                end
                ex && continue

                if pi == pj
                    continue
                end

                # Initialize currents
                current = zeros(size(matrix, 1))
                current[comp_i] = -1
                current[comp_j] = 1

                # Solve system
                info("Solving points $pi and $pj")
                t2 = @elapsed v = solve_linear_system(cfg, matrix, current, P)
                info("Time taken to solve linear system = $t2 seconds")
                v .= v .- v[comp_i]

                # Calculate resistance
                r = v[comp_j] - v[comp_i]

                # Return resistance value
                for c_i in I, c_j in J
                    push!(ret, (c_i, c_j, r))
                    postprocess(v, c, c_i, c_j, r, comp_i, comp_j, matrix, comp, cfg, voltmatrix,
                                                get_shortcut_resistances;
                                                local_nodemap = local_nodemap,
                                                orig_pts = orig_pts,
                                                polymap = polymap,
                                                hbmeta = hbmeta)
                end
            end

        matrix[comp_i, comp_i] = d

        ret
        end

       X = map(x ->f(x), 1:size(csub,1))

       # Set all resistances
       for x in X
           for i = 1:size(x, 1)
               resistances[x[i][1], x[i][2]] = x[i][3]
               resistances[x[i][2], x[i][1]] = x[i][3]
           end
       end

    end

    for i = 1:size(resistances,1)
       resistances[i,i] = 0
    end

    resistances
end

function smash_repeats!(ret, I)
    for i = 1:size(I,1)
        for j = i+1:size(I,1)
            push!(ret, (I[i], I[j], 0))
        end
    end
end

function solve_linear_system!(cfg, v, G, curr, M)
    if cfg["solver"] == "cg+amg"
        cg!(v, G, curr, Pl = M, tol = 1e-6, maxiter = 100000)
    end
    v
end
solve_linear_system(cfg, G, curr, M) = solve_linear_system!(cfg, zeros(size(curr)), G, curr, M)

@inline function rightcc{T}(cc::Vector{Vector{T}}, c::T)
    for i in eachindex(cc)
        if c in cc[i]
            return i
        end
    end
end

@inline function ingraph{T}(cc::Vector{T}, c::T)
    findfirst(cc, c)
end

function laplacian(G)
    n = size(G, 1)
    s = Vector{eltype(G)}(n)
    for i = 1:n
        s[i] = sum_off_diag(G, i)
        for j in nzrange(G, i)
            if i == G.rowval[j]
                G.nzval[j] = 0
            else
                G.nzval[j] = -G.nzval[j]
            end
        end
    end
    G + spdiagm(s)
end

function sum_off_diag(G, i)
     sum = zero(eltype(G))
     for j in nzrange(G, i)
         if G.rowval[j] != i
             sum += G.nzval[j]
         end
     end
     sum
 end

function postprocess(volt, cond, i, j, r, pt1, pt2, cond_pruned, cc, cfg, voltmatrix,
                                            get_shortcut_resistances;
                                            local_nodemap = Matrix{Float64}(),
                                            orig_pts = Vector{Int}(),
                                            polymap = NoPoly(),
                                            hbmeta = hbmeta)

    if get_shortcut_resistances
        # local_nodemap = zeros(Int, size(nodemap))
        # idx = findin(nodemap, cc)
        # local_nodemap[idx] = nodemap[idx]
        update_voltmatrix!(voltmatrix, local_nodemap, volt, hbmeta, cond, r, j, cc)
        return nothing
    end

    name = "_$(cond[i])_$(cond[j])"

    if cfg["data_type"] == "raster"
        name = "_$(Int(orig_pts[i]))_$(Int(orig_pts[j]))"
    end

    if cfg["write_volt_maps"] == "True"
        # local_nodemap = construct_local_node_map(nodemap, cc, polymap)
        t = @elapsed write_volt_maps(name, volt, cc, cfg, hbmeta = hbmeta, nodemap = local_nodemap)
        info("Time taken to write voltage maps = $t seconds")
    end

    if cfg["write_cur_maps"] == "True"
        # local_nodemap = construct_local_node_map(nodemap, cc, polymap)
        t = @elapsed write_cur_maps(cond_pruned, volt, [-9999.], cc, name, cfg;
                                    nodemap = local_nodemap,
                                    hbmeta = hbmeta)
        info("Time taken to write current maps = $t seconds")
    end
    nothing
end

function compute{S<:Scenario}(obj::Network{S}, cfg)
    flags = inputflags(obj, cfg)
    data = grab_input(obj, flags)
    compute(obj, data, cfg)
end
compute(::Network{Pairwise}, data, cfg) =
    single_ground_all_pair_resistances(data.A, data.fp, cfg)
compute(::Network{Advanced}, data, cfg) = advanced(cfg, data.A, data.source_map, data.ground_map)

function advanced(cfg, a::SparseMatrixCSC, source_map, ground_map;
                                                                    nodemap = Matrix{Float64}(0,0),
                                                                    policy = :keepall,
                                                                    check_node = -1,
                                                                    hbmeta = RasterMeta(),
                                                                    src = 0,
                                                                    polymap = NoPoly())
    cc = connected_components(SimpleWeightedGraph(a))
    debug("There are $(size(a, 1)) points and $(length(cc)) connected components")
    mode = cfg["data_type"]
    is_network = mode == "network"
    sources = zeros(size(a, 1))
    grounds = zeros(size(a, 1))
    if mode == "raster"
        (i1, j1, v1) = findnz(source_map)
        (i2, j2, v2) = findnz(ground_map)
        for i = 1:size(i1, 1)
            v = Int(nodemap[i1[i], j1[i]])
            if v != 0
                sources[v] += v1[i]
            end
        end
        for i = 1:size(i2, 1)
            v = Int(nodemap[i2[i], j2[i]])
            if v != 0
                grounds[v] += v2[i]
            end
        end
    else
        is_res = cfg["ground_file_is_resistances"]
        if is_res == "True"
            ground_map[:,2] = 1 ./ ground_map[:,2]
        end
        sources[Int.(source_map[:,1])] = source_map[:,2]
        grounds[Int.(ground_map[:,1])] = ground_map[:,2]
    end
    sources, grounds, finitegrounds = resolve_conflicts(sources, grounds, policy)
    volt = zeros(size(nodemap))
    ind = find(nodemap)
    f_local = Float64[]
    solver_called = false
    voltages = Float64[]
    outvolt = alloc_map(hbmeta)
    outcurr = alloc_map(hbmeta)
    for c in cc
        if check_node != -1 && !(check_node in c)
            continue
        end
        a_local = laplacian(a[c, c])
        s_local = sources[c]
        g_local = grounds[c]
        if sum(s_local) == 0 || sum(g_local) == 0
            continue
        end
        if finitegrounds != [-9999.]
            f_local = finitegrounds[c]
        else
            f_local = finitegrounds
        end
        voltages = multiple_solver(cfg, a_local, s_local, g_local, f_local)
        solver_called = true
        if cfg["write_volt_maps"] == "True" && !is_network
            local_nodemap = construct_local_node_map(nodemap, c, polymap)
            accum_voltages!(outvolt, voltages, local_nodemap, hbmeta)
        end
        if cfg["write_cur_maps"] == "True" && !is_network
            local_nodemap = construct_local_node_map(nodemap, c, polymap)
            accum_currents!(outcurr, voltages, cfg, a_local, voltages, f_local, local_nodemap, hbmeta)
        end
        for i in eachindex(volt)
            if i in ind
                val = Int(nodemap[i])
                if val in c
                    idx = findfirst(x -> x == val, c)
                    volt[i] = voltages[idx]
                end
            end
        end
    end

    name = src == 0 ? "" : "_$(Int(src))"
    if cfg["write_volt_maps"] == "True"
        if is_network
            write_volt_maps(name, voltages, collect(1:size(a,1)), cfg)
        else
            write_aagrid(outvolt, name, cfg, hbmeta, voltage = true)
        end
    end
    if cfg["write_cur_maps"] == "True"
        if is_network
            write_cur_maps(laplacian(a), voltages, finitegrounds, collect(1:size(a,1)), name, cfg)
        else
            write_aagrid(outcurr, name, cfg, hbmeta)
        end
    end

    if cfg["data_type"] == "network"
        v = [collect(1:size(a, 1))  voltages]
        return v
    end
    scenario = cfg["scenario"]
    if !solver_called
        return [-1.]
    end
    if scenario == "one-to-all"
        idx = find(source_map)
        val = volt[idx] ./ source_map[idx]
        if val[1] ≈ 0
            return [-1.]
        else
            return val
        end
    elseif scenario == "all-to-one"
        return [0.]
    end

    return volt
end
function construct_local_node_map(nodemap, c, polymap)
    local_nodemap = zeros(Int, size(nodemap))
    idx = findin(nodemap, c)
    local_nodemap[idx] = nodemap[idx]
    get_local_nodemap(local_nodemap, polymap, idx)
end
function get_local_nodemap(local_nodemap, ::NoPoly, i)
    idx = find(local_nodemap)
    local_nodemap[idx] = 1:length(idx)
    local_nodemap
end
function get_local_nodemap(local_nodemap, p::Polymap, idx)
    polymap = p.polymap
    local_polymap = zeros(size(local_nodemap))
    local_polymap[idx] = polymap[idx]
    construct_node_map(local_nodemap, local_polymap)
end

function del_row_col(a, n::Int)
    l = size(a, 1)
    ind = union(1:n-1, n+1:l)
    a[ind, ind]
end

function resolve_conflicts(sources, grounds, policy)

    finitegrounds = similar(sources)
    l = size(sources, 1)

    finitegrounds = map(x -> x < Inf ? x : 0., grounds)
    if count(x -> x != 0, finitegrounds) == 0
        finitegrounds = [-9999.]
    end

    conflicts = falses(l)
    for i = 1:l
        conflicts[i] = sources[i] != 0 && grounds[i] != 0
    end

    if any(conflicts)
        if policy == :rmvsrc
            sources[find(conflicts)] = 0
        elseif policy == :rmvgnd
            grounds[find(conflicts)] = 0
        elseif policy == :rmvall
            sources[find(conflicts)] = 0
        end
    end

    infgrounds = map(x -> x == Inf, grounds)
    infconflicts = map((x,y) -> x > 0 && y > 0, infgrounds, sources)
    grounds[infconflicts] = 0


    sources, grounds, finitegrounds
end


function multiple_solver(cfg, a, sources, grounds, finitegrounds)

    asolve = deepcopy(a)
    if finitegrounds[1] != -9999
        asolve = a + spdiagm(finitegrounds, 0, size(a, 1), size(a, 1))
    end

    infgrounds = find(x -> x == Inf, grounds)
    deleteat!(sources, infgrounds)
    dst_del = Int[]
    append!(dst_del, infgrounds)
    r = collect(1:size(a, 1))
    deleteat!(r, dst_del)
    asolve = asolve[r, r]

    M = aspreconditioner(ruge_stuben(asolve))
    volt = solve_linear_system(cfg, asolve, sources, M)

    # Replace the inf with 0
    voltages = zeros(length(volt) + length(infgrounds))
    k = 1
    for i = 1:size(voltages, 1)
        if i in infgrounds
            voltages[i] = 0
        else
            #voltages[i] = volt[1][k]
            voltages[i] = volt[k]
            k += 1
        end
    end
    voltages
end
