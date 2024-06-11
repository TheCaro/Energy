using JuMP # building models
using DataStructures # using dictionaries with a default value
using HiGHS # solver for the JuMP model
using CSV # readin of CSV files
using DataFrames # data tables
using Statistics # mean function
using Plots  # generate graphs
using Plots.Measures
using StatsPlots # additional features for plots
include(joinpath(@__DIR__, "colors.jl")) # colors for the plots
include(joinpath(@__DIR__, "helper_functions.jl")) # helper functions

data_dir = joinpath(@__DIR__, "data")


### Read in of parameters ###
# We define our sets from the csv files
technologies = readcsv("technologies.csv", dir=data_dir).technology
fuels = readcsv("fuels.csv", dir=data_dir).fuel
storages = readcsv("storages.csv", dir=data_dir).storage
hour = 1:120
n_hour = length(hour)

# in addition, we now also read a set for our regions
regions = readcsv("regions.csv", dir=data_dir).region

# Also, we read our input parameters via csv files
Demand = readin("demand_regions.csv", dims=2, dir=data_dir)
OutputRatio = readin("outputratio.csv", dims=2, dir=data_dir)
InputRatio = readin("inputratio.csv", dims=2, dir=data_dir)
VariableCost = readin("variablecost.csv", dims=1, dir=data_dir)
InvestmentCost = readin("investmentcost.csv", dims=1, dir=data_dir)
EmissionRatio = readin("emissionratio.csv", dims=1, dir=data_dir)
DemandProfile = readin("demandprofile_regions.csv", default=1/n_hour, dims=3, dir=data_dir)
CapacityFactor = readin("capacity_factors_regions.csv",default=0, dims=3, dir=data_dir)
TagDispatchableTechnology = readin("tagdispatchabletechnology.csv",default=1,dims=1, dir=data_dir)
# new parameters
TradeDistance = readin("tradedistance.csv",default=0, dims=2, dir=data_dir)
TradeCostFactor = readin("tradecostfactor.csv",default=0, dims=1, dir=data_dir)
TradeLossFactor = readin("tradelossfactor.csv",default=0,dims=1,dir=data_dir)

# we need to ensure that all non-variable technologies do have a CapacityFactor of 1 at all times
for r in regions    
    for t in technologies
        if TagDispatchableTechnology[t] > 0
            for h in hour
                CapacityFactor[r,h,t] = 1
            end
        end
    end
end

# we can test if solar does still produce during the night
CapacityFactor["DE",30,"SolarPV"]

### Also, we need to read in our additional storage parameters
InvestmentCostStorage = readin("investmentcoststorage.csv",dims=1, dir=data_dir)
E2PRatio = readin("e2pratio.csv",dims=1, dir=data_dir)
StorageChargeEfficiency = readin("storagechargeefficiency.csv",dims=2, dir=data_dir)
StorageDischargeEfficiency = readin("storagedischargeefficiency.csv",dims=2, dir=data_dir)
MaxStorageCapacity = readin("maxstoragecapacity.csv",default=50,dims=2, dir=data_dir)
StorageLosses = readin("storagelosses.csv",default=1,dims=2, dir=data_dir)

# our emission limit
EmissionLimit = 20000

# define the dictionary for max capacities with specific default value
MaxCapacity = readin("maxcapacity.csv", default=999, dims=2, dir=data_dir)
MaxTradeCapacity = readin("maxtradecapacity.csv", default=0, dims=3, dir=data_dir)

### building the model ###
# instantiate a model with an optimizer
ESM = Model(HiGHS.Optimizer)

# this creates our variables
@variable(ESM, TotalCost[regions,technologies] >= 0)
@variable(ESM, FuelProductionByTechnology[regions,hour,technologies, fuels] >= 0)
@variable(ESM, Capacity[regions,technologies] >=0)
@variable(ESM, FuelUseByTechnology[regions,hour,technologies, fuels] >=0)
@variable(ESM, TechnologyEmissions[regions,technologies] >=0)
@variable(ESM, Curtailment[regions,hour,fuels] >=0)

### And we also need to add our new variables for storages
@variable(ESM, StorageEnergyCapacity[regions,s=storages,f=fuels; StorageDischargeEfficiency[s,f]>0]>=0)
@variable(ESM, StorageCharge[regions,s=storages, hour, f=fuels; StorageDischargeEfficiency[s,f]>0]>=0)
@variable(ESM, StorageDischarge[regions,s=storages, hour, f=fuels; StorageDischargeEfficiency[s,f]>0]>=0)
@variable(ESM, StorageLevel[regions,s=storages, hour, f=fuels; StorageDischargeEfficiency[s,f]>0]>=0)
@variable(ESM, TotalStorageCost[regions,storages] >= 0)

##### now, we also need new variables for trade between regions
@variable(ESM, Import[regions,regions,hour,fuels] >= 0)
@variable(ESM, Export[regions,regions,hour,fuels] >= 0)


## constraints ##
# Generation must meet demand
@constraint(ESM, EnergyBalance[r in regions,h in hour,f in fuels],
    sum(FuelProductionByTechnology[r,h,t,f] for t in technologies) 
    + sum(StorageDischarge[r,s,h,f] for s in storages if StorageDischargeEfficiency[s,f]>0) 
    + sum(Import[r,rr,h,f] for rr in regions) == 
    Demand[r,f]*DemandProfile[r,h,f] 
    + sum(FuelUseByTechnology[r,h,t,f] for t in technologies) 
    + Curtailment[r,h,f] 
    + sum(StorageCharge[r,s,h,f] for s in storages if StorageChargeEfficiency[s,f] > 0)
    + sum(Export[r,rr,h,f] for rr in regions)
)

