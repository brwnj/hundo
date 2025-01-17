#!/bin/sh
#SBATCH --account=mint
#SBATCH --partition=short
#SBATCH --time=180
#SBATCH --nodes=1
#SBATCH --ntasks=24
#SBATCH --job-name="hundo"
#SBATCH --output="%A.out"
#SBATCH --error="%A.err"

<<usage
sbatch run.sh bottos-pt

The default is to run with 16s configuration file.

Alternatively,

sbatch run.sh bottos-its resources/its.config.yaml
usage

cd /pic/projects/mint/hundo
config=${2:-"resources/16s.config.yaml"}
snakemake -j 24 --nolock --rerun-incomplete --configfile $config --config eid=$1
