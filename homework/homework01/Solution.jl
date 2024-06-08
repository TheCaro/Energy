using JuMP # building models
using DataStructures # using dictionaries with a default value
using HiGHS # solver for the JuMP model
using CSV # readin of CSV files
using DataFrames # data tables
using Statistics # mean function
using Plots  # generate graphs
using StatsPlots # additional features for plots
using Plots.Measures
include(joinpath(@__DIR__, "colors.jl")) # colors for the plots

### some helper functions ###
# read the csv files
readcsv(x; dir=@__DIR__) = CSV.read(joinpath(dir, x), DataFrame, stringtype=String)
# readin function for parameters; this makes handling easier
readin(x::AbstractDataFrame; default=0,dims=1) = DefaultDict(default,Dict((dims > 1 ? Tuple(row[y] for y in 1:dims) : row[1]) => row[dims+1] for row in eachrow(x)))
readin(x::AbstractString; dir=@__DIR__, kwargs...) = readin(readcsv(x, dir=dir); kwargs...)

### Read in of parameters ###
# We define our sets from the csv files
technologies = readcsv("technologies.csv").technology
fuels = readcsv("fuels.csv").fuel

# Also, we read our input parameters via csv files
Demand = readin("demand.csv", dims=1)
OutputRatio = readin("outputratio.csv", dims=2)
InputRatio = readin("inputratio.csv", dims=2)
VariableCost = readin("variablecost.csv", dims=1)
InvestmentCost = readin("investmentcost.csv", dims=1)
EmissionRatio = readin("emissionratio.csv", dims=1)

# our emission limit
EmissionLimit = 20

# define the dictionary for max capacities with specific default value
MaxCapacity = readin("maxcapacity.csv", default=999, dims=1)

# you can also set the parameter for one specific technology in the code
# this overrides the read-in from the csv file
MaxCapacity["SolarPV"] = 60

### building the model ###
# instantiate a model with an optimizer
ESM = Model(HiGHS.Optimizer)

# this creates our variables
@variable(ESM, TotalCost[technologies] >= 0)
@variable(ESM, FuelProductionByTechnology[technologies, fuels] >= 0)
@variable(ESM, Capacity[technologies] >=0)
@variable(ESM, FuelUseByTechnology[technologies, fuels] >=0)
@variable(ESM, TechnologyEmissions[t in technologies])

## constraints ##
# Generation must meet demand
@constraint(ESM, EnergyBalance[f in fuels],
    sum(FuelProductionByTechnology[t,f] for t in technologies) >= Demand[f] + sum(FuelUseByTechnology[t,f] for t in technologies)
)

# calculate the total cost
@constraint(ESM, ProductionCost[t in technologies],
    sum(FuelProductionByTechnology[t,f] for f in fuels) * VariableCost[t] + Capacity[t] * InvestmentCost[t] == TotalCost[t]
)

# limit the production by the installed capacity
@constraint(ESM, ProductionFuntion[t in technologies, f in fuels],
    OutputRatio[t,f] * Capacity[t] >= FuelProductionByTechnology[t,f]
)

# define the use by the production
@constraint(ESM, UseFunction[t in technologies, f in fuels],
    InputRatio[t,f] * sum(FuelProductionByTechnology[t,ff] for ff in fuels) == FuelUseByTechnology[t,f]
)

# define the emissions
@constraint(ESM, TechnologyEmissionsFunction[t in technologies],
    sum(FuelProductionByTechnology[t,f] for f in fuels) * EmissionRatio[t] == TechnologyEmissions[t]
)

# limit the emissions
@constraint(ESM, TotalEmissionsFunction,
    sum(TechnologyEmissions[t] for t in technologies) <= EmissionLimit
)

# installed capacity is limited by the maximum capacity
@constraint(ESM, MaxCapacityFunction[t in technologies],
     Capacity[t] <= MaxCapacity[t]
)

# the objective function
# total costs should be minimized
@objective(ESM, Min, sum(TotalCost[t] for t in technologies))

# this starts the optimization

# the assigned solver (here HiGHS) will takes care of the solution algorithm
optimize!(ESM)

# reading our objective value
objective_value(ESM)

# some result analysis
sum(value.(FuelProductionByTechnology[:,"H2"]))
value.(Capacity)

df_res_production = DataFrame(Containers.rowtable(value,FuelProductionByTechnology; header = [:Technology, :Fuel, :value]))
df_res_capacity = DataFrame(Containers.rowtable(value,Capacity; header = [:Technology, :value]))

transform!(df_res_production, "Technology" => ByRow(x-> colors[x]) => "Color")
transform!(df_res_capacity, "Technology" => ByRow(x-> colors[x]) => "Color")

# and some plots
groupedbar(
    df_res_production.Fuel,
    df_res_production.value,
    group=df_res_production.Technology,
    bar_position=:stack,
    title="Production by Technology",
    linewidth=0,
    color=df_res_production.Color,
    legend=false
)


bar(
    df_res_capacity.Technology,
    df_res_capacity.value,
    title="Installed Capacity by Technology",
    color=df_res_capacity.Color,
    linewidth=0,
    rotation=90
)