# calculate the total production cost
@constraint(ESM, ProductionCost[r in regions,t in technologies],
    sum(FuelProductionByTechnology[r,h,t,f] for f in fuels, h in hour) * VariableCost[t] + Capacity[r,t] * InvestmentCost[t] == TotalCost[r,t]
)

# limit the production by the installed capacity
@constraint(ESM, ProductionFuntion_disp[r in regions,h in hour, t in technologies, f in fuels;TagDispatchableTechnology[t]>0],
    OutputRatio[t,f] * Capacity[r,t] * CapacityFactor[r,h,t] >= FuelProductionByTechnology[r,h,t,f]
)

# for variable renewables, the production needs to be always at maximum
@constraint(ESM, ProductionFuntion_res[r in regions,h in hour, t in technologies, f in fuels;TagDispatchableTechnology[t]==0],
    OutputRatio[t,f] * Capacity[r,t] * CapacityFactor[r,h,t] == FuelProductionByTechnology[r,h,t,f]
)

# define the use by the production
@constraint(ESM, UseFunction[r in regions,h in hour,t in technologies, f in fuels],
    InputRatio[t,f] * sum(FuelProductionByTechnology[r,h,t,ff] for ff in fuels) == FuelUseByTechnology[r,h,t,f]
)

# define the emissions
@constraint(ESM, TechnologyEmissionFunction[r in regions,t in technologies],
    sum(FuelProductionByTechnology[r,h,t,f] for f in fuels, h in hour) * EmissionRatio[t] == TechnologyEmissions[r,t]
)

# limit the emissions
@constraint(ESM, TotalEmissionsFunction,
    sum(TechnologyEmissions[r,t] for t in technologies for r in regions) <= EmissionLimit
)

# installed capacity is limited by the maximum capacity
@constraint(ESM, MaxCapacityFunction[r in regions,t in technologies],
     Capacity[r,t] <= MaxCapacity[r,t]
)

### Add your storage constraints here
@constraint(ESM, StorageChargeFunction[r in regions,s in storages, h in hour, f in fuels; StorageDischargeEfficiency[s,f]>0], 
    StorageCharge[r,s,h,f] <= StorageEnergyCapacity[r,s,f]/E2PRatio[s]
)

@constraint(ESM, StorageDischargeFunction[r in regions,s in storages, h in hour, f in fuels; StorageDischargeEfficiency[s,f]>0], 
    StorageDischarge[r,s,h,f] <= StorageEnergyCapacity[r,s,f]/E2PRatio[s]
)

@constraint(ESM, StorageLevelFunction[r in regions,s in storages, h in hour, f in fuels; h>1 && StorageDischargeEfficiency[s,f]>0], 
    StorageLevel[r,s,h,f] == StorageLevel[r,s,h-1,f]*StorageLosses[s,f] + StorageCharge[r,s,h,f]*StorageChargeEfficiency[s,f] - StorageDischarge[r,s,h,f]/StorageDischargeEfficiency[s,f]
)

@constraint(ESM, StorageLevelStartFunction[r in regions,s in storages, h in hour, f in fuels; h==1 && StorageDischargeEfficiency[s,f]>0], 
    StorageLevel[r,s,h,f] == 0.5*StorageEnergyCapacity[r,s,f]*StorageLosses[s,f] + StorageCharge[r,s,h,f]*StorageChargeEfficiency[s,f] - StorageDischarge[r,s,h,f]/StorageDischargeEfficiency[s,f]
)

@constraint(ESM, MaxStorageLevelFunction[r in regions,s in storages, h in hour, f in fuels; StorageDischargeEfficiency[s,f]>0], 
    StorageLevel[r,s,h,f] <= StorageEnergyCapacity[r,s,f]
)

@constraint(ESM, StorageAnnualBalanceFunction[r in regions,s in storages, f in fuels; StorageDischargeEfficiency[s,f]>0], 
    StorageLevel[r,s,n_hour,f] == 0.5*StorageEnergyCapacity[r,s,f]
)

@constraint(ESM, StorageCostFunction[r in regions,s in storages], 
    TotalStorageCost[r,s] == sum(StorageEnergyCapacity[r,s,f]*InvestmentCostStorage[s] for f in fuels if StorageDischargeEfficiency[s,f]>0)
)

@constraint(ESM, StorageMaxCapacityLimit[r in regions,s in storages],
    sum(StorageEnergyCapacity[r,s,f] for f in fuels if StorageDischargeEfficiency[s,f]>0) <= MaxStorageCapacity[r,s]
)

@constraint(ESM, ImportExportBalance[r in regions, rr in regions, h in hour, f in fuels],
    Import[r,rr,h,f] == (1-TradeLossFactor[f])^TradeDistance[r,rr]*Export[rr,r,h,f]
)

@constraint(ESM, MaxImportFunction[r in regions,rr in regions,h in hour,f in fuels],
    Import[r,rr,h,f] <= MaxTradeCapacity[r,rr,f]
)

# the objective function
# total costs should be minimized
@objective(ESM, Min, 
    sum(TotalCost[r,t] for t in technologies for r in regions) 
    + sum(TotalStorageCost[r,s] for s in storages for r in regions)
    + sum(Export[r,rr,h,f]*TradeCostFactor[f]*TradeDistance[r,rr] for h in hour, r in regions, rr in regions, f in fuels)
    )

# this starts the optimization
# the assigned solver (here HiGHS) will takes care of the solution algorithm
optimize!(ESM)
# reading our objective value
objective_value(ESM)

# we will analyze the results in Tableau from now on, so we just need to write our results to csv files
# you can find the code that does this reading, merging, and writing of results in the helper_functions.jl file!
df_energybalance,df_capacity,df_storage_level,df_trade = process_dataframes()
write_result_csvs()

